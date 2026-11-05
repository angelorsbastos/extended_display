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
                } else if text.hasPrefix(Self.baseline) {
                    send(["type": "type_text", "text": String(text.dropFirst(Self.baseline.count))])
                } else {
                    send(["type": "type_text", "text": text])
                }
                typed = Self.baseline
            }
            .onSubmit {
                Self.press(40, send: send)  // Enter
                focus.wrappedValue = true   // keep typing
            }
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
