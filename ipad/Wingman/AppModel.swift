import AVFoundation
import UIKit
import WidgetKit

enum VideoMode: String {
    case extend, mirror
}

enum Screen: Equatable {
    case home
    case video(VideoMode)
    case shortcuts
    case controls
    case clipboard
    case files
    case dashboard
    case trackpad  // iPhone
    case dock
    case settings
}

/// iPhone or iPad: the iPhone has its own home screen and modes.
let isPhone = UIDevice.current.userInterfaceIdiom == .phone

/// App state, shared by all screens. Published properties change on the main thread only.
final class AppModel: ObservableObject {
    @Published var connected = false
    /// The playing song's cover from the laptop, for the Dock's album background.
    @Published var artwork: UIImage?
    /// The Connect card's progress: nil until Connect is tapped (or a way set to
    /// Automatic starts connecting), then each stage as it happens.
    @Published var connectStage: ConnectStage?
    /// A way set to "Ask" that the laptop just tried: it's reachable, tap Connect.
    @Published var nearby: Transport?
    /// Connect was tapped (and not Disconnect since).
    @Published private(set) var wantsConnection = false
    /// For the Connect card: the way the current attempt arrived, how far it got
    /// (ConnectCard.Step's number, kept when it fails), and whether it paired.
    @Published private(set) var transportTrying: Transport?
    @Published private(set) var lastReachedStep: Int?
    @Published private(set) var pairedDuringConnect = false
    private var lookingTimeout: DispatchWorkItem?

    enum ConnectStage: Equatable {
        case looking
        case found(Transport)
        case pairing
        case securing
        case connected(Transport)
        case failed(String)
    }
    /// How the laptop is connected right now, when it is.
    @Published var transport: Transport?
    /// Set while a laptop asks to pair over Wi-Fi: its name, for the code screen.
    @Published var pairingLaptop: String?
    /// The outcome of the last pairing, shown on the home screen.
    @Published var pairingMessage: String?
    /// What the Wi-Fi side is doing, and this iPad's addresses, for the home screen.
    @Published var wifiState: StreamServer.WifiState = .starting
    @Published var addresses: [String] = []
    @Published var pairedLaptops = 0
    @Published var screen: Screen = .home
    @Published var shortcuts: [Shortcut] = []
    /// The laptop's name (hello), for the home screen's title.
    @Published var laptopName: String?
    /// Ctrl+Alt+I is on: the laptop's keyboard and trackpad drive the iPad.
    @Published var laptopInput = false
    /// The laptop's Start menu apps, for the shortcut editor (asked for with requestApps).
    @Published var laptopApps: [LaptopApp]?
    /// Laptop apps' own icons (base64 PNG; "" = none), asked for one by one (requestAppIcon).
    @Published var appIcons: [String: String] = [:]
    /// The Dashboard's latest numbers, and the last few minutes of them for the graphs.
    @Published var stats: LaptopStats?
    @Published var statsHistory: [LaptopStats] = []
    static let statsHistoryLength = 90  // samples, every 2 s: 3 minutes
    @Published var nowPlaying: NowPlaying?
    /// Changed by the laptop's updates, and right away by the Controls screen
    /// (so a switch flips instantly instead of after the next update).
    @Published var controls: ControlsState?
    @Published var receivingVideo = false
    @Published var videoError: String?
    @Published var listenError: String?
    /// Size of the laptop screen being streamed, to map touches onto it.
    @Published var videoSize = CGSize(width: 16, height: 9)
    /// Play the laptop's sound on the iPad. Remembered separately for remote use
    /// (on by default: nobody hears the laptop) and at home (off by default).
    @Published private(set) var soundOnIPad = false
    /// The clipboard panel over the video (four-finger tap).
    @Published var showingClipboard = false {  // the quick panel over the video
        didSet {
            // keyboard and trackpad work the panel, not the laptop, while it's open
            if case .video = screen { input.active = !showingClipboard }
            updateControlsWatch()  // its Controls tab shows volume and brightness
        }
    }
    enum PanelTab { case controls, shortcuts, clipboard }
    @Published var panelTab = PanelTab.controls

