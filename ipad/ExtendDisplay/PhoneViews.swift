import SwiftUI
import UIKit

// MARK: - Trackpad

/// The phone screen as a touchpad for the laptop: one finger moves the pointer,
/// tap = click, two-finger tap = right-click, two fingers = scroll, touch and
/// hold then move = drag. The keyboard button types into the laptop.
struct TrackpadView: View {
    @ObservedObject var model: AppModel
    @State private var typing = false
    @State private var typed = TrackpadView.baseline
    @FocusState private var keyboardUp: Bool

    /// The text field always holds one space, so deleting is noticed even when
    /// nothing was typed (it becomes a Backspace on the laptop).
    static let baseline = " "

    var body: some View {
        VStack(spacing: 12) {
            TopBar(title: "Trackpad", model: model)
            TouchpadSurfaceView(send: model.pointer)
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(0.07)))
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
            TextField("", text: $typed)
                .focused($keyboardUp)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onChange(of: typed) { text in
                    if text == Self.baseline { return }
                    if text.count < Self.baseline.count {
                        key(42)  // Backspace
                    } else if text.hasPrefix(Self.baseline) {
                        model.pointer(["type": "type_text", "text": String(text.dropFirst(Self.baseline.count))])
                    } else {
                        model.pointer(["type": "type_text", "text": text])
                    }
                    typed = Self.baseline
                }
                .onSubmit {
                    key(40)  // Enter
                    keyboardUp = true  // keep typing
                }
        }
        .screenPadding()
        .foregroundStyle(.white)
    }

    /// Press and release one key (HID usage, like the iPad's keyboard sends).
    private func key(_ usage: Int) {
        model.pointer(["type": "key", "usage": usage, "down": true])
        model.pointer(["type": "key", "usage": usage, "down": false])
    }

    private func button(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.1)))
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
    /// Phone points -> laptop pointer movement (Windows adds its own acceleration).
    static let pointerSpeed: CGFloat = 2.2
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
            send?(["type": "mouse_move", "dx": Double(dx * Self.pointerSpeed), "dy": Double(dy * Self.pointerSpeed)])
        case 2:
            // content follows the fingers, like on the phone itself
            send?(["type": "scroll", "dx": Double(-dx / Self.scrollPoints), "dy": Double(dy / Self.scrollPoints)])
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
        haptic.impactOccurred()
        send?(["type": "mouse_button", "button": "left", "down": true])
    }

    private func centre() -> CGPoint? {
        guard !down.isEmpty else { return nil }
        let points = down.map { $0.location(in: self) }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                       y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }
}

// MARK: - Dock

/// For a phone standing next to the laptop, plugged in: a big clock, what's
/// playing with its controls, the laptop's battery, and a row of shortcuts.
/// Works both ways round; on its side is the classic dock look.
struct DockView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                if wide {
                    HStack(spacing: 28) {
                        clock.frame(maxWidth: .infinity)
                        VStack(spacing: 16) {
                            nowPlaying
                            shortcutsRow
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                } else {
                    VStack(spacing: 28) {
                        Spacer()
                        clock
                        nowPlaying
                        shortcutsRow
                        Spacer()
                    }
                    .padding(16)
                }
                Button {
                    model.goHome()
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                .padding(8)
            }
        }
        .foregroundStyle(.white)
    }

    private var clock: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 4) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 96, weight: .thin, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if let battery = model.controls?.battery, let percent = battery.percent {
                    Label("Laptop \(percent)%\(battery.charging ? " · charging" : "")",
                          systemImage: battery.charging ? "battery.100.bolt" : "laptopcomputer")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        }
    }

    private var nowPlaying: some View {
        VStack(spacing: 12) {
            if let playing = model.nowPlaying {
                VStack(spacing: 2) {
                    Text(playing.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(playing.artist.isEmpty ? playing.app : playing.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("Nothing playing on the laptop")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 34) {
                MediaButton(icon: "backward.fill", size: 26) { model.media("previous") }
                MediaButton(icon: model.nowPlaying?.playing == true ? "pause.fill" : "play.fill",
                            size: 34, prominent: true) { model.media("play_pause") }
                MediaButton(icon: "forward.fill", size: 26) { model.media("next") }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.06)))
    }

    private var shortcutsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.shortcuts) { shortcut in
                    Button {
                        model.run(shortcut)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: shortcut.icon)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Color.orange)
                            Text(shortcut.title)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(width: 76, height: 66)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }
}
