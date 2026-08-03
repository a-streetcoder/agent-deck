import AppKit
import Combine
import Darwin
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Table/scroll subclasses, question rail UI, jump-to-latest chrome

@MainActor
protocol QuestionRailKeyboardNavigationHandling: AnyObject {
    func handleQuestionRailKeyboardShortcut(_ event: NSEvent) -> Bool
}

@MainActor
final class PiAgentTranscriptTableView: NSTableView {
    weak var questionNavigationHandler: QuestionRailKeyboardNavigationHandling?

    override func keyDown(with event: NSEvent) {
        if questionNavigationHandler?.handleQuestionRailKeyboardShortcut(event) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor
final class PiAgentTranscriptScrollView: NSScrollView {
    weak var questionNavigationHandler: QuestionRailKeyboardNavigationHandling?

    override func keyDown(with event: NSEvent) {
        if questionNavigationHandler?.handleQuestionRailKeyboardShortcut(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Observable rail data. Mutated by the transcript coordinator on scroll/apply;
/// the hosted rail view is created ONCE and never replaced, so SwiftUI `@State`
/// (hover) survives every scroll/update tick instead of being reset — replacing
/// the hosted view every scroll tick was the root cause of the hover buzz.
@MainActor
final class QuestionRailModel: ObservableObject {
    @Published var items: [UserQuestionNavigationRailItem] = []
    @Published var availableWidth: CGFloat = 0
    /// Host (visible) rail height in px. Used by the overflow view's scroll frame.
    @Published var railHeight: CGFloat = 0
    /// True when the questions no longer fit as an evenly-spaced stack — the view
    /// then switches to a compact vertical scroller with edge fades.
    @Published var isSliding = false
}

struct UserQuestionNavigationRail: View {
    @ObservedObject var model: QuestionRailModel
    let onSelect: (String) -> Void

    @State private var hoveredID: String?

    private let expandAnimation = Animation.interpolatingSpring(mass: 0.75, stiffness: 320, damping: 30)
    private let fadeAnimation = Animation.easeOut(duration: 0.14)
    private let collapsedMarkWidth = TranscriptFloatingControlGeometry.questionRailCollapsedWidth

    private var expandedRowWidth: CGFloat {
        Self.expandedWidth(for: model.availableWidth)
    }

    private var activeOverflowItemID: String? {
        model.items.first(where: { $0.isActive })?.id
    }

    static func expandedWidth(for availableWidth: CGFloat) -> CGFloat {
        let desiredWidth = max(168, availableWidth * 0.22)
        let availableEdgeWidth = max(96, availableWidth - 112)
        return min(248, desiredWidth, availableEdgeWidth)
    }

    var body: some View {
        // Two layouts share the same rows and hover/opacity behavior:
        //  - stack (default): evenly-spaced marks, the look already approved.
        //  - overflow: when questions don't fit, keep every question reachable in
        //    a compact vertical scroller instead of hiding the rail.
        Group {
            if model.isSliding {
                overflowBody
            } else {
                stackedBody
            }
        }
        .opacity(hoveredID == nil ? 0.72 : 1)
        .animation(expandAnimation, value: hoveredID)
        .animation(fadeAnimation, value: hoveredID == nil)
        .onHover { hovering in
            // Nothing reacts until a mark is actually under the pointer. We only
            // use the container hover to clear when the pointer leaves the rail
            // entirely, so the expanded preview stays interactive while reading.
            if !hovering { hoveredID = nil }
        }
    }

    private var stackedBody: some View {
        // Container is FIXED at the expanded width. Collapsed rows occupy only
        // their trailing mark strip; the empty left region has no hit shape, so
        // clicks pass straight through to the transcript. Only the hovered row
        // grows left to reveal its preview.
        VStack(alignment: .trailing, spacing: TranscriptFloatingControlGeometry.questionRailRowSpacing) {
            ForEach(model.items) { item in
                row(for: item)
            }
        }
        .frame(width: expandedRowWidth, alignment: .trailing)
        .padding(.vertical, 8)
    }

    private var overflowBody: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .trailing, spacing: TranscriptFloatingControlGeometry.questionRailRowSpacing) {
                    ForEach(model.items) { item in
                        row(for: item)
                            .id(item.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.vertical, 8)
            }
            .frame(width: expandedRowWidth, height: max(1, model.railHeight), alignment: .trailing)
            .transcriptEdgeFade(height: 16)
            .onAppear { scrollOverflowActive(proxy) }
            .onChange(of: activeOverflowItemID) { _, _ in scrollOverflowActive(proxy) }
            .onChange(of: model.items) { _, _ in scrollOverflowActive(proxy) }
        }
    }

    private func scrollOverflowActive(_ proxy: ScrollViewProxy) {
        guard model.isSliding, let activeOverflowItemID else { return }
        withTransaction(Transaction(animation: nil)) {
            proxy.scrollTo(activeOverflowItemID, anchor: .center)
        }
    }

    private func row(for item: UserQuestionNavigationRailItem) -> some View {
        let isActive = item.isActive
        let isHovered = item.id == hoveredID

        return Button {
            onSelect(item.id)
        } label: {
            HStack(spacing: 8) {
                if isHovered {
                    Text(displayText(for: item))
                        .font(AppTheme.Font.caption.weight(.medium))
                        .foregroundStyle(textColor(isActive: isActive, isHovered: isHovered))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: expandedRowWidth - 44, alignment: .trailing)
                        .fixedSize(horizontal: true, vertical: false)
                }

                mark(isActive: isActive, isHovered: isHovered, isRailHovered: hoveredID != nil)
            }
            // The host remains fixed-width to avoid hover/layout feedback loops,
            // but the visible hover pill hugs its content inside that stable host.
            .frame(maxWidth: isHovered ? expandedRowWidth : collapsedMarkWidth, alignment: .trailing)
            .frame(height: TranscriptFloatingControlGeometry.questionRailRowHeight)
            .padding(.leading, isHovered ? 11 : 0)
            .padding(.trailing, isHovered ? 7 : 0)
            .background(rowBackground(isActive: isActive, isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(displayText(for: item))
        .accessibilityLabel(displayText(for: item))
        .accessibilityHint("Scroll to this question")
        .onHover { hovering in
            if hovering { hoveredID = item.id }
        }
    }

    private func mark(isActive: Bool, isHovered: Bool, isRailHovered: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(markColor(isActive: isActive, isHovered: isHovered, isRailHovered: isRailHovered))
            .frame(width: isActive ? 14 : (isHovered ? 14 : 7), height: isActive || isHovered ? 3 : 2)
    }

    private func markColor(isActive: Bool, isHovered: Bool, isRailHovered: Bool) -> Color {
        if isActive { return AppTheme.brandAccent }
        if isHovered { return .primary }
        return Color.secondary.opacity(isRailHovered ? 0.68 : 0.50)
    }

    private func textColor(isActive: Bool, isHovered: Bool) -> Color {
        if isActive { return AppTheme.brandAccent }
        if isHovered { return .primary }
        return .secondary
    }

    @ViewBuilder
    private func rowBackground(isActive: Bool, isHovered: Bool) -> some View {
        if isHovered {
            let fill = isActive ? AppTheme.brandAccent.opacity(0.16) : Color.secondary.opacity(0.10)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill)
                .glassEffect(.regular.tint(AppTheme.glassTint.opacity(0.14)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 1)
        } else {
            Color.clear
        }
    }

    private func displayText(for item: UserQuestionNavigationRailItem) -> String {
        let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(empty message)" }
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }
}

final class UserQuestionNavigationRailHostView: NSHostingView<UserQuestionNavigationRail> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Floating "scroll to latest" affordance shown when the transcript is not
/// pinned to the bottom — tapping it scrolls to the newest content and
/// re-engages streaming auto-follow.
struct JumpToLatestPill: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // Fill the full 32pt circle inside the button label so the whole pill
            // is the hit target — not just the glyph. The frame/contentShape must
            // live on the label (the button's interactive region), not outside it.
            Image(systemName: "chevron.down")
                .font(AppTheme.Font.footnote.weight(.bold))
                .offset(x: 0.5, y: 0.5)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .foregroundStyle(AppTheme.brandAccent)
        .glassEffect(.regular.tint(AppTheme.brandAccent.opacity(0.16)), in: Circle())
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .scaleEffect(isHovering ? 1.07 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(LanguageStore.shared.t("agent.jumpLatestShort"))
        .accessibilityLabel(LanguageStore.shared.t("agent.jumpLatestHelp"))
    }
}

/// Holds the transcript's pinned-to-bottom flag in a reference type so the screen
/// can keep it in `@State` (which watches identity only). Scrolling flips this
/// constantly; only `JumpToLatestOverlay` observes it, so flips don't invalidate
/// the screen body or re-run the transcript items build.
final class TranscriptPinnedState: ObservableObject {
    @Published var isPinned = true
}

/// The "jump to latest" pill, isolated so that toggling pinned-to-bottom on scroll
/// re-renders only this small view — never the screen body / transcript host.
struct JumpToLatestOverlay: View {
    @ObservedObject var pinnedState: TranscriptPinnedState
    let onJump: () -> Void

    var body: some View {
        ZStack {
            if !pinnedState.isPinned {
                JumpToLatestPill(action: onJump)
                    .padding(.trailing, TranscriptFloatingControlGeometry.jumpToLatestTrailingPadding)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: pinnedState.isPinned)
    }
}

/// Intermediate per-block descriptor used while flattening threads into rows.
/// Insets are filled in a second pass from row adjacency, then folded into the
/// final `PiAgentAppKitTranscriptItem` (`contentRevision` + `estimatedHeight`).
struct PiAgentTranscriptBlockDescriptor {
    let id: String
    /// Legacy SwiftUI content for hosted rows. `nil` when `kind` is native.
    let view: AnyView?
    /// Native render kind; `nil` falls back to hosting `view`.
    var kind: PiAgentTranscriptCellKind? = nil
    /// Content hash WITHOUT insets — insets are folded in at materialize time.
    let baseRevision: Int
    /// Height estimate for the block content alone (insets added separately).
    let estimatedContentHeight: (CGFloat) -> CGFloat
    /// Thread id this block belongs to, or nil for chrome / plan / anchor rows.
    let threadID: String?
    /// Truncated navigation title for top-level user-question rows.
    var questionNavigationTitle: String? = nil
    /// True only for a thread's user-question block (drives the 10pt q↔reply gap).
    let isThreadQuestion: Bool
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
}

/// The transcript-rendering unit, deliberately split out from `PiAgentScreen` so
/// that it — and only it — observes `PiAgentTranscriptRenderCache`. The render
/// cache pulses `streamingRevision` ~30Hz during streaming; isolating the
/// subscription here keeps that pulse from re-evaluating the screen's session
/// list and composer (see the `@State transcriptCache` note in `PiAgentScreen`).
///
/// `makeItems` is supplied by the parent and re-run on every pulse. It reads the
/// live cache (`threads`) and parent references (`store`/`viewModel`), so the
/// rebuilt items reflect the latest streamed content even though the parent view
