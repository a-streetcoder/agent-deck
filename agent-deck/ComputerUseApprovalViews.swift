import SwiftUI

struct ComputerUseApprovalPresentation: ViewModifier {
    let coordinator: ComputerUseApprovalCoordinator
    let sessionID: UUID?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        let request = coordinator.request(for: sessionID)
        content
            .onAppear { isPresented = request != nil }
            .onChange(of: request?.id) { _, id in isPresented = id != nil }
            .sheet(isPresented: $isPresented) {
                if let request = coordinator.request(for: sessionID) {
                    ComputerUseApprovalSheet(
                        request: request,
                        accept: { coordinator.accept(request) },
                        decline: { coordinator.decline(request) },
                        cancel: { coordinator.cancel(request) }
                    )
                }
            }
    }
}

/// Native confirmation surface for the discovered Codex Computer Use helper.
struct ComputerUseApprovalSheet: View {
    let request: ComputerUseApprovalCoordinator.Request
    let accept: () -> Void
    let decline: () -> Void
    let cancel: () -> Void
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Computer Use approval", systemImage: "hand.raised.fill")
                .font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Server / tool").foregroundStyle(.secondary); Text("\(request.server)/\(request.tool)").textSelection(.enabled) }
                GridRow { Text("Project").foregroundStyle(.secondary); Text(request.projectID ?? "No project") }
                GridRow { Text("Requesting agent").foregroundStyle(.secondary); Text(request.requestingAgent ?? "Parent session") }
                if let subagentRunID = request.subagentRunID { GridRow { Text("Subagent run").foregroundStyle(.secondary); Text(subagentRunID.uuidString) } }
            }
            if let title = request.title, !title.isEmpty { Text(title).font(.headline) }
            Text(request.message)
                .textSelection(.enabled)
                .accessibilityLabel("Computer Use request message: \(request.message)")
            Text(request.schemaSummary).font(.callout).foregroundStyle(.secondary)
            Text("macOS Automation, Accessibility, and Screen Recording permissions are separate from this approval.")
                .font(.callout).foregroundStyle(.secondary)
            if !request.advertisedPersistenceModes.isEmpty {
                Text("This server advertised persistence options, but Agent Deck will make a one-call decision only.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(expiryText(at: context.date)).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Cancels this Computer Use request")
                Spacer()
                Button("Decline", role: .destructive, action: decline)
                    .keyboardShortcut("d", modifiers: [.command])
                    .accessibilityHint("Denies the Computer Use request")
                Button("Accept", action: accept)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Approves this single Computer Use request")
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }

    private func expiryText(at date: Date) -> String {
        let remaining = max(0, Int(request.deadline.timeIntervalSince(date)))
        return remaining == 0 ? "This request has expired." : "Expires in \(remaining) seconds."
    }
}
