import AppKit
import SwiftUI

// Native (pure AppKit) subagent ("Deck agent") cards — the dominant scroll-hang
// source in subagent-heavy sessions. Hosted, the markdown task previews rebuilt
// their whole NSTextView trees (inside NSHostingView + SwiftUI layout) on every
// scroll vend. Native, they reuse persistent markdown containers and rebuild only
// on content change.
//
// One reusable unit — the "agent block" (glyph · name+outcome · status/metrics ·
// icon actions · capped/expandable task). Single runs render one block in a card;
// parallel runs render a header + a vertical stack of agent cards inside ONE
// outer card (same outline), so they read as a group. No box-in-box-in-box.

// MARK: - Agent block payload

struct NativeAgentBlockPayload {
    var agentName: String
    var agentDescription: String?
    var whenToUse: String?
    var statusText: String
    var statusColor: NSColor
    var isActive: Bool
    var avatarURL: URL?
    var outcomePill: String?
    var task: String
    /// Elapsed time, shown on the status line next to the status word.
    var durationText: String?
    /// Model + reasoning effort, shown in a monospace capsule pill beside the
    /// agent name as `model:thinking` (e.g. `opencode-go/mimo-v2.5:off`). Uses
    /// the shared identifier-pill style (AppTheme.IdentifierPill) so it matches
    /// the plan-id pill in the plan popover. Hugs its content, never truncates.
    var modelText: String?
    /// Token count, shown as muted text beside the model pill.
    var tokensText: String?
    var actions: [Action]

    struct Action {
        var symbol: String
        var help: String
        var isEnabled: Bool = true
        var isDestructive: Bool = false
        var run: (NSButton) -> Void
    }
}

struct NativeSubagentParallelPayload {
    var title: String          // "Parallel agents"
    var count: Int
    var statusText: String
    var statusColor: NSColor
    var children: [NativeAgentBlockPayload]
}

private struct NativeAgentProfilePayload {
    var agentName: String
    var agentDescription: String?
    var whenToUse: String?
    var modelText: String?
    var avatarURL: URL?
    var accentColor: NSColor
}

// MARK: - Activity glyph (avatar + rotating ring when active)

private final class PiAgentNativeSubagentGlyph: NSView, NSPopoverDelegate {
    private let bgLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    // Activity ring: a conic ("angular") gradient masked to a circular stroke —
    // bright at the head, fading along the tail (the comet the SwiftUI original
    // drew with AngularGradient). The whole gradient layer rotates; the render
    // server composites it, so the spin costs the main thread nothing.
    private let ringGradient = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private let avatar = NSImageView()
    private var hoverTracking: NSTrackingArea?
    private var hoverShowWorkItem: DispatchWorkItem?
    private var hoverDismissWorkItem: DispatchWorkItem?
    private var profilePopover: NSPopover?
    private var profile: NativeAgentProfilePayload?
    private var isPointerInside = false
    private var isPointerInsideProfilePopover = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(bgLayer)
        layer?.addSublayer(strokeLayer)
        layer?.addSublayer(ringGradient)
        strokeLayer.fillColor = NSColor.clear.cgColor
        strokeLayer.lineWidth = 1
        ringGradient.type = .conic
        ringGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        ringGradient.endPoint = CGPoint(x: 0.5, y: 0)
        ringMask.fillColor = NSColor.clear.cgColor
        ringMask.strokeColor = NSColor.white.cgColor
        ringMask.lineWidth = 2
        ringGradient.mask = ringMask
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        // 28pt inside the 34pt glyph, like the SwiftUI original — the activity
        // ring spins at the glyph edge, so a full-bleed avatar would hide it.
        avatar.layer?.cornerRadius = 14
        avatar.layer?.masksToBounds = true
        addSubview(avatar)
        setAccessibilityLabel("Agent profile for \(profile?.agentName ?? "agent")")
        setAccessibilityHelp("Hover to view this agent's profile.")
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 34),
            avatar.widthAnchor.constraint(equalToConstant: 28),
            avatar.heightAnchor.constraint(equalToConstant: 28),
            avatar.centerXAnchor.constraint(equalTo: centerXAnchor),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(
        color: NSColor,
        isActive: Bool,
        avatarURL: URL?,
        profile: NativeAgentProfilePayload?
    ) {
        if self.profile?.agentName != profile?.agentName {
            dismissProfilePopover()
        }
        self.profile = profile
        setAccessibilityLabel("Agent profile for \(profile?.agentName ?? "agent")")
        bgLayer.fillColor = color.withAlphaComponent(isActive ? 0.12 : 0.08).cgColor
        strokeLayer.strokeColor = color.withAlphaComponent(isActive ? 0.30 : 0.16).cgColor
        // Comet profile: transparent tail rising to a bright head.
        ringGradient.colors = [
            color.withAlphaComponent(0).cgColor,
            color.withAlphaComponent(0.10).cgColor,
            color.withAlphaComponent(0.95).cgColor,
            color.cgColor
        ]
        ringGradient.locations = [0, 0.35, 0.92, 1]
        ringGradient.isHidden = !isActive
        if let nsImage = AgentImageLoader.image(at: avatarURL) {
            avatar.image = nsImage
            avatar.imageScaling = .scaleProportionallyUpOrDown
            avatar.contentTintColor = nil
        } else {
            avatar.image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 0, weight: .medium, scale: .medium))
            avatar.imageScaling = .scaleNone
            avatar.contentTintColor = color
        }
        if isActive { startSpin() } else { ringGradient.removeAnimation(forKey: "spin") }
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        hoverDismissWorkItem?.cancel()
        hoverShowWorkItem?.cancel()
        guard profile != nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isPointerInside else { return }
            self.showProfilePopover()
        }
        hoverShowWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: item)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        scheduleProfilePopoverDismissal()
    }

    private func showProfilePopover() {
        guard profilePopover?.isShown != true, let profile, window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = PiAgentNativeProfilePopoverController(profile: profile) { [weak self] isInside in
            self?.isPointerInsideProfilePopover = isInside
            if isInside {
                self?.hoverDismissWorkItem?.cancel()
            } else {
                self?.scheduleProfilePopoverDismissal()
            }
        }
        profilePopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
    }

    private func scheduleProfilePopoverDismissal() {
        hoverDismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isPointerInside, !self.isPointerInsideProfilePopover else { return }
            self.dismissProfilePopover()
        }
        hoverDismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    func popoverDidClose(_ notification: Notification) {
        // NSPopover may close itself (for example, from Escape). Ignore a delayed
        // callback from an older popover so it cannot clear a newer one.
        guard let popover = notification.object as? NSPopover, popover === profilePopover else { return }
        isPointerInsideProfilePopover = false
        profilePopover = nil
    }

    func dismissProfilePopover() {
        hoverShowWorkItem?.cancel()
        hoverShowWorkItem = nil
        hoverDismissWorkItem?.cancel()
        hoverDismissWorkItem = nil
        isPointerInsideProfilePopover = false
        profilePopover?.close()
        profilePopover = nil
    }

    private func startSpin() {
        guard ringGradient.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        // Positive z-rotation reads CLOCKWISE here: the glyph view is flipped
        // (top-left origin), which visually inverts CA's rotation direction.
        // Clockwise also keeps the conic comet's bright head leading its tail.
        spin.fromValue = 0; spin.toValue = 2 * Double.pi
        spin.duration = 1.4; spin.repeatCount = .infinity
        ringGradient.add(spin, forKey: "spin")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let circle = CGPath(ellipseIn: bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        bgLayer.path = circle; strokeLayer.path = circle
        bgLayer.frame = bounds; strokeLayer.frame = bounds
        ringGradient.frame = bounds
        ringGradient.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ringGradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ringMask.frame = CGRect(origin: .zero, size: bounds.size)
        ringMask.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        CATransaction.commit()
        // CA drops repeating animations when the layer leaves the tree (cell
        // scrolled offscreen and back) — re-arm if the run is still active.
        if !ringGradient.isHidden { startSpin() }
    }
}

