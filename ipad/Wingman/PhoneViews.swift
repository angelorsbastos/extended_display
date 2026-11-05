import SwiftUI
import UIKit

// MARK: - Trackpad

/// The phone screen as a touchpad for the laptop: one finger moves the pointer,
/// tap = click, two-finger tap = right-click, two fingers = scroll, touch and
/// hold then move = drag. The keyboard button types into the laptop.
struct TrackpadView: View {
    @ObservedObject var model: AppModel
    @FocusState private var keyboardUp: Bool

    var body: some View {
        VStack(spacing: 12) {
            TopBar(title: "Trackpad", model: model)
            TouchpadSurfaceView(send: model.pointer)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.tile))
                .overlay(alignment: .bottom) {
                    Text("Tap to click · two fingers to scroll or right-click · hold to drag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
            HStack(spacing: 12) {
                button("Esc", icon: "escape") { key(41) }
                button("Tab", icon: "arrow.right.to.line") { key(43) }
                button(keyboardUp ? "Hide keyboard" : "Keyboard", icon: "keyboard") {
                    keyboardUp.toggle()
                }
            }
            // invisible: it only brings up the keyboard and catches what's typed
            LaptopTyping(send: model.pointer, focus: $keyboardUp)
        }
        .screenPadding()
        .foregroundStyle(.white)
    }

    /// Press and release one key (HID usage, like the iPad's keyboard sends).
    private func key(_ usage: Int) {
        LaptopTyping.press(usage, send: model.pointer)
    }

    private func button(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.tile))
        }
        .buttonStyle(PressableStyle())
    }
}

/// The touch surface itself (UIKit, for exact multi-finger handling).
struct TouchpadSurfaceView: UIViewRepresentable {
    let send: ([String: Any]) -> Void

    func makeUIView(context: Context) -> TouchpadSurface {
        let view = TouchpadSurface()
        view.send = send
        return view
    }

    func updateUIView(_ view: TouchpadSurface, context: Context) {
        view.send = send
    }
}

final class TouchpadSurface: UIView {
    /// Points of two-finger movement per mouse-wheel notch.
    static let scrollPoints: CGFloat = 30
    static let tapTime: TimeInterval = 0.25
    static let tapSlop: CGFloat = 10
    static let holdTime: TimeInterval = 0.45

    var send: (([String: Any]) -> Void)?

    private var down: Set<UITouch> = []
    private var started = Date()
    private var mostFingers = 0
    private var travelled: CGFloat = 0
    private var last: CGPoint?
    private var dragging = false
    private var holdTimer: Timer?
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if down.isEmpty {
            started = Date()
            mostFingers = 0
            travelled = 0
            dragging = false
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                self?.startDragIfHeld()
            }
        }
        down.formUnion(touches)
        mostFingers = max(mostFingers, down.count)
        if down.count > 1 { holdTimer?.invalidate() }
        last = centre()  // a new finger: measure movement from here on
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = centre(), let previous = last else { return }
        let dx = point.x - previous.x, dy = point.y - previous.y
        last = point
        travelled += hypot(dx, dy)
        if travelled > Self.tapSlop { holdTimer?.invalidate() }
        switch down.count {
        case 1:
            // phone points -> laptop pointer movement (Windows adds its own acceleration)
            let speed = CGFloat(Prefs.pointerSpeedValue)
            send?(["type": "mouse_move", "dx": Double(dx * speed), "dy": Double(dy * speed)])
        case 2:
            // natural: content follows the fingers, like on the phone itself
            let scale = CGFloat(Prefs.scrollSpeedValue) / Self.scrollPoints * (Prefs.naturalScrollValue ? 1 : -1)
            send?(["type": "scroll", "dx": Double(-dx * scale), "dy": Double(dy * scale)])
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lift(touches)
    }

    private func lift(_ touches: Set<UITouch>) {
        down.subtract(touches)
        last = centre()
        guard down.isEmpty else { return }
        holdTimer?.invalidate()
        if dragging {
            send?(["type": "mouse_button", "button": "left", "down": false])
            dragging = false
        } else if Date().timeIntervalSince(started) < Self.tapTime && travelled < Self.tapSlop {
            let button = mostFingers >= 2 ? "right" : "left"
            send?(["type": "mouse_button", "button": button, "down": true])
            send?(["type": "mouse_button", "button": button, "down": false])
        }
    }

    /// Touch and hold without moving: press the button and keep it down while
    /// the finger moves (dragging a window, selecting text).
    private func startDragIfHeld() {
        guard down.count == 1, travelled < Self.tapSlop else { return }
        dragging = true
        if Prefs.hapticsOn { haptic.impactOccurred() }
        send?(["type": "mouse_button", "button": "left", "down": true])
    }

    private func centre() -> CGPoint? {
        guard !down.isEmpty else { return nil }
        let points = down.map { $0.location(in: self) }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                       y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }
}