    let displayLayer = AVSampleBufferDisplayLayer()
    /// Extend and Mirror keep playing in a small window after leaving the app.
    let pictureInPicture = PictureInPicture()
    let clipboardHistory = ClipboardHistory()
    let dockTimer = DockTimer()  // here, so a timer keeps going after leaving the Dock
    let files = FileTransfers()
    /// Files other apps shared here (Share > Wingman) before the laptop was
    /// connected: sent as soon as it is.
    private var sharedWhileAway: [URL] = []
    private let server = StreamServer()
    private let input = InputCapture()
    private let audio = AudioPlayer()
    private lazy var decoder = H264Decoder(layer: displayLayer)
    private var videoFlowing = false  // only touched on the server's queue
    private var linkTransport: Transport?  // `transport`, but for the server's queue
    private var started = false
    private var portrait = false
    private var lastKeyframeRequest = Date.distantPast
    /// UIPasteboard.changeCount when we last synced, to spot new copies.
    private var pasteboardSeen = UIPasteboard.general.changeCount

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    func start() {
        guard !started else { return }
        started = true

        input.send = { [weak self] message in self?.server.send(json: message) }
        decoder.onNeedsKeyframe = { [weak self] reason in
            self?.log("video decoder reset (\(reason)), asking for a keyframe")
            self?.requestKeyframe()
        }
        audio.onProblem = { [weak self] text in self?.log(text) }
        dockTimer.onFinish = { [weak self] in self?.server.send(json: ["type": "timer_done"]) }
        files.attach(server)
        server.onFileData = { [weak self] payload in self?.files.receive(payload) }

        server.onConnected = { [weak self] transport in
            self?.linkTransport = transport
            self?.audio.stop()  // a new connection (e.g. the cable replacing Wi-Fi) starts its own
            DispatchQueue.main.async {
                guard let self else { return }
                self.connected = true
                self.transport = transport
                self.performPendingLink()
                self.nearby = nil
                self.lookingTimeout?.cancel()
                self.connectStage = .connected(transport)
                self.soundOnIPad = Self.soundSetting(for: transport)
                if self.soundOnIPad {
                    self.server.send(json: ["type": "sound", "on": true])
                }
                if self.screen == .dashboard {  // reconnected while it's open
                    self.server.send(json: ["type": "watch_stats", "on": true])
                }
                self.updateControlsWatch()
                self.sendPrefs()
                if !self.sharedWhileAway.isEmpty {
                    self.files.send(self.sharedWhileAway)
                    self.sharedWhileAway.removeAll()
                }
            }
        }
        server.onPairingRequest = { [weak self] laptopName in
            DispatchQueue.main.async {
                self?.pairingMessage = nil
                self?.pairingLaptop = laptopName
            }
        }
        server.onPairingEnded = { [weak self] problem in
            DispatchQueue.main.async {
                self?.pairingLaptop = nil
                self?.pairingMessage = problem ?? "Paired. The laptop now connects over Wi-Fi too."
                self?.refreshNetworkInfo()
            }
        }
        server.onWifiState = { [weak self] state in
            DispatchQueue.main.async {
                self?.wifiState = state
                self?.refreshNetworkInfo()
            }
        }
        refreshNetworkInfo()
        server.onDisconnected = { [weak self] in
            self?.audio.stop()
            self?.files.disconnected()
            DispatchQueue.main.async {
                guard let self else { return }
                self.connected = false
                self.transport = nil
                // dropped while Connect is on: it reconnects by itself, show that
                self.connectStage = nil
                if self.wantsConnection { self.startLooking() }
                self.nowPlaying = nil
                self.controls = nil
                if case .video = self.screen {
                    self.goHome()
                }
            }
        }
        server.onStage = { [weak self] stage in
            DispatchQueue.main.async {
                guard let self, !self.connected else { return }  // e.g. a spare Wi-Fi link while on the cable
                switch stage {
                case .found(let transport):
                    self.lookingTimeout?.cancel()
                    self.transportTrying = transport
                    self.lastReachedStep = 1
                    self.pairedDuringConnect = false
                    self.connectStage = .found(transport)
                case .pairing:
                    self.lastReachedStep = 2
                    self.pairedDuringConnect = true
                    self.connectStage = .pairing
                case .securing:
                    self.lastReachedStep = 3
                    self.connectStage = .securing
                case .failed(let reason):
                    self.connectStage = .failed(reason)
                }
            }
        }
        server.onNearby = { [weak self] transport in
            DispatchQueue.main.async {
                guard let self, !self.connected else { return }
                // the cable outranks the others: don't let a Wi-Fi try replace "by cable"
                if self.nearby == nil || transport == .usb || self.nearby == .remote { self.nearby = transport }
            }
        }
        server.onVideo = { [weak self] data in
            guard let self, self.decoder.decode(data), !self.videoFlowing else { return }
            self.videoFlowing = true
            DispatchQueue.main.async { self.receivingVideo = true }
        }
        server.onAudio = { [weak self] packet in
            self?.audio.play(packet)
        }
        server.onMessage = { [weak self] message in
            self?.handle(message)
        }

        do {
            try server.start()
        } catch {
            listenError = "Could not start listening for the laptop: \(error.localizedDescription)"
        }
    }