// MARK: - Capped + expandable markdown

/// Task preview that, when collapsed, shows a clean N-line plain-text excerpt with
/// a trailing ellipsis (no mid-line pixel clip, no fade); when expanded, renders
/// the full markdown. The markdown is only built on expand, so collapsed rows stay
/// cheap. The "Show more"/"Show less" toggle drives the re-measure hook.
final class PiAgentNativeExpandableMarkdown: NSView {
    private let wrapper = NSView()
    private let collapsedLabel = NSTextField(wrappingLabelWithString: "")
    private let container = NativeMarkdownTextContainer()
    private let applier = MarkdownSourceApplier()
    private let toggle = NSButton(title: "", target: nil, action: nil)

    private var wrapperHeightC: NSLayoutConstraint!
    private(set) var isExpanded = false
    var collapsedLineLimit = 4
    var onToggle: (() -> Void)?

    private var source = ""
    private var didBuildMarkdown = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wrapper)

        collapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        collapsedLabel.font = NativeTranscriptFont.body()
        collapsedLabel.textColor = .labelColor
        collapsedLabel.maximumNumberOfLines = collapsedLineLimit
        // Wrap each paragraph normally and ellipsize only when the whole excerpt
        // overflows the line limit. `.byTruncatingTail` would instead clip every
        // long paragraph to a single line with its own ellipsis.
        collapsedLabel.lineBreakMode = .byWordWrapping
        collapsedLabel.cell?.truncatesLastVisibleLine = true
        wrapper.addSubview(collapsedLabel)

        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true
        wrapper.addSubview(container)

        // A tight text label (not an NSButton, which carries inline-bezel vertical
        // padding that reads as extra bottom space below the card content).
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.font = NativeTranscriptFont.caption(.semibold)
        toggle.contentTintColor = AppTheme.ns(AppTheme.brandAccent)
        toggle.isBordered = false
        toggle.alignment = .left
        toggle.target = self
        toggle.action = #selector(toggleTapped)
        toggle.toolTip = "Show more or less task detail"
        toggle.setAccessibilityLabel("Show more or less task detail")
        toggle.isHidden = true
        addSubview(toggle)

        wrapperHeightC = wrapper.heightAnchor.constraint(equalToConstant: 0)
        // The view's bottom is the toggle's bottom when the toggle is shown, else
        // the wrapper's bottom — a hidden toggle must NOT reserve layout space
        // (otherwise non-truncated rows measure short and crop).
        toggleBottomC = toggle.bottomAnchor.constraint(equalTo: bottomAnchor)
        wrapperBottomC = wrapper.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            wrapper.topAnchor.constraint(equalTo: topAnchor),
            wrapper.leadingAnchor.constraint(equalTo: leadingAnchor),
            wrapper.trailingAnchor.constraint(equalTo: trailingAnchor),
            wrapperHeightC,
            collapsedLabel.topAnchor.constraint(equalTo: wrapper.topAnchor),
            collapsedLabel.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            collapsedLabel.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            container.topAnchor.constraint(equalTo: wrapper.topAnchor),
            container.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            toggle.topAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: 4),
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor)
        ])
        wrapperBottomC.isActive = true
    }

    private var toggleBottomC: NSLayoutConstraint!
    private var wrapperBottomC: NSLayoutConstraint!
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(source: String) {
        if source != self.source { isExpanded = false; didBuildMarkdown = false; self.source = source }
        collapsedLabel.stringValue = Self.plainPreview(source)
        if isExpanded { buildMarkdownIfNeeded() }
    }

    private func buildMarkdownIfNeeded() {
        applier.apply(source: source, to: container)
        didBuildMarkdown = true
    }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        collapsedLabel.preferredMaxLayoutWidth = width
        collapsedLabel.maximumNumberOfLines = collapsedLineLimit
        let collapsedH = ceil(collapsedLabel.intrinsicContentSize.height)
        collapsedLabel.maximumNumberOfLines = 0
        let fullPlainH = ceil(collapsedLabel.intrinsicContentSize.height)
        collapsedLabel.maximumNumberOfLines = collapsedLineLimit
        let truncated = fullPlainH > collapsedH + 1

        toggle.isHidden = !truncated
        toggle.stringValue = isExpanded ? "Show less" : "Show more"
        // Only let the toggle define the bottom when it's actually shown. Swap the
        // two bottom pins deactivate-FIRST: activating one while the other is still
        // active leaves both pinned to self.bottom for an instant, which AppKit
        // evaluates eagerly as an unsatisfiable system (constraint-conflict storm +
        // solver thrash that shows up as 100ms+ retiles).
        if truncated {
            wrapperBottomC.isActive = false
            toggleBottomC.isActive = true
        } else {
            toggleBottomC.isActive = false
            wrapperBottomC.isActive = true
        }
        let toggleH = truncated ? ceil(toggle.intrinsicContentSize.height) + 4 : 0

        if isExpanded {
            buildMarkdownIfNeeded()
            collapsedLabel.isHidden = true
            container.isHidden = false
            let h = container.measureHeight(forWidth: width)
            wrapperHeightC.constant = h
            return ceil(h + toggleH)
        } else {
            collapsedLabel.isHidden = false
            container.isHidden = true
            wrapperHeightC.constant = collapsedH
            return ceil(collapsedH + toggleH)
        }
    }

    @objc private func toggleTapped() { isExpanded.toggle(); onToggle?() }
    func cancel() { applier.cancel() }

    /// Light markdown→plain strip for the collapsed excerpt: drop leading list /
    /// heading / quote markers and inline emphasis characters, keep line breaks.
    static func plainPreview(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = String(line)
            l = l.replacingOccurrences(of: #"^\s*(#{1,6}\s+|[-*+]\s+|\d+[.)]\s+|>\s?)"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
            return l
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Reusable agent block

/// One agent's block: glyph + name (+ outcome pill) + status·metrics line + icon
/// actions on the right, then the capped/expandable task. No inner box.
final class PiAgentNativeAgentBlockView: NSView {
    private let glyph = PiAgentNativeSubagentGlyph()
    private let nameLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let tokensLabel = NSTextField(labelWithString: "")
    private let outcomePill = NSTextField(labelWithString: "")
    private let outcomeCapsule = NativeCardSurface()
    private let metaLabel = NSTextField(labelWithString: "")
    private let buttonStack = NSStackView()
    let task = PiAgentNativeExpandableMarkdown()

    private var actions: [NativeAgentBlockPayload.Action] = []
    var onToggle: (() -> Void)? { didSet { task.onToggle = onToggle } }

    private let headerToTask: CGFloat = 12

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NativeTranscriptFont.body(.semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Model identifier beside the name — bare condensed text via the
        // shared AppTheme.IdentifierPill style. No wrapping view; the row
        // centers mixed font sizes so their visible glyphs align optically.
        modelLabel.font = AppTheme.IdentifierPill.nsFont()
        modelLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        modelLabel.setContentHuggingPriority(.required, for: .horizontal)
        modelLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Token count beside the pill: muted, truncates before the name does.
        tokensLabel.font = NativeTranscriptFont.callout()
        tokensLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        tokensLabel.lineBreakMode = .byTruncatingTail
        tokensLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        tokensLabel.setContentHuggingPriority(.required, for: .horizontal)

        outcomePill.font = NativeTranscriptFont.caption2(.medium)
        outcomePill.textColor = AppTheme.ns(AppTheme.mutedText)
        outcomePill.translatesAutoresizingMaskIntoConstraints = false
        outcomeCapsule.translatesAutoresizingMaskIntoConstraints = false
        outcomeCapsule.cardCornerRadius = 5
        outcomeCapsule.fillColor = AppTheme.ns(AppTheme.contentSubtleFill.opacity(0.7))
        outcomeCapsule.strokeColor = AppTheme.ns(AppTheme.contentStroke)
        outcomeCapsule.addSubview(outcomePill)
        outcomeCapsule.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            outcomePill.leadingAnchor.constraint(equalTo: outcomeCapsule.leadingAnchor, constant: 6),
            outcomePill.trailingAnchor.constraint(equalTo: outcomeCapsule.trailingAnchor, constant: -6),
            outcomePill.topAnchor.constraint(equalTo: outcomeCapsule.topAnchor, constant: 2),
            outcomePill.bottomAnchor.constraint(equalTo: outcomeCapsule.bottomAnchor, constant: -2)
        ])

        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let nameRow = NSStackView(views: [nameLabel, modelLabel, tokensLabel])
        nameRow.orientation = .horizontal
        nameRow.spacing = 8
        nameRow.alignment = .centerY
        let titleStack = NSStackView(views: [nameRow, metaLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        buttonStack.orientation = .horizontal
        buttonStack.spacing = 2

        let headerStack = NSStackView(views: [glyph, titleStack, NSView(), buttonStack])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.spacing = 10
        headerStack.alignment = .centerY

        addSubview(headerStack)
        addSubview(task)

        let taskBottom = task.bottomAnchor.constraint(equalTo: bottomAnchor)
        taskBottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            task.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: headerToTask),
            task.leadingAnchor.constraint(equalTo: leadingAnchor),
            task.trailingAnchor.constraint(equalTo: trailingAnchor),
            taskBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(_ payload: NativeAgentBlockPayload) {
        let profile = NativeAgentProfilePayload(
            agentName: payload.agentName,
            agentDescription: payload.agentDescription,
            whenToUse: payload.whenToUse,
            modelText: payload.modelText,
            avatarURL: payload.avatarURL,
            accentColor: payload.statusColor
        )
        glyph.configure(
            color: payload.statusColor,
            isActive: payload.isActive,
            avatarURL: payload.avatarURL,
            profile: profile
        )
        nameLabel.stringValue = payload.agentName
        modelLabel.stringValue = payload.modelText ?? ""
        modelLabel.isHidden = (payload.modelText?.isEmpty ?? true)
        tokensLabel.stringValue = payload.tokensText ?? ""
        tokensLabel.isHidden = (payload.tokensText?.isEmpty ?? true)
        metaLabel.attributedStringValue = metaLine(payload)
        setStatusShimmer(payload.isActive)
        task.configure(source: payload.task)
        rebuildButtons(payload.actions)
    }

    // MARK: Status shimmer (active runs)

    /// While the run is active, a soft highlight sweeps across the status line —
    /// the "Codex shimmer". Implemented as a repeating CABasicAnimation on a
    /// gradient mask over the label's own layer, so the animation is composited
    /// entirely by the render server: zero main-thread work per frame, no layout,
    /// no SwiftUI invalidation. The base alpha keeps the text readable; only the
    /// moving band brightens to full.
    private func setStatusShimmer(_ active: Bool) {
        guard active else {
            metaLabel.layer?.mask = nil
            return
        }
        metaLabel.wantsLayer = true
        if metaLabel.layer?.mask == nil {
            let gradient = CAGradientLayer()
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            let base = NSColor.white.withAlphaComponent(0.55).cgColor
            gradient.colors = [base, NSColor.white.cgColor, base]
            gradient.locations = [0, 0.5, 1]
            metaLabel.layer?.mask = gradient
        }
        startShimmerSweepIfNeeded()
    }

    /// (Re)attach the sweep animation. CA drops repeating animations whenever the
    /// layer leaves the layer tree (cell scrolled offscreen, window changes), so
    /// `layout()` re-arms it — same pattern as the glyph's spin.
    private func startShimmerSweepIfNeeded() {
        guard let mask = metaLabel.layer?.mask, mask.animation(forKey: "shimmer") == nil else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-1.0, -0.5, 0.0]
        sweep.toValue = [1.0, 1.5, 2.0]
        sweep.duration = 1.6
        sweep.repeatCount = .infinity
        mask.add(sweep, forKey: "shimmer")
    }

    override func layout() {
        super.layout()
        guard let mask = metaLabel.layer?.mask else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = metaLabel.layer?.bounds ?? .zero
        CATransaction.commit()
        startShimmerSweepIfNeeded()
    }

    private func metaLine(_ payload: NativeAgentBlockPayload) -> NSAttributedString {
        let muted = AppTheme.ns(AppTheme.mutedText)
        let result = NSMutableAttributedString()
        // No status dot — the colored status word (Running / Completed / Blocked)
        // already carries the state. Only the elapsed time follows it.
        result.append(NSAttributedString(string: payload.statusText, attributes: [.foregroundColor: payload.statusColor, .font: NativeTranscriptFont.caption(.semibold)]))
        if let duration = payload.durationText {
            result.append(NSAttributedString(string: "   " + duration, attributes: [.foregroundColor: muted, .font: NativeTranscriptFont.caption()]))
        }
        return result
    }

    private func rebuildButtons(_ payloadActions: [NativeAgentBlockPayload.Action]) {
        actions = payloadActions
        buttonStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let base = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let muted = AppTheme.ns(AppTheme.mutedText)
        for (i, action) in actions.enumerated() {
            let b: NSButton
            if action.isDestructive {
                // Quiet at rest (muted outline) like its sibling icons; on hover it
                // fills in white-on-red to flag the destructive action only when
                // reached for, instead of always shouting in the row.
                let restSymbol = action.symbol.replacingOccurrences(of: ".fill", with: "")
                let rest = NSImage(systemSymbolName: restSymbol, accessibilityDescription: action.help)?
                    .withSymbolConfiguration(base)
                let hover = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.help)?
                    .withSymbolConfiguration(base.applying(.init(paletteColors: [.white, .systemRed])))
                hover?.isTemplate = false
                let hb = HoverDestructiveButton(image: rest ?? NSImage(), target: self, action: #selector(actionTapped(_:)))
                hb.restImage = rest
                hb.hoverImage = hover
                hb.restTint = muted
                b = hb
            } else {
                let image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.help)?
                    .withSymbolConfiguration(base)
                b = NSButton(image: image ?? NSImage(), target: self, action: #selector(actionTapped(_:)))
            }
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.tag = i
            b.isEnabled = action.isEnabled
            b.contentTintColor = muted
            b.toolTip = action.help
            b.widthAnchor.constraint(equalToConstant: AppTheme.Control.regularActionTarget).isActive = true
            b.heightAnchor.constraint(equalToConstant: AppTheme.Control.regularActionTarget).isActive = true
            b.setAccessibilityLabel(action.help)
            buttonStack.addArrangedSubview(b)
        }
    }

    @objc private func actionTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        actions[sender.tag].run(sender)
    }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        let nameH = ceil(nameLabel.intrinsicContentSize.height)
        let metaH = ceil(metaLabel.intrinsicContentSize.height)
        // The name row hugs the tallest of the name and the model identifier
        // text, so the status line below it never gets clipped.
        let modelH = modelLabel.isHidden ? 0 : ceil(modelLabel.intrinsicContentSize.height)
        let nameRowH = max(nameH, modelH)
        let headerH = max(34, nameRowH + 3 + metaH)
        let taskH = task.measuredHeight(forWidth: width)
        return ceil(headerH + headerToTask + taskH)
    }

    func cancel() {
        glyph.dismissProfilePopover()
        task.cancel()
    }
}

