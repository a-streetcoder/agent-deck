import AppKit
import SwiftUI

// Native (pure AppKit) "Deck agent run" summary card — the content shown for an
// assistant entry that carries a PiAgentSubagentSummary. Plain text (no markdown),
// rendered as a flat list of agents so it stays cheap on scroll and avoids the
// hosted SwiftUI rebuild.

struct NativeSubagentSummaryPayload {
    var title: String
    var isRunning: Bool
    var metrics: [Metric]
    var agents: [Agent]

    struct Metric { var text: String; var color: NSColor }
    struct Agent {
        var icon: String
        var color: NSColor
        var name: String
        var meta: String
        var detail: String?     // output path or task
        var detailIsMono: Bool
    }
}

extension NativeSubagentSummaryPayload {
    @MainActor
    static func make(summary: PiAgentSubagentSummary) -> NativeSubagentSummaryPayload {
        let countText = summary.total == 1 ? "1 agent" : "\(summary.total) agents"
        var metrics: [Metric] = [.init(text: "\(summary.completed)/\(summary.total) done", color: .systemGreen)]
        if summary.running > 0 { metrics.append(.init(text: "\(summary.running) running", color: .systemOrange)) }
        if summary.failed > 0 { metrics.append(.init(text: "\(summary.failed) failed", color: .systemRed)) }

        let agents = summary.agents.map { agent -> Agent in
            let detailPath = agent.outputPath ?? agent.sessionFile
            return Agent(
                icon: icon(for: agent.status),
                color: color(for: agent.status),
                name: agent.name,
                meta: meta(for: agent),
                detail: detailPath ?? (agent.task.flatMap { $0.isEmpty ? nil : $0 }),
                detailIsMono: detailPath != nil
            )
        }
        return NativeSubagentSummaryPayload(
            title: "\(summary.mode) · \(countText)",
            isRunning: summary.running > 0,
            metrics: metrics,
            agents: agents
        )
    }

    private static func meta(for agent: PiAgentSubagentSummary.Agent) -> String {
        [
            agent.context.map { "[\($0)]" },
            agent.toolCount.map { "\($0) tools" },
            agent.tokens.map { "\(formatTokens($0)) token" },
            agent.durationMs.map { formatDuration($0) }
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private static func icon(for status: String) -> String {
        switch status {
        case "completed", "ok": return "checkmark"
        case "failed": return "xmark"
        case "paused", "needs_attention": return "exclamationmark"
        default: return "ellipsis"
        }
    }
    private static func color(for status: String) -> NSColor {
        switch status {
        case "completed", "ok": return .systemGreen
        case "failed": return .systemRed
        case "paused", "needs_attention": return .systemOrange
        default: return .systemCyan
        }
    }
    private static func formatTokens(_ t: Int) -> String { t >= 1000 ? "\(t / 1000)k" : "\(t)" }
    private static func formatDuration(_ ms: Int) -> String {
        let s = ms / 1000
        return s >= 60 ? "\(s / 60)m\(s % 60)s" : "\(s)s"
    }
}

final class PiAgentNativeSubagentSummaryView: NSView, PiAgentNativeRowContent {
    private let surface = NativeCardSurface()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let metricsStack = NSStackView()
    private let agentsStack = NSStackView()
    private var agentRows: [AgentRow] = []
    var onIntrinsicHeightChange: (() -> Void)?

    private let pad: CGFloat = 14
    private let agentSpacing: CGFloat = 8
    private var surfaceWidthC: NSLayoutConstraint!

    required init() {
        super.init(frame: .zero)
        wantsLayer = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = AppTheme.Chat.cardCornerRadius
        addSubview(surface)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "person.2.wave.2", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NativeTranscriptFont.calloutSize, weight: .semibold))
        iconView.contentTintColor = .systemCyan
        titleLabel.font = NativeTranscriptFont.callout(.semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let header = NSStackView(views: [iconView, titleLabel, spinner, NSView()])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY

        metricsStack.translatesAutoresizingMaskIntoConstraints = false
        metricsStack.orientation = .horizontal
        metricsStack.spacing = 8

        agentsStack.translatesAutoresizingMaskIntoConstraints = false
        agentsStack.orientation = .vertical
        agentsStack.alignment = .leading
        agentsStack.spacing = agentSpacing

        surface.addSubview(header)
        surface.addSubview(metricsStack)
        surface.addSubview(agentsStack)
        surfaceWidthC = surface.widthAnchor.constraint(equalToConstant: 100)

        let agentsBottom = agentsStack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -pad)
        agentsBottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceWidthC,
            header.topAnchor.constraint(equalTo: surface.topAnchor, constant: pad),
            header.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            header.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            metricsStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            metricsStack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            agentsStack.topAnchor.constraint(equalTo: metricsStack.bottomAnchor, constant: 12),
            agentsStack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            agentsStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            agentsBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    private func cardWidth(_ rowWidth: CGFloat) -> CGFloat {
        max(1, min(rowWidth, PiAgentBubbleWidth.replyCap(for: rowWidth)))
    }

    func configure(payload: NativeSubagentSummaryPayload, width rowWidth: CGFloat) {
        surface.fillColor = AppTheme.ns(AppTheme.Chat.cardFill)
        surface.strokeColor = AppTheme.ns(AppTheme.Chat.cardStroke)
        surfaceWidthC.constant = cardWidth(rowWidth)
        titleLabel.stringValue = payload.title
        if payload.isRunning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        metricsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for m in payload.metrics { metricsStack.addArrangedSubview(metricPill(m)) }

        if agentRows.count != payload.agents.count {
            agentsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            agentRows = payload.agents.map { _ in AgentRow() }
            for row in agentRows {
                agentsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: agentsStack.widthAnchor).isActive = true
            }
        }
        for (i, agent) in payload.agents.enumerated() { agentRows[i].configure(agent) }
        needsLayout = true
    }

