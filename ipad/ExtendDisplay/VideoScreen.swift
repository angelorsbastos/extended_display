import AVFoundation
import SwiftUI
import UIKit

/// Full-screen video for Extend and Mirror. Three-finger tap goes back home,
/// four-finger tap opens the clipboard history.
struct VideoScreen: View {
    @ObservedObject var model: AppModel
    @State private var showHint = false
    @AppStorage(Prefs.quickButton) private var showQuickButton = true

    var body: some View {
        ZStack {
            Color.black
            VideoView(displayLayer: model.displayLayer, videoSize: model.videoSize,
                      onTouches: { model.touches($0) },
                      onThreeFingerTap: { model.goHome() },
                      onFourFingerTap: {
                          model.panelTab = .clipboard
                          withAnimation { model.showingClipboard = true }
                      })

            if let error = model.videoError {
                status(icon: "exclamationmark.triangle", text: error)
            } else if !model.receivingVideo {
                status(icon: nil, text: "Starting…")
            }

            if showHint {
                VStack {
                    Spacer()
                    Text("The small button has controls and shortcuts; three fingers go back")
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

            if model.receivingVideo && !model.showingClipboard && showQuickButton {
                QuickButton(model: model)
            }

            if model.showingClipboard {
                QuickPanel(model: model)
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

/// A small, faint button floating over the laptop's picture: tap for the quick
/// panel (controls, shortcuts, clipboard). Drag it anywhere; it settles against
/// the nearer side, and stays where it was put next time.
struct QuickButton: View {
    @ObservedObject var model: AppModel
    @AppStorage("quickButton.x") private var x = 0.97   // fractions of the screen
    @AppStorage("quickButton.y") private var y = 0.12
    @State private var dragging: CGSize = .zero
    @State private var pressed = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .opacity(pressed || dragging != .zero ? 1 : 0.4)
                .position(x: min(max(x * size.width + dragging.width, 24), size.width - 24),
                          y: min(max(y * size.height + dragging.height, 24), size.height - 24))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        pressed = true
                        dragging = drag.translation
                    }
                    .onEnded { drag in
                        pressed = false
                        let moved = hypot(drag.translation.width, drag.translation.height)
                        if moved < 6 {  // a tap
                            dragging = .zero
                            model.panelTab = .shortcuts
                            model.tap()
                            withAnimation { model.showingClipboard = true }
                            return
                        }
                        let endX = (x * size.width + drag.translation.width) / size.width
                        let endY = (y * size.height + drag.translation.height) / size.height
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            x = endX < 0.5 ? 0.03 : 0.97  // settle against the nearer side
                            y = min(max(endY, 0.05), 0.95)
                            dragging = .zero
                        }
                    })
                .accessibilityLabel("Quick controls")
        }
    }
}

/// Hosts the AVSampleBufferDisplayLayer inside SwiftUI, and reports fingers on it.
struct VideoView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let videoSize: CGSize
    let onTouches: ([[String: Any]]) -> Void
    let onThreeFingerTap: () -> Void
    let onFourFingerTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onThree: onThreeFingerTap, onFour: onFourFingerTap)
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView(displayLayer: displayLayer)
        let three = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.threeTapped))
        three.numberOfTouchesRequired = 3
        let four = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.fourTapped))
        four.numberOfTouchesRequired = 4
        // fingers rarely land at exactly the same moment: a four-finger tap
        // shouldn't count as a three-finger one on the way
        three.require(toFail: four)
        view.addGestureRecognizer(three)
        view.addGestureRecognizer(four)
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        context.coordinator.onThree = onThreeFingerTap
        context.coordinator.onFour = onFourFingerTap
        uiView.videoSize = videoSize
        uiView.onTouches = onTouches
    }

    final class Coordinator: NSObject {
        var onThree: () -> Void
        var onFour: () -> Void

        init(onThree: @escaping () -> Void, onFour: @escaping () -> Void) {
            self.onThree = onThree
            self.onFour = onFour
        }

        @objc func threeTapped() {
            onThree()
        }

        @objc func fourTapped() {
            onFour()
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
            // hide the iPad's own pointer over the video: the trackpad drives the
            // Windows pointer, and iPadOS doesn't always grant the pointer lock
            addInteraction(UIPointerInteraction(delegate: self))
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

extension VideoView.LayerView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction,
                            styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }
}
