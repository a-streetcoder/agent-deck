import SwiftUI

/// First item of the Pi Agent toolbar: an icon button that opens the current plan in
/// a popover. While the plan is in progress the `checklist` icon takes the
/// brand-accent tint; once every item is done it settles to neutral chrome.
/// Disabled when the selected session has no plan.
///
/// Structured as a single-level custom view — its `body` is the `Button` directly,
/// mirroring `PiAgentOpenTerminalToolbarButton`. A toolbar resolves the control through
/// exactly one custom-view layer; an extra wrapper view breaks glass-island formation
/// and collapses the whole toolbar into one capsule.
///
/// Icon-only per `docs/agent-guidelines/toolbar-guidelines.md`. Owns a `.popover`, so it is
/// a standalone `ToolbarItem`, never inside a `ControlGroup`.
struct PiAgentPlanToolbarButton: View {
    var store: PiAgentSessionStore

    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Label(LanguageStore.shared.t("transcript.plan"), systemImage: "checklist")
        }
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(tint)
        .tint(tint)
        .help(LanguageStore.shared.t("transcript.planHelp"))
        .disabled(plan == nil)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            if let plan {
                PiAgentCurrentPlanCard(plan: plan, showsSurface: false, showsHeaderDivider: true, showsSubtitle: false)
                    .padding(16)
                    .frame(width: AppTheme.Popover.standardWidth)
            }
        }
    }

    /// The current plan for the selected session, or `nil` when there is none.
    private var plan: PiSessionPlanRecord? {
        guard let session = store.selectedSession,
              let plan = store.sessionPlan(for: session.id),
              !plan.items.isEmpty else { return nil }
        return plan
    }

    /// True while the plan still has at least one item left to complete.
    private var isInProgress: Bool {
        guard let plan else { return false }
        let done = plan.items.count(where: { $0.status == .done || $0.status == .skipped })
        return done < plan.items.count
    }

    /// Brand accent while the plan is in progress; neutral chrome otherwise.
    private var tint: Color {
        isInProgress ? AppTheme.brandAccent : .primary
    }
}
