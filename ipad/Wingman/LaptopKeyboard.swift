import SwiftUI

// MARK: - The keys

/// One key of the on-screen laptop keyboard (Portuguese, Portugal layout).
/// Keys are sent by position (HID usage), so the laptop's Windows layout
/// decides the character, exactly like a real keyboard; the labels show what
/// Windows' Portuguese layout types. Flicked and held characters are typed as
/// text, so they come out the same whatever the layout.
struct DeckKey: Identifiable {
    enum Role { case character, action, modifier, shift, capsLock, upDown }

    let id: String
    let label: String
    var icon: String? = nil
    var usage: Int = 0
    var width: CGFloat = 1
    /// Typed by flicking down on the key (shown small in its corner).
    var flick: String? = nil
    /// Offered by holding the key, in a little popup.
    var variants: [String] = []
    var role: Role = .character
    var repeats = false
    /// The tall Portuguese Enter is two keys that touch: the top one joins down.
    var joinsDown = false
    var joinsUp = false

    static func char(_ label: String, _ usage: Int, flick: String? = nil, hold: [String] = []) -> DeckKey {
        DeckKey(id: "c\(usage)", label: label, usage: usage, flick: flick, variants: hold)
    }

    static func action(_ label: String, icon: String?, usage: Int, width: CGFloat, repeats: Bool = false) -> DeckKey {
        DeckKey(id: "a\(usage)", label: label, icon: icon, usage: usage, width: width, role: .action, repeats: repeats)
    }

    static func modifier(_ label: String, icon: String? = nil, usage: Int, width: CGFloat) -> DeckKey {
        DeckKey(id: "m\(usage)", label: label, icon: icon, usage: usage, width: width, role: .modifier)
    }

    // HID usages as the laptop maps them (pc/inputs.py): Cmd (227) is Ctrl,
    // Option (226) is Alt, right Option (230) is AltGr, Ctrl (224) is Windows
    static let rows: [[DeckKey]] = [
        [char("\\", 53, flick: "|"), char("1", 30, flick: "!"), char("2", 31, flick: "\"", hold: ["@"]),
         char("3", 32, flick: "#", hold: ["£"]), char("4", 33, flick: "$", hold: ["§", "€"]),
         char("5", 34, flick: "%"), char("6", 35, flick: "&"), char("7", 36, flick: "/", hold: ["{"]),
         char("8", 37, flick: "(", hold: ["["]), char("9", 38, flick: ")", hold: ["]"]),
         char("0", 39, flick: "=", hold: ["}"]), char("'", 45, flick: "?"), char("«", 46, flick: "»"),
         action("Delete", icon: "delete.left", usage: 42, width: 2, repeats: true)],
        [action("Tab", icon: "arrow.right.to.line", usage: 43, width: 1.5),
         char("q", 20), char("w", 26), char("e", 8, flick: "é", hold: ["é", "è", "ê", "€"]), char("r", 21),
         char("t", 23), char("y", 28), char("u", 24, flick: "ú", hold: ["ú", "ù", "û", "ü"]),
         char("i", 12, flick: "í", hold: ["í", "ì", "î"]), char("o", 18, flick: "ó", hold: ["ó", "ò", "ô", "õ"]),
         char("p", 19), char("+", 47, flick: "*", hold: ["¨"]), char("´", 48, flick: "`"),
         DeckKey(id: "enterTop", label: "", usage: 40, width: 1.5, role: .action, joinsDown: true)],
        [DeckKey(id: "caps", label: "Caps", icon: "capslock", width: 1.75, role: .capsLock),
         char("a", 4, flick: "á", hold: ["á", "à", "â", "ã"]), char("s", 22), char("d", 7), char("f", 9),
         char("g", 10), char("h", 11), char("j", 13), char("k", 14), char("l", 15), char("ç", 51),
         char("º", 52, flick: "ª"), char("~", 50, flick: "^"),
         DeckKey(id: "enter", label: "Enter", icon: "return", usage: 40, width: 1.25, role: .action,
                 joinsUp: true)],
        [DeckKey(id: "lshift", label: "Shift", icon: "shift", width: 1.25, role: .shift),
         char("<", 100, flick: ">"), char("z", 29), char("x", 27), char("c", 6, hold: ["ç"]), char("v", 25),
         char("b", 5), char("n", 17, hold: ["ñ"]), char("m", 16), char(",", 54, flick: ";"),
         char(".", 55, flick: ":", hold: ["…"]), char("-", 56, flick: "_", hold: ["–", "—"]),
         DeckKey(id: "rshift", label: "Shift", icon: "shift", width: 2.75, role: .shift)],
        [modifier("Ctrl", usage: 227, width: 1.25), modifier("Win", icon: "squareshape.split.2x2", usage: 224, width: 1.25),
         modifier("Alt", usage: 226, width: 1.25), DeckKey(id: "space", label: "", usage: 44, width: 6.25),
         modifier("AltGr", usage: 230, width: 1.25),
         action("", icon: "arrow.left", usage: 80, width: 1.25, repeats: true),
         DeckKey(id: "updown", label: "", width: 1.25, role: .upDown),
         action("", icon: "arrow.right", usage: 79, width: 1.25, repeats: true)],
    ]
}