// MARK: - Single subagent card

final class PiAgentNativeSubagentRunCardView: NSView, PiAgentNativeRowContent {
    private let surface = NativeCardSurface()
    private let block = PiAgentNativeAgentBlockView()
    var onIntrinsicHeightChange: (() -> Void)?
    private let pad: CGFloat = 16
    private var surfaceWidthC: NSLayoutConstraint!

    required init() {
        super.init(frame: .zero)
        wantsLayer = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = 16
        addSubview(surface)
        block.onToggle = { [weak self] in self?.onIntrinsicHeightChange?() }
        surface.addSubview(block)
        let blockBottom = block.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -pad)
        blockBottom.priority = NSLayoutConstraint.Priority(999)
        // Cap to the reply column width (left-aligned), like assistant replies.
        surfaceWidthC = surface.widthAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceWidthC,
            block.topAnchor.constraint(equalTo: surface.topAnchor, constant: pad),
            block.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            block.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            blockBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    private func cardWidth(_ rowWidth: CGFloat) -> CGFloat {
        max(1, min(rowWidth, PiAgentBubbleWidth.replyCap(for: rowWidth)))
    }

    func configure(payload: NativeAgentBlockPayload, width rowWidth: CGFloat) {
        surface.fillColor = AppTheme.ns(AppTheme.Chat.cardFill)
        surface.strokeColor = AppTheme.ns(AppTheme.Chat.cardStroke)
        surfaceWidthC.constant = cardWidth(rowWidth)
        block.configure(payload)
        needsLayout = true
    }

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        ceil(pad + block.measuredHeight(forWidth: max(1, cardWidth(rowWidth) - pad * 2)) + pad)
    }

    func prepareForReuseIfNeeded() { block.cancel() }
}

