import AVFoundation
import SwiftUI
import UIKit

@main
struct ExtendDisplayApp: App {
    @StateObject private var model = DisplayModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    // a monitor should not go to sleep
                    UIApplication.shared.isIdleTimerDisabled = true
                    model.start()
                }
        }
    }
}

final class DisplayModel: ObservableObject {
    @Published var connected = false
    @Published var receivingVideo = false
    @Published var error: String?

    let displayLayer = AVSampleBufferDisplayLayer()
    private let server = StreamServer()
    private lazy var decoder = H264Decoder(layer: displayLayer)
    private var started = false

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    func start() {
        guard !started else { return }
        started = true

        server.onConnected = { [weak self] in
            self?.decoder.reset()
            DispatchQueue.main.async { self?.connected = true }
        }
        server.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connected = false
                self.receivingVideo = false
                self.displayLayer.flushAndRemoveImage()
            }
        }
        server.onVideo = { [weak self] data in
            guard let self, self.decoder.decode(data), !self.receivingVideo else { return }
            DispatchQueue.main.async { self.receivingVideo = true }
        }

        do {
            try server.start()
        } catch {
            self.error = "Could not listen on port \(StreamServer.port): \(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: DisplayModel

    var body: some View {
        ZStack {
            Color.black
            VideoView(displayLayer: model.displayLayer)
            if !model.receivingVideo {
                VStack(spacing: 12) {
                    Image(systemName: "display.2")
                        .font(.system(size: 56))
                    Text(model.connected ? "Connected, waiting for video…" : "Waiting for PC")
                        .font(.title2.bold())
                    Text(model.error ?? "Plug the iPad into the PC and run  python pc/stream.py")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

/// Hosts the AVSampleBufferDisplayLayer inside SwiftUI.
struct VideoView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> LayerView {
        LayerView(displayLayer: displayLayer)
    }

    func updateUIView(_ uiView: LayerView, context: Context) {}

    final class LayerView: UIView {
        private let displayLayer: AVSampleBufferDisplayLayer

        init(displayLayer: AVSampleBufferDisplayLayer) {
            self.displayLayer = displayLayer
            super.init(frame: .zero)
            layer.addSublayer(displayLayer)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            displayLayer.frame = bounds
        }
    }
}