// MARK: - The keyboard

/// A Windows keyboard for the laptop with the iPad's touches: flick down on a
/// key for its small character, hold a key for its variants (à â ã, €, @...),
/// hold Delete or an arrow to repeat. Ctrl, Shift, Win, Alt and AltGr work
/// like real keys: down while touched (hold Ctrl with one finger, tap C with
/// another). Caps is the real Caps Lock.
struct LaptopKeyboard: View {
    let send: ([String: Any]) -> Void

    /// Modifier keys under a finger right now (HID usages; Shift is 225).
    @State private var held: [String: Int] = [:]
    @State private var capsOn = false

    private var shifted: Bool { held.values.contains(225) || capsOn }

    var body: some View {
        GeometryReader { geometry in
            let unit = geometry.size.width / 15
            let rowHeight = geometry.size.height / CGFloat(DeckKey.rows.count)
            VStack(spacing: 0) {
                ForEach(0..<DeckKey.rows.count, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(DeckKey.rows[row]) { key in
                            keyView(key, width: unit * key.width, height: rowHeight)
                        }
                    }
                }
            }
        }
        .onDisappear { releaseAll() }  // never leave a key held on the laptop
    }

    @ViewBuilder private func keyView(_ key: DeckKey, width: CGFloat, height: CGFloat) -> some View {
        switch key.role {
        case .upDown:
            VStack(spacing: 0) {
                KeyCap(label: "", icon: "arrow.up", repeats: true, special: true, width: width, height: height / 2,
                       onTap: { press(82) })
                KeyCap(label: "", icon: "arrow.down", repeats: true, special: true, width: width, height: height / 2,
                       onTap: { press(81) })
            }
        case .modifier:
            KeyCap(label: key.label, icon: key.icon, lit: held[key.id] != nil, special: true,
                   width: width, height: height, onTap: {}, onHold: { hold(key, $0) })
        case .shift:
            KeyCap(label: key.label, icon: key.icon, lit: held[key.id] != nil, special: true,
                   width: width, height: height, onTap: {},
                   onHold: { hold(DeckKey(id: key.id, label: "", usage: 225), $0) })
        case .capsLock:
            KeyCap(label: key.label, icon: capsOn ? "capslock.fill" : key.icon, lit: capsOn, special: true,
                   width: width, height: height, onTap: {
                       LaptopTyping.press(57, send: send)  // the laptop's own Caps Lock
                       capsOn.toggle()
                   })
        case .action:
            KeyCap(label: key.label, icon: key.icon, repeats: key.repeats, special: true,
                   joinsDown: key.joinsDown, joinsUp: key.joinsUp,
                   width: width, height: height, onTap: { press(key.usage) })
        case .character:
            KeyCap(label: shifted ? key.label.uppercased() : key.label, flick: key.flick,
                   variants: key.variants, width: width, height: height,
                   onTap: { press(key.usage) }, onText: { type($0) })
        }
    }

    // MARK: sending

    /// Press and release a key (any modifier held down applies, as on a real keyboard).
    private func press(_ usage: Int) {
        LaptopTyping.press(usage, send: send)
    }

    /// A flicked or held character: typed as text (capital with Shift or Caps).
    private func type(_ text: String) {
        send(["type": "type_text", "text": shifted ? text.uppercased() : text])
    }

    /// A modifier touched (down) or let go (up).
    private func hold(_ key: DeckKey, _ down: Bool) {
        if down {
            held[key.id] = key.usage
        } else {
            held[key.id] = nil
        }
        send(["type": "key", "usage": key.usage, "down": down])
    }

    private func releaseAll() {
        for usage in held.values {
            send(["type": "key", "usage": usage, "down": false])
        }
        held.removeAll()
    }
}