// MARK: - Parallel subagent card (one outline, stacked agent cards)

final class PiAgentNativeSubagentParallelCardView: NSView, PiAgentNativeRowContent {
    private let surface = NativeCardSurface()
    private let headerLabel = NSTextField(labelWithString: "")
    private let childStack = NSStackView()
    private var blocks: [PiAgentNativeAgentBlockView] = []
    private var childSurfaces: [NativeCardSurface] = []
    var onIntrinsicHeightChange: (() -> Void)?

    private let pad: CGFloat = 16
    private let childPad: CGFloat = 14
    private let childSpacing: CGFloat = 10
    // Single-line header height: NSTextField's intrinsic height for a 14pt
    // semibold run comes up a hair short and clips descenders, so pin a floor.
    private let headerHeight: CGFloat = 18
    private var surfaceWidthC: NSLayoutConstraint!

    required init() {
        super.init(frame: .zero)
        wantsLayer = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = 16
        addSubview(surface)

        // Shared transcript header scale, matching the memory / web / diff / status
        // card titles so every card reads at one size.
        headerLabel.font = NativeTranscriptFont.header
        headerLabel.maximumNumberOfLines = 1
        headerLabel.lineBreakMode = .byTruncatingTail
        childStack.translatesAutoresizingMaskIntoConstraints = false
        childStack.orientation = .vertical
        childStack.alignment = .leading
        childStack.spacing = childSpacing
        surface.addSubview(headerLabel)
        surface.addSubview(childStack)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let stackBottom = childStack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -pad)
        stackBottom.priority = NSLayoutConstraint.Priority(999)
        surfaceWidthC = surface.widthAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceWidthC,
            headerLabel.topAnchor.constraint(equalTo: surface.topAnchor, constant: pad),
            headerLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            headerLabel.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            headerLabel.heightAnchor.constraint(equalToConstant: headerHeight),
            childStack.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            childStack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            childStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            stackBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    private func cardWidth(_ rowWidth: CGFloat) -> CGFloat {
        max(1, min(rowWidth, PiAgentBubbleWidth.replyCap(for: rowWidth)))
    }

