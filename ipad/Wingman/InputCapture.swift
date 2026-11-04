import GameController

/// Reads a keyboard and trackpad/mouse attached to the iPad (Magic Keyboard,
/// Combo Touch, Bluetooth, ...) through the GameController framework and turns
/// them into messages for the laptop. Only forwards while `active` is true,
/// i.e. while a video screen is showing.
final class InputCapture {
    /// Trackpad points -> Windows mouse counts. Windows adds its own acceleration.
    static let pointerSpeed = 1.0
    /// Trackpad scroll units -> mouse wheel notches.
    static let scrollSpeed = 0.1

    var active = false
    var send: (([String: Any]) -> Void)?

    init() {
        let center = NotificationCenter.default
        center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attach(mouse) }
        }
        center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] note in
            if let keyboard = note.object as? GCKeyboard { self?.attach(keyboard) }
        }
        for mouse in GCMouse.mice() {
            attach(mouse)
        }
        if let keyboard = GCKeyboard.coalesced {
            attach(keyboard)
        }
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            // GameController's y axis points up, Windows' points down
            self?.forward(["type": "mouse_move",
                           "dx": Double(dx) * Self.pointerSpeed,
                           "dy": Double(-dy) * Self.pointerSpeed])
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.forward(["type": "mouse_button", "button": "left", "down": pressed])
        }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.forward(["type": "mouse_button", "button": "right", "down": pressed])
        }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.forward(["type": "mouse_button", "button": "middle", "down": pressed])
        }
        input.scroll.valueChangedHandler = { [weak self] _, x, y in
            guard x != 0 || y != 0 else { return }
            self?.forward(["type": "scroll",
                           "dx": Double(x) * Self.scrollSpeed,
                           "dy": Double(y) * Self.scrollSpeed])
        }
    }

    private func attach(_ keyboard: GCKeyboard) {
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            // GCKeyCode is the key's HID usage number; the laptop maps it to a scan code
            self?.forward(["type": "key", "usage": keyCode.rawValue, "down": pressed])
        }
    }

    private func forward(_ message: [String: Any]) {
        guard active else { return }
        send?(message)
    }
}
