import SwiftUI

struct SettingsSceneContent: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        SettingsScreen(viewModel: viewModel)
            .frame(minWidth: 640, idealWidth: 760, minHeight: 560, idealHeight: 700)
    }
}