    func configure(payload: NativeSubagentParallelPayload, width rowWidth: CGFloat) {
        // Outer is an outline only (no fill) so the child cards are the single grey
        // layer — avoids grey-in-grey-in-grey.
        surface.fillColor = .clear
        surface.strokeColor = AppTheme.ns(AppTheme.Chat.cardStroke)
        surfaceWidthC.constant = cardWidth(rowWidth)
        headerLabel.attributedStringValue = headerLine(payload)

        // Rebuild child cards if the count changed; otherwise reconfigure in place.
        if blocks.count != payload.children.count {
            childStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            blocks.removeAll(); childSurfaces.removeAll()
            for _ in payload.children {
                let card = NativeCardSurface()
                card.translatesAutoresizingMaskIntoConstraints = false
                card.cardCornerRadius = 12
                let blk = PiAgentNativeAgentBlockView()
                blk.onToggle = { [weak self] in self?.onIntrinsicHeightChange?() }
                card.addSubview(blk)
                let b = blk.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -childPad)
                b.priority = NSLayoutConstraint.Priority(999)
                NSLayoutConstraint.activate([
                    blk.topAnchor.constraint(equalTo: card.topAnchor, constant: childPad),
                    blk.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: childPad),
                    blk.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -childPad),
                    b
                ])
                childStack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: childStack.widthAnchor).isActive = true
                blocks.append(blk); childSurfaces.append(card)
            }
        }
        let childFill = AppTheme.ns(AppTheme.Chat.cardFill)
        for (i, child) in payload.children.enumerated() {
            childSurfaces[i].fillColor = childFill
            childSurfaces[i].strokeColor = AppTheme.ns(AppTheme.Chat.cardStroke)
            blocks[i].configure(child)
        }
        needsLayout = true
    }

    private func headerLine(_ payload: NativeSubagentParallelPayload) -> NSAttributedString {
        // Title only — the per-agent count and run status are already shown on
        // each child card below, so the header stays a single clean label.
        NSAttributedString(string: payload.title, attributes: [
            .font: NativeTranscriptFont.header,
            .foregroundColor: NSColor.labelColor
        ])
    }

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let childInner = max(1, cardWidth(rowWidth) - pad * 2 - childPad * 2)
        var h = pad + headerHeight + 12
        for (i, blk) in blocks.enumerated() {
            if i > 0 { h += childSpacing }
            h += childPad + blk.measuredHeight(forWidth: childInner) + childPad
        }
        h += pad
        return ceil(h)
    }

    func prepareForReuseIfNeeded() { blocks.forEach { $0.cancel() } }
}

