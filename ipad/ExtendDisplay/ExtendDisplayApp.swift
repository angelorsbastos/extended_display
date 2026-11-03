import Combine
import SwiftUI
import UIKit

/// UIKit startup instead of SwiftUI's `App`, because pointer lock (the trackpad
/// driving the laptop's mouse) has to be requested by the window's root controller.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let model = AppModel()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = RootHostingController(model: model)
        window.makeKeyAndVisible()
        self.window = window

        // a monitor should not go to sleep
        UIApplication.shared.isIdleTimerDisabled = true
        model.start()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        model.appBecameActive()
    }
}

/// Hosts the SwiftUI screens and locks the pointer while video is showing, so
/// the trackpad's movement goes to the laptop instead of moving the iPad pointer.
final class RootHostingController: UIHostingController<RootView> {
    private let model: AppModel
    private var screenChanges: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init(rootView: RootView(model: model))
        screenChanges = model.$screen.sink { [weak self] _ in
            // $screen fires before the value changes; ask again once it has
            DispatchQueue.main.async { self?.setNeedsUpdateOfPrefersPointerLocked() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.reportPointerLock() }
        }
    }

    /// Tell the laptop's log whether iPadOS granted the pointer lock. It only does
    /// for apps running full screen, so the window and screen sizes are included.
    private func reportPointerLock() {
        guard prefersPointerLocked, let scene = view.window?.windowScene else { return }
        let locked = scene.pointerLockState?.isLocked ?? false
        let window = view.window?.bounds.size ?? .zero
        let screen = scene.screen.bounds.size
        model.log("pointer lock \(locked ? "granted" : "NOT granted"); "
                  + "iPadOS \(UIDevice.current.systemVersion); "
                  + "window \(Int(window.width))x\(Int(window.height)) "
                  + "of screen \(Int(screen.width))x\(Int(screen.height))")
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("not used")
    }

    override var prefersPointerLocked: Bool {
        if case .video = model.screen { return true }
        return false
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geometry in
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
            .onAppear { model.updateOrientation(size: geometry.size) }
            .onChange(of: geometry.size) { size in model.updateOrientation(size: size) }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}
