import SwiftUI

/// Pi Agent toolbar button that opens the dev-server controls popover for the
/// selected session's project. Structured as a single custom-view layer — its
/// `body` is the `Button` directly — so it forms its own toolbar glass island,
/// mirroring `PiAgentPlanToolbarButton`. An extra wrapper view would collapse
/// the toolbar's glass formation.
struct ProjectServerToolbarButton: View {
    var viewModel: AppViewModel
    var store: PiAgentSessionStore

    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Label("Dev Server", systemImage: hasActiveServer ? "bolt.horizontal.circle.fill" : "play.circle")
                .symbolEffect(.breathe, options: .repeating, isActive: hasActiveServer)
        }
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(tint)
        .tint(tint)
        .help("Start, stop, and restart this project's dev server")
        .disabled(store.selectedSession == nil)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            if let session = store.selectedSession {
                ProjectServerPopover(viewModel: viewModel, session: session)
            }
        }
    }

    private var hasActiveServer: Bool {
        guard let path = store.selectedSession?.projectPath else { return false }
        return viewModel.projectServerService.activeServer(forProjectPath: path) != nil
    }

    private var tint: Color {
        hasActiveServer ? AppTheme.brandAccent : .primary
    }
}
