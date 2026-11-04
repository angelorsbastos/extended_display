import Foundation

/// Wire format, both directions: [u8 type][u32 big-endian length][payload].
/// See pc/hub.py for the list of JSON messages.
enum MessageType: UInt8 {
    case video = 1   // H.264, laptop -> iPad
    case json = 2    // both ways
    case sealed = 3  // a video, json or audio message encrypted by Cipher (all of Wi-Fi)
    case audio = 4   // one AAC packet, laptop -> iPad (after audio_started)
    case file = 5    // a piece of a file, both ways: [u32 id][bytes] (see FileTransfers)
}

enum Transport: String {
    case usb, wifi
    case remote  // Wi-Fi port, but arriving through Tailscale (away from home)
}

/// One shortcut button, as in pc/shortcuts.json: exactly one of keys / open / run / lock.
struct Shortcut: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var icon: String     // SF Symbol name
    var keys: [String]?  // a key combination, e.g. ["win", "shift", "s"] (names: pc/actions.py)
    var open: String?    // an app (shell:AppsFolder\...), file, folder or website
    var run: String?     // a command
    var lock: Bool?
    /// The app's own icon (base64 PNG, from the laptop); "" = show the symbol instead.
    var image: String?

    /// For the laptop (save_shortcuts / try_shortcut).
    var json: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

/// An app on the laptop's Start menu (list_apps).
struct LaptopApp: Decodable, Identifiable, Equatable {
    let name: String
    let open: String
    var id: String { open }
}

struct NowPlaying: Decodable, Equatable {
    let title: String
    let artist: String
    let app: String
    let playing: Bool
}

struct PowerPlan: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
}

struct Battery: Decodable, Equatable {
    let percent: Int?
    let charging: Bool
}

/// The laptop's settings for the Controls screen (pc/controls.py state()).
/// nil fields are ones the laptop couldn't read.
struct ControlsState: Decodable, Equatable {
    var volume: Int?
    var muted: Bool?
    var micMuted: Bool?
    var brightness: Int?
    var darkMode: Bool?
    var wifi: Bool?
    var bluetooth: Bool?
    var battery: Battery?
    var keepAwake: Bool?
    var powerPlans: [PowerPlan]?
    var powerPlan: String?
    var cpuTemp: Int?
}

/// The Dashboard's numbers (pc/stats.py read()). nil = the laptop couldn't read it.
struct LaptopStats: Decodable, Equatable {
    struct CPU: Decodable, Equatable {
        let temp: Double?    // °C
        let usage: Double?   // %
        let fan: Int?        // RPM
    }
    struct GPU: Decodable, Equatable {
        let name: String?
        let temp: Double?
        let usage: Double?
        let power: Double?   // W
        let clock: Double?   // MHz
        let memoryUsed: Double?   // MiB
        let memoryTotal: Double?
        let fan: Int?
    }
    struct Memory: Decodable, Equatable {
        let used: Double?    // GiB
        let total: Double?
    }
    struct BatteryInfo: Decodable, Equatable {
        let percent: Int?
        let pluggedIn: Bool?
        let health: Int?     // % of the capacity it had when new
        let designWh: Double?
        let fullWh: Double?
    }
    let cpu: CPU
    let gpu: GPU
    let memory: Memory
    let battery: BatteryInfo?
    let powerPlan: String?
}

/// Any JSON message from the laptop; which fields are set depends on `type`.
struct LaptopMessage: Decodable {
    let type: String
    let shortcuts: [Shortcut]?
    let laptopName: String?
    let laptopInput: Bool?
    let on: Bool?  // laptop_input
    let open: String?  // app_icon: which app (its png is in `png`)
    let apps: [LaptopApp]?
    let stats: LaptopStats?
    let nowPlaying: NowPlaying?
    let controls: ControlsState?
    let width: Int?
    let height: Int?
    let message: String?
    // file_start / file_end / file_saved / file_failed
    let id: Int?
    let name: String?
    let size: Int64?
    // audio_started
    let sampleRate: Int?
    let channels: Int?
    // clipboard: kind is "text" (with text) or "image" (with png, base64)
    let kind: String?
    let text: String?
    let png: String?

    static func decode(_ data: Data) -> LaptopMessage? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase  // now_playing -> nowPlaying
        return try? decoder.decode(LaptopMessage.self, from: data)
    }
}
