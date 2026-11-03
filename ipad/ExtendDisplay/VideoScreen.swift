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
            VideoView(displayLayer: model.displayLayer, onThreeFingerTap: { model.goHome() })

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

/// Hosts the AVSampleBufferDisplayLayer inside SwiftUI.
struct VideoView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
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
        private let displayLayer: AVSampleBufferDisplayLayer

        init(displayLayer: AVSampleBufferDisplayLayer) {
            self.displayLayer = displayLayer
            super.init(frame: .zero)
            // a layer has one parent, so this also takes it from a previous VideoView
            layer.addSublayer(displayLayer)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            displayLayer.frame = bounds
        }
    }
}
