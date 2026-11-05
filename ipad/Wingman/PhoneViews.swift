import SwiftUI
import UIKit

// MARK: - Trackpad

/// A touchpad and keyboard for the laptop, on the iPhone and the iPad: one
/// finger moves the pointer, tap = click, two-finger tap = right-click, two
/// fingers = scroll, touch and hold then move = drag. Under it, a key bar
/// (Esc, Tab, arrows, Backspace, Enter, and Ctrl / Alt / Win / Shift, which
/// stay held while lit, like on a real keyboard: Alt, then Tab, Tab...) and
/// the on-screen keyboard. While a modifier is held, letters and digits go as
/// keys, so Ctrl + C copies.
struct TrackpadView: View {
    @ObservedObject var model: AppModel
    @FocusState private var keyboardUp: Bool
    /// Modifiers held down on the laptop right now (HID usages).
    @State private var held: Set<Int> = []

    // HID usages as the laptop maps them (pc/inputs.py): the iPad's Cmd is the
    // laptop's Ctrl, Option is Alt, and the iPad's Ctrl is the Windows key
    private static let ctrl = 227, alt = 226, win = 224, shift = 225

    var body: some View {
        VStack(spacing: 12) {
            TopBar(title: isPhone ? "Trackpad" : "Trackpad & keyboard", model: model)
            TouchpadSurfaceView(send: model.pointer)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.tile))
                .overlay(alignment: .bottom) {
                    Text("Tap to click · two fingers to scroll or right-click · hold to drag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
            keyBar
            // invisible: it only brings up the keyboard and catches what's typed
            LaptopTyping(send: model.pointer, focus: $keyboardUp,
                         asKeys: { !held.subtracting([Self.shift]).isEmpty })
        }
        .screenPadding()
        .foregroundStyle(.white)
        .onDisappear { releaseAll() }  // never leave a key held on the laptop
    }

    // MARK: keys

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: isPhone ? 8 : 10) {
                modifierKey("Ctrl", usage: Self.ctrl)
                modifierKey("Alt", usage: Self.alt)
                modifierKey("Win", icon: "squareshape.split.2x2", usage: Self.win)
                modifierKey("Shift", icon: "shift", usage: Self.shift)
                divider
                key("Esc", icon: "escape", usage: 41)
                key("Tab", icon: "arrow.right.to.line", usage: 43)
                key("Back", icon: "delete.left", usage: 42)
                key("Enter", icon: "return", usage: 40)
                divider
                key(nil, icon: "arrow.left", usage: 80)
                key(nil, icon: "arrow.up", usage: 82)
                key(nil, icon: "arrow.down", usage: 81)
                key(nil, icon: "arrow.right", usage: 79)
                divider
                Button {
                    model.tap()
                    keyboardUp.toggle()
                } label: {
                    keyFace(keyboardUp ? "Hide" : "Keyboard",
                            icon: keyboardUp ? "keyboard.chevron.compact.down" : "keyboard", lit: keyboardUp)
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.vertical, 2)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 28)
    }

    /// A key that's pressed and released (with any held modifiers still down).
    private func key(_ title: String?, icon: String, usage: Int) -> some View {
        Button {
            model.tap()
            LaptopTyping.press(usage, send: model.pointer)
        } label: {
            keyFace(title, icon: icon, lit: false)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title ?? icon)
    }

    /// Ctrl / Alt / Win / Shift: tap to hold it down on the laptop, tap again to let go.
    private func modifierKey(_ title: String, icon: String? = nil, usage: Int) -> some View {
        let on = held.contains(usage)
        return Button {
            model.tap()
            if on {
                held.remove(usage)
                model.pointer(["type": "key", "usage": usage, "down": false])
            } else {
                held.insert(usage)
                model.pointer(["type": "key", "usage": usage, "down": true])
            }
        } label: {
            keyFace(title, icon: icon, lit: on)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func keyFace(_ title: String?, icon: String?, lit: Bool) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon) }
            if let title { Text(title) }
        }
        .font(.system(size: isPhone ? 14 : 16, weight: .semibold))
        .foregroundStyle(lit ? Theme.onText : Theme.text)
        .padding(.horizontal, isPhone ? 12 : 16)
        .frame(minWidth: isPhone ? 44 : 56, minHeight: isPhone ? 44 : 52)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(lit ? Theme.on : Theme.tile))
    }

    private func releaseAll() {
        for usage in held {
            model.pointer(["type": "key", "usage": usage, "down": false])
        }
        held.removeAll()
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