// MARK: - Factories (computed in the items pass; views are dumb renderers)

enum NativeSubagentFactory {
    static func isParallel(_ run: PiSubagentRunRecord) -> Bool {
        run.mode == .parallel && (run.children?.isEmpty == false)
    }

    /// Bridges the shared themed status mapping to AppKit for the native cards —
    /// the glyph ring, status word, and fills all follow the active theme.
    @MainActor
    static func statusColor(_ status: PiSubagentRunStatus) -> NSColor {
        AppTheme.ns(status.themedColor)
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let t = value?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func formattedDuration(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m \(s % 60)s" }
        return "\(m / 60)h \(m % 60)m"
    }

    static func compactNumber(_ v: Int) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", Double(v) / 1_000_000) }
        if v >= 1_000 { return "\(v / 1_000)k" }
        return "\(v)"
    }

    /// Token count shown beside the model pill.
    static func tokensText(_ tokens: Int?) -> String? {
        guard let tokens else { return nil }
        return compactNumber(tokens) + " tokens"
    }

    /// Model + reasoning effort for the identifier pill, in the `model:thinking`
    /// form AI apps use (e.g. `opencode-go/mimo-v2.5:off`). Falls back to the
    /// model alone when there is no thinking value, and to nil with no model.
    static func modelChipText(model: String?, thinking: String?) -> String? {
        guard let model = nonEmpty(model) else { return nil }
        if let suffix = model.split(separator: ":").last,
           PiThinkingLevelCatalog.ordered.contains(String(suffix)) {
            return model
        }
        guard let thinking = nonEmpty(thinking) else { return model }
        return "\(model):\(thinking)"
    }

    static func showTextPopover(title: String, text: String, from sender: NSButton) {
        let pop = NSPopover(); pop.behavior = .transient
        pop.contentViewController = PiAgentNativeTextPopoverController(title: title, text: text)
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
}

extension NativeAgentBlockPayload {
    /// Single-run block built from a run record.
    @MainActor
    static func makeSingle(
        run: PiSubagentRunRecord,
        agent: EffectiveAgentRecord?,
        imageStore: AgentImageStore,
        onStop: @escaping () -> Void,
        onTranscript: @escaping () -> Void,
        onReveal: @escaping () -> Void
    ) -> NativeAgentBlockPayload {
        let artifactDir = run.child?.artifactDirectory ?? run.artifactDirectory
        let sysPromptURL = URL(fileURLWithPath: artifactDir).appendingPathComponent("final-system-prompt.md")
        let canSys = FileManager.default.fileExists(atPath: sysPromptURL.path)

        let duration = run.child?.durationMs ?? run.durationMs
        let tokens = run.child?.totalTokens ?? sum(run.children?.compactMap(\.totalTokens))
        let tools = run.child?.toolCount ?? sum(run.children?.compactMap(\.toolCount))
        let model = run.model ?? run.child?.model ?? run.children?.compactMap(\.model).first
        let cost = run.child?.cost ?? sumDouble(run.children?.compactMap(\.cost))

        var detailRows: [(String, String)] = []
        if let duration { detailRows.append(("Duration", NativeSubagentFactory.formattedDuration(duration))) }
        if let tokens { detailRows.append(("Tokens", NativeSubagentFactory.compactNumber(tokens))) }
        if let cost { detailRows.append(("Cost", String(format: "$%.2f", cost))) }
        if let tools { detailRows.append(("Tools", "\(tools)")) }
        if let model = NativeSubagentFactory.nonEmpty(model) { detailRows.append(("Model", model)) }
        if let thinking = NativeSubagentFactory.nonEmpty(run.thinking) { detailRows.append(("Thinking", thinking)) }
        if let outcome = run.expectedOutcome {
            detailRows.append(("Outcome", outcome.displayName + (run.requestedOutputPath.map { " · \($0)" } ?? "")))
        }
        let canReveal = !run.artifactDirectory.isEmpty

        var actions: [Action] = [
            Action(symbol: "info.circle", help: "Run details") { sender in
                let pop = NSPopover(); pop.behavior = .transient
                pop.contentViewController = PiAgentNativeKeyValuePopover(title: "Run details", rows: detailRows, revealAction: canReveal ? onReveal : nil)
                pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
            },
            Action(symbol: "doc.text.magnifyingglass", help: "Final runtime system prompt", isEnabled: canSys) { sender in
                let text = (try? String(contentsOf: sysPromptURL, encoding: .utf8)) ?? "System prompt unavailable."
                NativeSubagentFactory.showTextPopover(title: "Final Runtime System Prompt", text: text, from: sender)
            },
            Action(symbol: "text.bubble", help: "Open transcript") { _ in onTranscript() }
        ]
        if run.status.isActive {
            actions.append(Action(symbol: "stop.circle.fill", help: "Stop", isDestructive: true) { _ in onStop() })
        }

        return NativeAgentBlockPayload(
            agentName: run.agentName,
            agentDescription: NativeSubagentFactory.nonEmpty(agent?.resolved.description),
            whenToUse: NativeSubagentFactory.nonEmpty(agent?.resolved.whenToUse),
            statusText: run.status.rawValue.capitalized,
            statusColor: NativeSubagentFactory.statusColor(run.status),
            isActive: run.status.isActive,
            avatarURL: imageStore.imageURL(for: run.agentName),
            outcomePill: run.expectedOutcome?.displayName,
            task: run.task,
            durationText: duration.map { NativeSubagentFactory.formattedDuration($0) },
            modelText: NativeSubagentFactory.modelChipText(model: model, thinking: run.thinking),
            tokensText: NativeSubagentFactory.tokensText(tokens),
            actions: actions
        )
    }

