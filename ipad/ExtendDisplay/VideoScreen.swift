import AVFoundation
import SwiftUI
import UIKit

/// Full-screen video for Extend and Mirror. Three-finger tap goes back home.
struct VideoScreen: View {
    @ObservedObject var model: AppModel
    @State private var showHint = false

    var body: some View {
        ZStack {
            Color.black
            VideoView(displayLayer: model.displayLayer, videoSize: model.videoSize,
                      onTouches: { model.touches($0) },
                      onThreeFingerTap: { model.goHome() })

            if let error = model.videoError {
                status(icon: "exclamationmark.triangle", text: error)
            } else if !model.receivingVideo {
                status(icon: nil, text: "Starting…")
            }

            if showHint {
                VStack {
                    Spacer()
                    Text("Tap with three fingers to go back")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .padding(.bottom, 30)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .onChange(of: model.receivingVideo) { receiving in
            guard receiving else { return }
            withAnimation { showHint = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation { showHint = false }
            }
        }
    }

    private func status(icon: String?, text: String) -> some View {
        VStack(spacing: 18) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 44))
            } else {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
            }
            Text(text)
                .font(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button("Back to home") { model.goHome() }
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
    }
}

/// Hosts the AVSampleBufferDisplayLayer inside SwiftUI, and reports fingers on it.
struct VideoView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let videoSize: CGSize
    let onTouches: ([[String: Any]]) -> Void
    let onThreeFingerTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onThreeFingerTap)
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView(displayLayer: displayLayer)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.numberOfTouchesRequired = 3
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        context.coordinator.onTap = onThreeFingerTap
        uiView.videoSize = videoSize
        uiView.onTouches = onTouches
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
        }

        @objc func tapped() {
            onTap()
        }
    }

    final class LayerView: UIView {
        var videoSize = CGSize(width: 16, height: 9)
        var onTouches: (([[String: Any]]) -> Void)?

        private let displayLayer: AVSampleBufferDisplayLayer
        /// Each finger keeps a small number (0-9) while it touches; Windows wants stable ids.
        private var fingerIds: [ObjectIdentifier: Int] = [:]

        init(displayLayer: AVSampleBufferDisplayLayer) {
            self.displayLayer = displayLayer
            super.init(frame: .zero)
            isMultipleTouchEnabled = true
            // a layer has one parent, so this also takes it from a previous VideoView
            layer.addSublayer(displayLayer)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            displayLayer.frame = bounds
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            report(touches, state: "down")
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            report(touches, state: "move")
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            report(touches, state: "up")
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            report(touches, state: "cancel")
        }

        /// Positions are sent as fractions (0-1) of the picture, leaving out the
        /// black bars, so the laptop can map them onto its screen.
        private func report(_ touches: Set<UITouch>, state: String) {
            let picture = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
            guard picture.width > 0, picture.height > 0 else { return }
            var fingers: [[String: Any]] = []
            // only real fingers: trackpad clicks are sent as mouse input instead
            for touch in touches where touch.type == .direct {
                let key = ObjectIdentifier(touch)
                if state == "down" {
                    let used = Set(fingerIds.values)
                    fingerIds[key] = (0..<10).first { !used.contains($0) } ?? 0
                }
                guard let id = fingerIds[key] else { continue }
                let point = touch.location(in: self)
                fingers.append(["id": id,
                                "x": Double((point.x - picture.minX) / picture.width),
                                "y": Double((point.y - picture.minY) / picture.height),
                                "state": state])
                if state == "up" || state == "cancel" {
                    fingerIds[key] = nil
                }
            }
            if !fingers.isEmpty {
                onTouches?(fingers)
            }
        }
    }
}