// MARK: - One key

/// A key cap that reads taps, flicks down (its small character), holds
/// (variants popup, or repeating) and slides across the popup to choose.
private struct KeyCap: View {
    let label: String
    var icon: String? = nil
    var flick: String? = nil
    var variants: [String] = []
    var repeats = false
    var lit = false
    var special = false
    var joinsDown = false
    var joinsUp = false
    let width: CGFloat
    let height: CGFloat
    let onTap: () -> Void
    var onText: (String) -> Void = { _ in }
    /// Modifier keys: down when the finger lands, up when it lifts (no tap).
    var onHold: ((Bool) -> Void)? = nil

    @State private var pressing = false
    @State private var travel: CGSize = .zero
    @State private var popup = false
    @State private var selection = 0
    @State private var repeating = false
    @State private var holdTimer: Timer?
    @State private var repeatTimer: Timer?

    private var gap: CGFloat { max(3, min(width, height) * 0.08) }
    private var flicking: Bool { flick != nil && travel.height > 14 && !popup }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill)
            if let flick, !flicking {
                Text(flick)
                    .font(.system(size: max(10, height * 0.2)))
                    .foregroundStyle(lit ? Theme.onText.opacity(0.6) : Theme.secondary)
                    .padding(.leading, 6)
                    .padding(.top, 3)
            }
            face
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, gap / 2)
        .padding(.top, joinsUp ? -1 : gap / 2)       // the tall Enter's two halves touch
        .padding(.bottom, joinsDown ? -1 : gap / 2)
        .frame(width: width, height: height)
        .overlay(alignment: .bottomLeading) {
            if popup {
                popupView.offset(y: -height)
            }
        }
        .zIndex(popup || pressing ? 10 : 0)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { changed($0) }
            .onEnded { ended($0) })
        .accessibilityLabel(label.isEmpty ? (icon ?? "key") : label)
    }

    @ViewBuilder private var face: some View {
        if let icon {
            Image(systemName: icon)
                .font(.system(size: max(13, height * 0.26), weight: .semibold))
                .foregroundStyle(lit ? Theme.onText : Theme.text)
        } else {
            Text(flicking ? (flick ?? label) : label)
                .font(.system(size: max(14, height * (special ? 0.22 : 0.34)), weight: special ? .semibold : .regular))
                .foregroundStyle(lit ? Theme.onText : Theme.text)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    private var fill: Color {
        if lit { return Theme.on }
        if pressing { return Color(white: 0.34) }
        return special ? Theme.tile : Theme.tileRaised
    }

    private var popupView: some View {
        HStack(spacing: 2) {
            ForEach(Array(variants.enumerated()), id: \.offset) { index, variant in
                Text(variant)
                    .font(.system(size: max(16, height * 0.38)))
                    .foregroundStyle(index == selection ? Color.white : Theme.text)
                    .frame(width: width - gap, height: height - gap)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(index == selection ? Theme.accent : Theme.tileRaised))
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.tile))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    private func changed(_ value: DragGesture.Value) {
        if let onHold {
            if !pressing {
                pressing = true
                haptic()
                onHold(true)
            }
            return
        }
        if !pressing {
            pressing = true
            haptic()
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                if !variants.isEmpty {
                    popup = true
                    selection = 0
                    haptic()
                } else if repeats {
                    repeating = true
                    onTap()
                    repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in onTap() }
                }
            }
        }
        travel = value.translation
        if popup {
            let option = width - gap + 2
            selection = min(max(Int(floor(value.location.x / option)), 0), variants.count - 1)
        } else if abs(travel.height) > 14 || abs(travel.width) > 20 {
            holdTimer?.invalidate()  // a flick or a slide, not a hold
        }
    }

    private func ended(_ value: DragGesture.Value) {
        if let onHold {
            pressing = false
            onHold(false)
            return
        }
        holdTimer?.invalidate()
        repeatTimer?.invalidate()
        if popup {
            onText(variants[selection])
        } else if repeating {
            // already sent while held
        } else if let flick, value.translation.height > 14 {
            onText(flick)
        } else if abs(value.translation.width) < 30 && abs(value.translation.height) < 30 {
            onTap()
        }
        pressing = false
        popup = false
        repeating = false
        travel = .zero
    }
}

