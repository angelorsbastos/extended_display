import ActivityKit
import Foundation

/// What the widgets show: the latest state the app saw (laptop battery and
/// temperature, the song, the shortcuts), saved by the app in the shared app
/// group. Widgets can't reach the laptop themselves, so this is as fresh as
/// the last time Wingman was open; `updated` says when that was.
struct WidgetSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let symbol: String
        let image: String?  // the app's own icon, base64 PNG, when it has one
    }

    var laptopName: String?
    var connected = false
    var battery: Int?
    var charging = false
    var cpuTemp: Int?
    var songTitle: String?
    var songArtist: String?
    var playing = false
    var shortcuts: [Item] = []
    var updated = Date.distantPast

    private static let key = "widget.snapshot"

    /// The app group shared by the app and its extensions. SideStore (like
    /// AltStore) gives it a name of its own for each Apple ID and writes that
    /// name into the Info.plist as ALTAppGroups.
    static var appGroup: String {
        (Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String])?.first
            ?? "group.dev.extenddisplay.app"
    }

    static var shared: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> WidgetSnapshot? {
        guard let data = shared?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            Self.shared?.set(data, forKey: Self.key)
        }
    }

    /// The same, apart from when it was taken.
    func sameContent(as other: WidgetSnapshot?) -> Bool {
        guard var other else { return false }
        other.updated = updated
        return other == self
    }
}

/// Links from widgets and Control Center into the app (wingman://...). The
/// app opens, connects if it needs to, and does it.
enum WingmanLink {
    static func shortcut(_ id: String) -> URL {
        URL(string: "wingman://shortcut/\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)")!
    }
    static let lock = URL(string: "wingman://lock")!
    static let playPause = URL(string: "wingman://playpause")!
    static let dock = URL(string: "wingman://dock")!
}

/// The Dock timer as a Live Activity (Lock Screen, Dynamic Island). The
/// countdown is drawn by iOS from `end`, so it keeps going with the app closed.
@available(iOS 16.1, *)
struct TimerActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var end: Date?                 // running: it ends then
        var pausedRemaining: Double?   // paused: this much left
        var total: Double              // the timer's full length, for the progress bar
        var finished = false
    }
}
