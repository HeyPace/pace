import SwiftUI

@main
struct PacePadApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = PacePadViewModel()

    var body: some Scene {
        WindowGroup {
            PacePadRootView(viewModel: viewModel)
                .onAppear {
                    viewModel.start()
                }
                .onDisappear {
                    viewModel.stop()
                }
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                viewModel.start()
            case .background:
                viewModel.stop()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