    private func metricPill(_ m: NativeSubagentSummaryPayload.Metric) -> NSView {
        let pill = NativeCardSurface()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.cardCornerRadius = AppTheme.Chat.chipCornerRadius
        pill.fillColor = m.color.withAlphaComponent(0.12)
        pill.strokeColor = .clear
        let label = NSTextField(labelWithString: m.text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NativeTranscriptFont.caption(.semibold)
        label.textColor = m.color
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3)
        ])
        return pill
    }

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let inner = max(1, cardWidth(rowWidth) - pad * 2)
        let headerH: CGFloat = 18
        let metricsH = max(16, ceil((metricsStack.arrangedSubviews.first?.fittingSize.height) ?? 16))
        var h = pad + headerH + 8 + metricsH + 12
        for (i, row) in agentRows.enumerated() {
            if i > 0 { h += agentSpacing }
            h += row.measuredHeight(forWidth: inner)
        }
        h += pad
        return ceil(h)
    }

    // One agent row: status glyph + name/meta + optional detail line.
    private final class AgentRow: NSView {
        private let icon = NSImageView()
        private let nameLabel = NSTextField(labelWithString: "")
        private let metaLabel = NSTextField(labelWithString: "")
        private let detailLabel = NSTextField(wrappingLabelWithString: "")
        private var detailToText: NSLayoutConstraint!

        init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.setContentHuggingPriority(.required, for: .horizontal)
            nameLabel.font = NativeTranscriptFont.callout(.semibold)
            nameLabel.lineBreakMode = .byTruncatingTail
            metaLabel.font = NativeTranscriptFont.captionMono()
            metaLabel.textColor = AppTheme.ns(AppTheme.mutedText)
            metaLabel.lineBreakMode = .byTruncatingTail
            detailLabel.font = NativeTranscriptFont.caption()
            detailLabel.textColor = AppTheme.ns(AppTheme.mutedText)
            detailLabel.lineBreakMode = .byTruncatingTail
            detailLabel.maximumNumberOfLines = 2

            let nameRow = NSStackView(views: [nameLabel, metaLabel])
            nameRow.orientation = .horizontal
            nameRow.spacing = 6
            nameRow.alignment = .firstBaseline
            let textStack = NSStackView(views: [nameRow, detailLabel])
            textStack.translatesAutoresizingMaskIntoConstraints = false
            textStack.orientation = .vertical
            textStack.alignment = .leading
            textStack.spacing = 4

            addSubview(icon)
            addSubview(textStack)
            let bottom = textStack.bottomAnchor.constraint(equalTo: bottomAnchor)
            bottom.priority = NSLayoutConstraint.Priority(999)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor),
                icon.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                icon.widthAnchor.constraint(equalToConstant: 18),
                textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
                textStack.trailingAnchor.constraint(equalTo: trailingAnchor),
                textStack.topAnchor.constraint(equalTo: topAnchor),
                bottom
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var isFlipped: Bool { true }

        func configure(_ agent: NativeSubagentSummaryPayload.Agent) {
            icon.image = NSImage(systemSymbolName: agent.icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: NativeTranscriptFont.captionSize, weight: .bold))
            icon.contentTintColor = agent.color
            nameLabel.stringValue = agent.name
            metaLabel.stringValue = agent.meta
            if let detail = agent.detail, !detail.isEmpty {
                detailLabel.stringValue = detail
                detailLabel.font = agent.detailIsMono ? NativeTranscriptFont.captionMono() : NativeTranscriptFont.caption()
                detailLabel.maximumNumberOfLines = agent.detailIsMono ? 1 : 2
                detailLabel.isHidden = false
            } else {
                detailLabel.isHidden = true
            }
        }

        func measuredHeight(forWidth width: CGFloat) -> CGFloat {
            let textWidth = max(20, width - 18 - 10)
            var h = ceil(nameLabel.intrinsicContentSize.height)
            if !detailLabel.isHidden {
                detailLabel.preferredMaxLayoutWidth = textWidth
                h += 4 + ceil(detailLabel.intrinsicContentSize.height)
            }
            return max(18, h)
        }
    }

    func prepareForReuseIfNeeded() {}
}