    // MARK: widgets and Control Center

    /// What a widget or Control Center button asked for (wingman://...), done
    /// once the laptop is connected and has sent its shortcuts.
    private enum PendingLink {
        case shortcut(String), control(String), media(String)
    }
    private var pendingLink: PendingLink?
    private var lastSnapshot: WidgetSnapshot?
    private var lastWidgetReload = Date.distantPast

    /// wingman://shortcut/<id>, wingman://lock, wingman://playpause, wingman://dock
    func handleLink(_ url: URL) {
        switch url.host {
        case "shortcut":
            pendingLink = .shortcut(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        case "lock":
            pendingLink = .control("lock")
        case "playpause":
            pendingLink = .media("play_pause")
        case "dock":
            open(.dock)
            return
        case "send":  // the share extension saved something for the laptop
            collectOutbox()
            return
        default:
            return
        }
        if connected && !shortcuts.isEmpty {
            performPendingLink()
        } else if !wantsConnection {
            connect()  // tapping a widget button means "use the laptop now"
        }
    }

    private func performPendingLink() {
        guard connected, let link = pendingLink else { return }
        if case .shortcut = link, shortcuts.isEmpty { return }  // the list comes with "hello"
        pendingLink = nil
        switch link {
        case .shortcut(let id):
            if let shortcut = shortcuts.first(where: { $0.id == id }) { run(shortcut) }
        case .control(let name):
            control(name)
        case .media(let action):
            media(action)
        }
    }

    /// Files the share extension saved (Share > Wingman): send them (or keep
    /// them until the laptop connects), then clear the outbox.
    func collectOutbox() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup) else { return }
        let outbox = container.appendingPathComponent("Outbox", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil),
              !folders.isEmpty else { return }
        let items = folders.flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
        if !items.isEmpty {
            openShared(items)  // makes its own copies to send
            if !connected && !wantsConnection { connect() }  // sharing means "send it now"
        }
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private var reportedWidgetGroup = false