    private static func sum(_ values: [Int]?) -> Int? {
        guard let values, !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private static func sumDouble(_ values: [Double]?) -> Double? {
        guard let values, !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }
}

extension NativeSubagentParallelPayload {
    @MainActor
    static func make(
        run: PiSubagentRunRecord,
        agentsByName: [String: EffectiveAgentRecord],
        imageStore: AgentImageStore,
        onOpenChildTranscript: @escaping (UUID) -> Void,
        onStopChild: @escaping (UUID) -> Void
    ) -> NativeSubagentParallelPayload {
        let children = (run.children ?? []).map { child -> NativeAgentBlockPayload in
            let task = NativeSubagentFactory.nonEmpty(child.task)
                ?? NativeSubagentFactory.nonEmpty(child.summary ?? child.error)
                ?? "No task captured."
            let sysURL = URL(fileURLWithPath: child.artifactDirectory ?? "").appendingPathComponent("final-system-prompt.md")
            let canSys = (child.artifactDirectory?.isEmpty == false) && FileManager.default.fileExists(atPath: sysURL.path)

            var actions: [NativeAgentBlockPayload.Action] = [
                .init(symbol: "doc.text.magnifyingglass", help: "Final runtime system prompt", isEnabled: canSys) { sender in
                    let text = (try? String(contentsOf: sysURL, encoding: .utf8)) ?? "System prompt unavailable."
                    NativeSubagentFactory.showTextPopover(title: "Final Runtime System Prompt", text: text, from: sender)
                }
            ]
            if let execID = child.executionRunID {
                actions.append(.init(symbol: "text.bubble", help: "Open transcript") { _ in onOpenChildTranscript(execID) })
                if child.status.isActive {
                    actions.append(.init(symbol: "stop.circle.fill", help: "Stop", isDestructive: true) { _ in onStopChild(execID) })
                }
            }

            return NativeAgentBlockPayload(
                agentName: child.agentName,
                agentDescription: NativeSubagentFactory.nonEmpty(agentsByName[child.agentName]?.resolved.description),
                whenToUse: NativeSubagentFactory.nonEmpty(agentsByName[child.agentName]?.resolved.whenToUse),
                statusText: child.status.rawValue.capitalized,
                statusColor: NativeSubagentFactory.statusColor(child.status),
                isActive: child.status.isActive,
                avatarURL: imageStore.imageURL(for: child.agentName),
                outcomePill: child.expectedOutcome?.displayName,
                task: task,
                durationText: child.durationMs.map { NativeSubagentFactory.formattedDuration($0) },
                modelText: NativeSubagentFactory.modelChipText(model: child.model, thinking: child.thinking),
                tokensText: NativeSubagentFactory.tokensText(child.totalTokens),
                actions: actions
            )
        }
        return NativeSubagentParallelPayload(
            title: "Parallel agents",
            count: children.count,
            statusText: run.status.rawValue.capitalized,
            statusColor: NativeSubagentFactory.statusColor(run.status),
            children: children
        )
    }
}

// MARK: - Agent profile hover card

/// Reports pointer transitions so the glyph can keep its hover popover open while
/// its scrollable content is being read or scrolled.
private final class PiAgentNativeProfilePopoverContentView: NSView {
    var onPointerInsideChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onPointerInsideChange?(true) }
    override func mouseExited(with event: NSEvent) { onPointerInsideChange?(false) }
}

private final class PiAgentNativeProfilePopoverController: NSViewController {
    private let profile: NativeAgentProfilePayload
    private let onPointerInsideChange: (Bool) -> Void

