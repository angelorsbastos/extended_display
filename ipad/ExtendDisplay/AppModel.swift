import AVFoundation
import UIKit

enum VideoMode: String {
    case extend, mirror
}

enum Screen: Equatable {
    case home
    case video(VideoMode)
    case shortcuts
    case controls
}

/// App state, shared by all screens. Published properties change on the main thread only.
final class AppModel: ObservableObject {
    @Published var connected = false
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

    let displayLayer = AVSampleBufferDisplayLayer()
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

        server.onConnected = { [weak self] transport in
            self?.linkTransport = transport
            self?.audio.stop()  // a new connection (e.g. the cable replacing Wi-Fi) starts its own
            DispatchQueue.main.async {
                guard let self else { return }
                self.connected = true
                self.transport = transport
                self.soundOnIPad = Self.soundSetting(for: transport)
                if self.soundOnIPad {
                    self.server.send(json: ["type": "sound", "on": true])
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
            DispatchQueue.main.async {
                guard let self else { return }
                self.connected = false
                self.transport = nil
                self.nowPlaying = nil
                self.controls = nil
                if case .video = self.screen {
                    self.goHome()
                }
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

    // MARK: actions from the screens

    func open(_ screen: Screen) {
        self.screen = screen
        if screen == .controls {
            videoError = nil
            // the laptop sends its settings every 2 s while this screen is open
            server.send(json: ["type": "watch_controls", "on": true])
        }
        if case .video(let mode) = screen {
            receivingVideo = false
            videoError = nil
            displayLayer.flushAndRemoveImage()
            input.active = true
            server.send(json: ["type": "start_video", "mode": mode.rawValue, "portrait": portrait])
        }
    }

    func goHome() {
        if screen == .controls {
            server.send(json: ["type": "watch_controls", "on": false])
        }
        if case .video = screen {
            server.send(json: ["type": "stop_video"])
            displayLayer.flushAndRemoveImage()
        }
        input.active = false
        receivingVideo = false
        screen = .home
    }

    func run(_ shortcut: Shortcut) {
        server.send(json: ["type": "shortcut", "id": shortcut.id])
    }

    func media(_ action: String) {
        server.send(json: ["type": "media", "action": action])
    }

    /// Change a laptop setting or run a power action; see pc/controls.py apply().
    func control(_ name: String, _ value: Any = true) {
        server.send(json: ["type": "control", "name": name, "value": value])
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
    /// clipboard unless Settings > Extend Display > Paste from Other Apps is Allow.
    func sendClipboardIfChanged() {
        let pasteboard = UIPasteboard.general
        guard connected, pasteboard.changeCount != pasteboardSeen else { return }
        pasteboardSeen = pasteboard.changeCount
        if pasteboard.hasImages, let png = pasteboard.image?.pngData() {
            server.send(json: ["type": "clipboard", "kind": "image",
                               "png": png.base64EncodedString()])
        } else if pasteboard.hasStrings, let text = pasteboard.string {
            server.send(json: ["type": "clipboard", "kind": "text", "text": text])
        }
    }

    // MARK: messages from the laptop (on the server's queue)

    private func handle(_ message: LaptopMessage) {
        if message.type == "video_started" {
            // a new stream starts with new parameter sets; drop the old ones
            decoder.reset()
            videoFlowing = false
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
            case "now_playing":
                self.nowPlaying = message.nowPlaying
            case "controls":
                self.controls = message.controls
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
        } else if message.kind == "image", let png = message.png,
                  let data = Data(base64Encoded: png), let image = UIImage(data: data) {
            pasteboard.image = image
        } else {
            return
        }
        // our own write: don't send it straight back to the laptop
        pasteboardSeen = pasteboard.changeCount
    }
}