    /// Save what the widgets show (only when it changed) and let them redraw.
    func saveWidgetSnapshot() {
        if !reportedWidgetGroup, connected {
            reportedWidgetGroup = true
            log("widgets: app uses " + WidgetSnapshot.diagnosis)
        }
        let snapshot = WidgetSnapshot(
            laptopName: laptopName, connected: connected,
            battery: controls?.battery?.percent ?? lastSnapshot?.battery,
            charging: controls?.battery?.charging ?? lastSnapshot?.charging ?? false,
            cpuTemp: controls?.cpuTemp ?? lastSnapshot?.cpuTemp,
            songTitle: nowPlaying?.title, songArtist: nowPlaying?.artist, playing: nowPlaying?.playing ?? false,
            shortcuts: shortcuts.prefix(8).map {
                WidgetSnapshot.Item(id: $0.id, title: $0.title, symbol: $0.icon,
                                    image: ($0.image?.isEmpty ?? true) ? nil : $0.image)
            },
            updated: Date())
        let changed = !snapshot.sameContent(as: lastSnapshot)
        lastSnapshot = snapshot
        snapshot.save()  // the "updated" time, at least
        // redrawing has a budget: on real changes, at most every half minute
        if changed, Date().timeIntervalSince(lastWidgetReload) > 30 {
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: connecting

    /// The Connect button: ways set to "Ask" may connect now (until Disconnect).
    func connect() {
        tap()
        wantsConnection = true
        server.setArmed(true)
        startLooking()
    }

    func disconnect() {
        tap()
        wantsConnection = false
        lookingTimeout?.cancel()
        connectStage = nil
        nearby = nil
        server.setArmed(false)
    }

    /// "Looking for your laptop", and after a while, if nothing came, what to check.
    private func startLooking() {
        connectStage = .looking
        transportTrying = nil
        lastReachedStep = 0
        pairedDuringConnect = false
        lookingTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.connected, self.connectStage == .looking else { return }
            self.connectStage = .failed("No laptop answered. Is Wingman running on the laptop (its icon "
                                        + "in the tray)? For Wi-Fi, both must be on the same network; "
                                        + "away from home, Tailscale on both. Still trying meanwhile.")
        }
        lookingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
    }

    // MARK: actions from the screens

    func open(_ screen: Screen) {
        self.screen = screen
        tap()
        updateControlsWatch()
        if screen == .controls || screen == .dock {
            videoError = nil
        }
        if screen == .dashboard {
            // the laptop reads its sensors only while this screen is open
            server.send(json: ["type": "watch_stats", "on": true])
        }
        if case .video(let mode) = screen {
            receivingVideo = false
            videoError = nil
            displayLayer.flushAndRemoveImage()
            input.active = true
            server.send(json: ["type": "start_video", "mode": mode.rawValue, "portrait": portrait])
            pictureInPicture.attach(displayLayer)
        }
    }

    func goHome() {
        if screen == .dashboard {
            server.send(json: ["type": "watch_stats", "on": false])
        }
        if case .video = screen {
            server.send(json: ["type": "stop_video"])
            pictureInPicture.detach()
            displayLayer.flushAndRemoveImage()
        }
        input.active = false
        receivingVideo = false
        showingClipboard = false
        screen = .home
        updateControlsWatch()
    }

    /// The laptop sends its settings (volume, brightness, battery, temperature)
    /// every 2 s while a screen that shows them is open: home, Controls, Dock.
    private func updateControlsWatch() {
        var watching = screen == .home || screen == .controls || screen == .dock
        if case .video = screen, showingClipboard { watching = true }
        server.send(json: ["type": "watch_controls", "on": watching])
    }

    /// A light tap felt in the hand, for buttons and tiles (unless switched off).
    func tap() {
        haptic()
    }

    /// The connection setting changed: refuse ways it no longer allows (a
    /// connection that came that way is dropped; the laptop then tries others).
    func applyConnectionPrefs() {
        server.dropDisallowed()
    }

    /// Settings the laptop uses: the Extend screen's text size and picture quality.
    func sendPrefs() {
        server.send(json: ["type": "prefs", "extend_scale": Prefs.extendScaleValue, "quality": Prefs.qualityValue])
    }

    /// Ctrl+Alt+I from here: the laptop's keyboard and trackpad go to the iPad.
    func setLaptopInput(_ on: Bool) {
        laptopInput = on  // right away; the laptop confirms (laptop_input)
        tap()
        server.send(json: ["type": "laptop_input", "on": on])
    }

    func run(_ shortcut: Shortcut) {
        server.send(json: ["type": "shortcut", "id": shortcut.id])
    }

    /// Keep this list on the laptop (it answers with the saved list, as hello).
    func saveShortcuts(_ list: [Shortcut]) {
        shortcuts = list  // show it right away
        server.send(json: ["type": "save_shortcuts", "shortcuts": list.map(\.json)])
    }

    /// Laptop pointer, clicks, scrolling and typing from the iPhone's Trackpad mode.
    func pointer(_ message: [String: Any]) {
        server.send(json: message)
    }

    /// Run a shortcut that isn't saved yet, to see what it does.
    func tryShortcut(_ shortcut: Shortcut) {
        server.send(json: ["type": "try_shortcut", "shortcut": shortcut.json])
    }

    func requestApps() {
        server.send(json: ["type": "list_apps"])
    }

    func requestAppIcon(_ open: String) {
        guard appIcons[open] == nil else { return }
        appIcons[open] = ""  // asked: don't ask again while waiting
        server.send(json: ["type": "app_icon", "open": open])
    }

    func media(_ action: String) {
        server.send(json: ["type": "media", "action": action])
    }

    /// Change a laptop setting or run a power action; see pc/controls.py apply().
    func control(_ name: String, _ value: Any = true) {
        server.send(json: ["type": "control", "name": name, "value": value])
    }

    /// Another app shared files here (Share > Wingman, or "Open in"): send
    /// them to the laptop's Downloads, now or as soon as it connects.
    func openShared(_ urls: [URL]) {
        let copies = urls.compactMap { FileTransfers.makeSendableCopy(of: $0) }
        guard !copies.isEmpty else { return }
        if connected {
            files.send(copies)
        } else {
            sharedWhileAway += copies
            files.note = "Will send \(copies.count == 1 ? "“\(copies[0].lastPathComponent)”" : "\(copies.count) files") "
                + "when the laptop connects"
        }
        if screen == .home {
            open(.files)
        }
    }

    /// Play the laptop's sound here (or stop), and remember it for this kind of connection.
    func setSoundOnIPad(_ on: Bool) {
        guard let transport else { return }
        soundOnIPad = on
        UserDefaults.standard.set(on, forKey: Self.soundKey(for: transport))
        if !on {
            audio.stop()
        }
        server.send(json: ["type": "sound", "on": on])
    }

    /// Settings changed a sound preference: follow it now if it's for this connection.
    func applySoundPrefs() {
        guard let transport else { return }
        let wanted = Self.soundSetting(for: transport)
        if wanted != soundOnIPad { setSoundOnIPad(wanted) }
    }

    private static func soundKey(for transport: Transport) -> String {
        transport == .remote ? "soundOnIPad.remote" : "soundOnIPad.home"
    }

    private static func soundSetting(for transport: Transport) -> Bool {
        UserDefaults.standard.object(forKey: soundKey(for: transport)) as? Bool ?? (transport == .remote)
    }

    func submitPairingCode(_ code: String) {
        server.submitPairingCode(code)
    }

    func cancelPairing() {
        server.cancelPairing()
    }

    func refreshNetworkInfo() {
        addresses = NetworkInfo.addresses()
        pairedLaptops = PairingStore.laptopIds.count
    }

    /// The app is in front again (SceneDelegate).
    func appBecameActive() {
        refreshNetworkInfo()  // e.g. joined another Wi-Fi meanwhile
        collectOutbox()  // shared while the app couldn't be opened
        sendClipboardIfChanged()
        // the decoder may have been shut down while we were away; a keyframe
        // brings the picture back even if nothing on the laptop screen changes
        if case .video = screen {
            requestKeyframe()
        }
    }

    /// Ask the laptop to re-send the current picture as a full keyframe.
    /// At most twice a second: a reset can be noticed on several frames in a row.
    private func requestKeyframe() {
        guard Date().timeIntervalSince(lastKeyframeRequest) > 0.5 else { return }
        lastKeyframeRequest = Date()
        server.send(json: ["type": "keyframe"])
    }

    /// A line for the laptop's log (pc/hub.log), for diagnosing problems.
    func log(_ text: String) {
        server.send(json: ["type": "log", "text": text])
    }

    /// Fingers on the video, as fractions of the laptop screen (see VideoView).
    func touches(_ touches: [[String: Any]]) {
        server.send(json: ["type": "touch", "touches": touches])
    }

    /// Called whenever the window's size changes, i.e. when the iPad rotates.
    func updateOrientation(size: CGSize) {
        let isPortrait = size.height > size.width
        guard isPortrait != portrait else { return }
        portrait = isPortrait
        // only Extend follows: Mirror can't rotate the laptop's own screen
        if screen == .video(.extend) {
            server.send(json: ["type": "orientation", "portrait": isPortrait])
        }
    }

    /// Send what was copied on the iPad (in any app) to the laptop. Called when
    /// the app comes back to the front. iPadOS asks permission to read the
    /// clipboard unless Settings > Wingman > Paste from Other Apps is Allow.
    func sendClipboardIfChanged() {
        let pasteboard = UIPasteboard.general
        guard connected, pasteboard.changeCount != pasteboardSeen else { return }
        pasteboardSeen = pasteboard.changeCount
        if pasteboard.hasImages, let png = pasteboard.image?.pngData() {
            clipboardHistory.addImage(png: png, from: .iPad)
            server.send(json: ["type": "clipboard", "kind": "image",
                               "png": png.base64EncodedString()])
        } else if pasteboard.hasStrings, let text = pasteboard.string {
            clipboardHistory.addText(text, from: .iPad)
            server.send(json: ["type": "clipboard", "kind": "text", "text": text])
        }
    }

    /// Put a history item on both clipboards, the iPad's and the laptop's.
    /// With `paste`, the laptop also pastes it (Ctrl+V) where its cursor is.
    func copy(_ item: ClipItem, paste: Bool = false) {
        var message: [String: Any] = ["type": "clipboard", "paste": paste]
        let pasteboard = UIPasteboard.general
        if let text = item.text {
            pasteboard.string = text
            message["kind"] = "text"
            message["text"] = text
        } else if let png = clipboardHistory.png(of: item), let image = UIImage(data: png) {
            pasteboard.image = image
            message["kind"] = "image"
            message["png"] = png.base64EncodedString()
        } else {
            return
        }
        pasteboardSeen = pasteboard.changeCount  // ours: don't send it again on return
        clipboardHistory.touch(item)
        server.send(json: message)
    }

    // MARK: messages from the laptop (on the server's queue)

    private func handle(_ message: LaptopMessage) {
        if message.type == "bye" {
            // Disconnect, chosen in the laptop's tray menu: like tapping Disconnect here
            DispatchQueue.main.async { self.disconnect() }
            return
        }
        if message.type == "video_started" {
            // a new stream starts with new parameter sets; drop the old ones
            decoder.reset()
            videoFlowing = false
        }
        if message.type.hasPrefix("file_") {
            files.handle(message)
            return
        }
        if message.type == "audio_started" {
            // before the first packet, which is right behind this message
            audio.start(sampleRate: Double(message.sampleRate ?? 48000), channels: message.channels ?? 2,
                        remote: linkTransport == .remote)
        }
        DispatchQueue.main.async {
            switch message.type {
            case "hello":
                self.shortcuts = message.shortcuts ?? []
                self.laptopName = message.laptopName ?? self.laptopName
                self.laptopInput = message.laptopInput ?? false
                self.saveWidgetSnapshot()
                self.performPendingLink()  // a widget's shortcut waits for the shortcut list
            case "laptop_input":
                self.laptopInput = message.on ?? false
            case "apps":
                self.laptopApps = message.apps ?? []
            case "app_icon":
                if let open = message.open {
                    self.appIcons[open] = message.png ?? ""
                }
            case "stats":
                if let stats = message.stats {
                    self.stats = stats
                    self.statsHistory = Array((self.statsHistory + [stats]).suffix(Self.statsHistoryLength))
                }
            case "now_playing":
                self.nowPlaying = message.nowPlaying
                self.saveWidgetSnapshot()
            case "artwork":
                self.artwork = message.jpeg.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))
            case "controls":
                self.controls = message.controls
                self.saveWidgetSnapshot()
            case "video_started":
                if let width = message.width, let height = message.height {
                    self.videoSize = CGSize(width: width, height: height)
                }
            case "clipboard":
                self.receiveClipboard(message)
            case "error":
                self.videoError = message.message
            default:
                break
            }
        }
    }

    /// Something was copied on the laptop: put it on the iPad's clipboard.
    private func receiveClipboard(_ message: LaptopMessage) {
        let pasteboard = UIPasteboard.general
        if message.kind == "text", let text = message.text {
            pasteboard.string = text
            clipboardHistory.addText(text, from: .laptop)
        } else if message.kind == "image", let png = message.png,
                  let data = Data(base64Encoded: png), let image = UIImage(data: data) {
            pasteboard.image = image
            clipboardHistory.addImage(png: data, from: .laptop)
        } else {
            return
        }
        // our own write: don't send it straight back to the laptop
        pasteboardSeen = pasteboard.changeCount
    }
}
