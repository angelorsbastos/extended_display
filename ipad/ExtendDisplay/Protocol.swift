import Foundation

/// Wire format, both directions: [u8 type][u32 big-endian length][payload].
/// See pc/hub.py for the list of JSON messages.
enum MessageType: UInt8 {
    case video = 1   // H.264, laptop -> iPad
    case json = 2    // both ways
    case sealed = 3  // a video or json message encrypted by Cipher (all of Wi-Fi)
}

enum Transport: String {
    case usb, wifi
    case remote  // Wi-Fi port, but arriving through Tailscale (away from home)
}

struct Shortcut: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String  // SF Symbol name
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
}

/// Any JSON message from the laptop; which fields are set depends on `type`.
struct LaptopMessage: Decodable {
    let type: String
    let shortcuts: [Shortcut]?
    let nowPlaying: NowPlaying?
    let controls: ControlsState?
    let width: Int?
    let height: Int?
    let message: String?
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
