import Combine
import GameController
import SwiftUI

/// Typing into the laptop with the on-screen keyboard: an invisible text field
/// that brings the keyboard up and turns what's typed into messages. It always
/// holds one space, so deleting is noticed even when nothing was typed (it
/// becomes a Backspace on the laptop). Return is Enter, and the keyboard stays up.
struct LaptopTyping: View {
    let send: ([String: Any]) -> Void
    var focus: FocusState<Bool>.Binding
    /// True while Ctrl / Alt / Win is held: letters and digits then go as key
    /// presses (typed text can't make shortcuts like Ctrl + C).
    var asKeys: () -> Bool = { false }

    static let baseline = " "
    @State private var typed = LaptopTyping.baseline

    var body: some View {
        TextField("", text: $typed)
            .focused(focus)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
            .onChange(of: typed) { text in
                if text == Self.baseline { return }
                if text.count < Self.baseline.count {
                    Self.press(42, send: send)  // Backspace
                } else {
                    let added = text.hasPrefix(Self.baseline) ? String(text.dropFirst(Self.baseline.count)) : text
                    if asKeys(), let usages = Self.usages(added) {
                        usages.forEach { Self.press($0, send: send) }
                    } else {
                        send(["type": "type_text", "text": added])
                    }
                }
                typed = Self.baseline
            }
            .onSubmit {
                Self.press(40, send: send)  // Enter
                focus.wrappedValue = true   // keep typing
            }
    }

    /// a-z, 0-9 and space as HID key usages (for shortcuts), or nil if there's anything else.
    static func usages(_ text: String) -> [Int]? {
        var result: [Int] = []
        for character in text.lowercased() {
            guard let ascii = character.asciiValue else { return nil }
            switch ascii {
            case 97...122: result.append(Int(ascii) - 97 + 4)   // a -> 4 ... z -> 29
            case 49...57: result.append(Int(ascii) - 49 + 30)   // 1 -> 30 ... 9 -> 38
            case 48: result.append(39)                          // 0
            case 32: result.append(44)                          // space
            default: return nil
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Press and release one key (HID usage, like a real keyboard sends).
    static func press(_ usage: Int, send: ([String: Any]) -> Void) {
        send(["type": "key", "usage": usage, "down": true])
        send(["type": "key", "usage": usage, "down": false])
    }
}

/// Whether a hardware keyboard is attached (Magic Keyboard, Bluetooth, ...).
/// Its keys already reach the laptop, so the on-screen one isn't offered then:
/// with both, everything would be typed twice.
final class HardwareKeyboard: ObservableObject {
    static let shared = HardwareKeyboard()
    @Published private(set) var attached = GCKeyboard.coalesced != nil
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.attached = GCKeyboard.coalesced != nil
            })
        }
    }
}