    init(profile: NativeAgentProfilePayload, onPointerInsideChange: @escaping (Bool) -> Void) {
        self.profile = profile
        self.onPointerInsideChange = onPointerInsideChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let content = PiAgentNativeProfilePopoverContentView()
        content.onPointerInsideChange = onPointerInsideChange
        let scrollView = NSScrollView()
        let document = NSView()
        let stack = NSStackView()
        let width: CGFloat = 340
        let maximumHeight: CGFloat = 420

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        document.addSubview(stack)
        scrollView.documentView = document
        content.addSubview(scrollView)

        let avatar = NSImageView()
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 23
        avatar.layer?.masksToBounds = true
        avatar.layer?.borderWidth = 1
        avatar.layer?.borderColor = profile.accentColor.withAlphaComponent(0.45).cgColor
        if let image = AgentImageLoader.image(at: profile.avatarURL) {
            avatar.image = image
        } else {
            avatar.image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 20, weight: .medium))
            avatar.contentTintColor = profile.accentColor
            avatar.imageScaling = .scaleNone
        }
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 46),
            avatar.heightAnchor.constraint(equalToConstant: 46)
        ])

        let name = NSTextField(labelWithString: profile.agentName)
        name.font = NativeTranscriptFont.sectionTitle()
        name.maximumNumberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let role = NSTextField(labelWithString: "DECK AGENT")
        role.font = NativeTranscriptFont.caption2(.semibold)
        role.textColor = profile.accentColor

        let identity = NSStackView(views: [role, name])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 2
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let modelText = NativeSubagentFactory.nonEmpty(profile.modelText) {
            let model = NSTextField(labelWithString: modelText)
            model.font = AppTheme.IdentifierPill.nsFont()
            model.textColor = AppTheme.ns(AppTheme.mutedText)
            model.maximumNumberOfLines = 1
            model.lineBreakMode = .byTruncatingTail
            model.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            identity.addArrangedSubview(model)
        }

        let header = NSStackView(views: [avatar, identity])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        stack.addArrangedSubview(header)

        let description = NativeSubagentFactory.nonEmpty(profile.agentDescription)
        let whenToUse = NativeSubagentFactory.nonEmpty(profile.whenToUse)
        if description != nil || whenToUse != nil {
            stack.addArrangedSubview(divider())
        }
        if let description {
            stack.addArrangedSubview(profileSection(title: "Description", text: description))
        }
        if let whenToUse {
            stack.addArrangedSubview(profileSection(title: "When to use", text: whenToUse))
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: width),
            // Match the clip view instead of the popover's outer width so text
            // remains inside the visible column with legacy (non-overlay) scrollbars.
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor)
        ])
        view = content
        content.layoutSubtreeIfNeeded()
        var naturalHeight = ceil(stack.fittingSize.height)
        if naturalHeight > maximumHeight {
            // Temporarily reserve a legacy scroller's width before measuring the
            // wrapped prose; the final document stays constrained to the clip view.
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = false
            content.layoutSubtreeIfNeeded()
            naturalHeight = ceil(stack.fittingSize.height)
            scrollView.autohidesScrollers = true
        }
        let documentHeight = document.heightAnchor.constraint(equalToConstant: naturalHeight)
        NSLayoutConstraint.activate([
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            documentHeight
        ])
        scrollView.hasVerticalScroller = naturalHeight > maximumHeight
        preferredContentSize = NSSize(width: width, height: min(maximumHeight, naturalHeight))
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func profileSection(title: String, text: String) -> NSView {
        let heading = NSTextField(labelWithString: title.uppercased())
        heading.font = NativeTranscriptFont.caption2(.semibold)
        heading.textColor = AppTheme.ns(AppTheme.mutedText)

        let body = NSTextField(wrappingLabelWithString: text)
        body.font = NativeTranscriptFont.callout()
        body.textColor = .labelColor
        body.maximumNumberOfLines = 0
        body.isSelectable = true

        let section = NSStackView(views: [heading, body])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 5
        body.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }
}

// MARK: - Native key/value popover (run details)

final class PiAgentNativeKeyValuePopover: NSViewController {
    private let titleText: String
    private let rows: [(String, String)]
    private let revealAction: (() -> Void)?

    init(title: String, rows: [(String, String)], revealAction: (() -> Void)?) {
        self.titleText = title; self.rows = rows; self.revealAction = revealAction
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let title = NSTextField(labelWithString: titleText)
        title.font = NativeTranscriptFont.sectionTitle()
        stack.addArrangedSubview(title)

        for (k, v) in rows {
            let key = NSTextField(labelWithString: k)
            key.font = NativeTranscriptFont.caption(.semibold)
            key.textColor = AppTheme.ns(AppTheme.mutedText)
            key.setContentHuggingPriority(.required, for: .horizontal)
            let val = NSTextField(labelWithString: v)
            val.font = NativeTranscriptFont.caption()
            val.isSelectable = true
            val.lineBreakMode = .byTruncatingMiddle
            let row = NSStackView(views: [key, val])
            row.orientation = .horizontal
            row.spacing = 10
            stack.addArrangedSubview(row)
        }
        if revealAction != nil {
            let reveal = NSButton(title: "Reveal Run Folder", target: self, action: #selector(revealTapped))
            reveal.bezelStyle = .rounded
            reveal.controlSize = .small
            stack.addArrangedSubview(reveal)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 430)
        ])
        view = container
    }

    @objc private func revealTapped() { revealAction?() }
}

/// An icon button that stays quiet (muted template) at rest and swaps to a louder
/// image on hover — used for the destructive Stop control so it reads calm in the
/// action row but fills in white-on-red when reached for.
private final class HoverDestructiveButton: NSButton {
    var restImage: NSImage?
    var hoverImage: NSImage?
    var restTint: NSColor?
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        image = hovered ? hoverImage : restImage
        contentTintColor = hovered ? nil : restTint   // nil lets the hover image's palette colors show.
    }
}
