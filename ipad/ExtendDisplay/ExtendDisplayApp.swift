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
        // started by sharing a file to the app
        if !connectionOptions.urlContexts.isEmpty {
            model.openShared(connectionOptions.urlContexts.map(\.url))
        }
    }

    /// Share > Wingman (or "Open in") from another app, while running.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        model.openShared(URLContexts.map(\.url))
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
    private var clipboardChanges: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init(rootView: RootView(model: model))
        screenChanges = model.$screen.sink { [weak self] _ in
            // $screen fires before the value changes; ask again once it has
            DispatchQueue.main.async { self?.setNeedsUpdateOfPrefersPointerLocked() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.reportPointerLock() }
        }
        // the clipboard panel over the video needs the iPad's own pointer
        clipboardChanges = model.$showingClipboard.sink { [weak self] _ in
            DispatchQueue.main.async { self?.setNeedsUpdateOfPrefersPointerLocked() }
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
        if case .video = model.screen, !model.showingClipboard { return true }
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
                Theme.background.ignoresSafeArea()
                switch model.screen {
                case .home:
                    ControlCenterView(model: model, history: model.clipboardHistory, files: model.files)
                case .video:
                    VideoScreen(model: model)
                case .shortcuts:
                    ShortcutsView(model: model)
                case .controls:
                    ControlsView(model: model)
                case .clipboard:
                    ClipboardScreen(model: model)
                case .files:
                    FilesView(model: model, files: model.files)
                case .dashboard:
                    DashboardView(model: model)
                case .trackpad:
                    TrackpadView(model: model)
                case .dock:
                    DockView(model: model, timer: model.dockTimer)
                case .settings:
                    SettingsView(model: model)
                }
                FileNoteBanner(files: model.files)
                if let laptop = model.pairingLaptop {
                    PairingView(model: model, laptopName: laptop)
                }
            }
            .onAppear { model.updateOrientation(size: geometry.size) }
            .onChange(of: geometry.size) { size in model.updateOrientation(size: size) }
        }
        // the iPhone keeps clear of the Dynamic Island and rounded corners
        .ignoresSafeArea(.container, edges: isPhone ? [] : .all)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

extension View {
    /// Screen margins: roomy on the iPad, tight on the iPhone.
    func screenPadding() -> some View {
        padding(isPhone ? 16 : 40)
    }
}
