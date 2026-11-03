import Foundation

/// Wire format, both directions: [u8 type][u32 big-endian length][payload].
/// See pc/hub.py for the list of JSON messages.
enum MessageType: UInt8 {
    case video = 1  // H.264, laptop -> iPad
    case json = 2   // both ways
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

/// Any JSON message from the laptop; which fields are set depends on `type`.
struct LaptopMessage: Decodable {
    let type: String
    let shortcuts: [Shortcut]?
    let nowPlaying: NowPlaying?
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