// MARK: - The deck: keyboard and trackpad

/// The iPad as a laptop deck: the keyboard on the left, the trackpad on the
/// right (on top when upright), and a handle between them that hides the
/// trackpad to give the keyboard the whole width, and brings it back.
struct KeyboardDeckView: View {
    @ObservedObject var model: AppModel
    let showKeyBar: () -> Void
    @AppStorage("deck.showTrackpad") private var showTrackpad = true

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let landscape = size.width > size.height
            VStack(spacing: 14) {
                TopBar(title: "Keyboard & trackpad", model: model)
                    .overlay(alignment: .trailing) {
                        Pill(icon: "keyboard.badge.ellipsis", text: "Key bar view") { showKeyBar() }
                            .padding(.trailing, 24)  // clear of the connection dot
                    }
                Spacer(minLength: 0)  // the free space: nothing under your hands' way
                if landscape {
                    let height = min(size.height * 0.5, size.width * 0.33)
                    HStack(spacing: 8) {
                        LaptopKeyboard(send: model.pointer)
                        handle(landscape: true)
                        if showTrackpad {
                            trackpad.frame(width: size.width * 0.27)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .frame(height: height)
                } else {
                    VStack(spacing: 8) {
                        if showTrackpad {
                            trackpad.frame(height: size.height * 0.28)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        handle(landscape: false)
                        LaptopKeyboard(send: model.pointer)
                            .frame(height: size.width * 0.45)
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showTrackpad)
        }
        .padding(isPhone ? 12 : 20)
        .foregroundStyle(Theme.text)
    }

    private var trackpad: some View {
        TouchpadSurfaceView(send: model.pointer)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.tile))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The thin bar between keyboard and trackpad: tap to hide or show the trackpad.
    private func handle(landscape: Bool) -> some View {
        Button {
            haptic()
            showTrackpad.toggle()
        } label: {
            ZStack {
                Capsule().fill(Theme.tile)
                Image(systemName: landscape ? (showTrackpad ? "chevron.right" : "chevron.left")
                                            : (showTrackpad ? "chevron.up" : "chevron.down"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(width: landscape ? 18 : 64, height: landscape ? 64 : 18)
            .frame(maxWidth: landscape ? nil : .infinity, maxHeight: landscape ? .infinity : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showTrackpad ? "Hide the trackpad" : "Show the trackpad")
    }
}
