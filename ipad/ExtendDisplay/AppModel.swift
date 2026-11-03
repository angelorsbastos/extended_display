import AVFoundation
import UIKit

enum VideoMode: String {
    case extend, mirror
}

enum Screen: Equatable {
    case home
    case video(VideoMode)
    case shortcuts
    case media
}

/// App state, shared by all screens. Published properties change on the main thread only.
final class AppModel: ObservableObject {
    @Published var connected = false
    @Published var screen: Screen = .home
    @Published var shortcuts: [Shortcut] = []
    @Published var nowPlaying: NowPlaying?
    @Published var receivingVideo = false
    @Published var videoError: String?
    @Published var listenError: String?

    let displayLayer = AVSampleBufferDisplayLayer()
    private let server = StreamServer()
    private lazy var decoder = H264Decoder(layer: displayLayer)
    private var videoFlowing = false  // only touched on the server's queue
    private var started = false

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    func start() {
        guard !started else { return }
        started = true

        server.onConnected = { [weak self] in
            DispatchQueue.main.async { self?.connected = true }
        }
        server.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connected = false
                self.nowPlaying = nil
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
        server.onMessage = { [weak self] message in
            self?.handle(message)
        }

        do {
            try server.start()
        } catch {
            listenError = "Could not listen on port \(StreamServer.port): \(error.localizedDescription)"
        }
    }

    // MARK: actions from the screens

    func open(_ screen: Screen) {
        self.screen = screen
        if case .video(let mode) = screen {
            receivingVideo = false
            videoError = nil
            displayLayer.flushAndRemoveImage()
            server.send(json: ["type": "start_video", "mode": mode.rawValue])
        }
    }

    func goHome() {
        if case .video = screen {
            server.send(json: ["type": "stop_video"])
            displayLayer.flushAndRemoveImage()
        }
        receivingVideo = false
        screen = .home
    }

    func run(_ shortcut: Shortcut) {
        server.send(json: ["type": "shortcut", "id": shortcut.id])
    }

    func media(_ action: String) {
        server.send(json: ["type": "media", "action": action])
    }

    // MARK: messages from the laptop (on the server's queue)

    private func handle(_ message: LaptopMessage) {
        if message.type == "video_started" {
            // a new stream starts with new parameter sets; drop the old ones
            decoder.reset()
            videoFlowing = false
        }
        DispatchQueue.main.async {
            switch message.type {
            case "hello":
                self.shortcuts = message.shortcuts ?? []
            case "now_playing":
                self.nowPlaying = message.nowPlaying
            case "error":
                self.videoError = message.message
            default:
                break
            }
        }
    }
}
