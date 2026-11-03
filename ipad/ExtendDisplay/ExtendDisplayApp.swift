import SwiftUI
import UIKit

@main
struct ExtendDisplayApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onAppear {
                    // a monitor should not go to sleep
                    UIApplication.shared.isIdleTimerDisabled = true
                    model.start()
                }
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.screen {
            case .home:
                HomeView(model: model)
            case .video:
                VideoScreen(model: model)
            case .shortcuts:
                ShortcutsView(model: model)
            case .media:
                MediaView(model: model)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}
