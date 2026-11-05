import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Wingman's widgets, its timer Live Activity and its Control Center buttons.
/// They show what the app last saw (WidgetSnapshot) and open the app to act:
/// only the open app can reach the laptop.
@main
struct WingmanWidgetBundle: WidgetBundle {
    var body: some Widget {
        LaptopWidget()
        ShortcutsWidget()
        TimerLiveActivity()
        LockLaptopControl()
        PlayPauseControl()
    }
}

// MARK: - Colours (Theme.swift's, which the extension doesn't include)

private enum Look {
    static let background = Color(red: 16 / 255, green: 17 / 255, blue: 20 / 255)
    static let tile = Color(red: 30 / 255, green: 32 / 255, blue: 37 / 255)
    static let text = Color(red: 242 / 255, green: 243 / 255, blue: 245 / 255)
    static let secondary = Color(red: 154 / 255, green: 157 / 255, blue: 166 / 255)
    static let accent = Color(red: 47 / 255, green: 107 / 255, blue: 255 / 255)
    static let warm = Color(red: 255 / 255, green: 179 / 255, blue: 92 / 255)
}

// MARK: - The timeline: whatever the app saved last

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: WidgetSnapshot(laptopName: "Laptop", battery: 80, cpuTemp: 55,
                                                           songTitle: "Song", songArtist: "Artist"))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load() ?? placeholder(in: context).snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // the app asks for a reload whenever it saves something new
        completion(Timeline(entries: [SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load())], policy: .never))
    }
}

// MARK: - Laptop: battery, temperature, song

struct LaptopWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "laptop", provider: SnapshotProvider()) { entry in
            LaptopWidgetView(snapshot: entry.snapshot)
                .containerBackground(Look.background, for: .widget)
                .widgetURL(WingmanLink.dock)
        }
        .configurationDisplayName("Laptop")
        .description("Battery, temperature and what's playing, as of the last time Wingman was open.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct LaptopWidgetView: View {
    let snapshot: WidgetSnapshot?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot {
            switch family {
            case .accessoryCircular:
                Gauge(value: Double(snapshot.battery ?? 0), in: 0...100) {
                    Image(systemName: "laptopcomputer")
                } currentValueLabel: {
                    Text(snapshot.battery.map { "\($0)" } ?? "–")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.laptopName ?? "Laptop").font(.headline).lineLimit(1)
                    Text(batteryText(snapshot) + (snapshot.cpuTemp.map { " · \($0)°" } ?? ""))
                    if let song = snapshot.songTitle { Text(song).lineLimit(1) }
                }
            default:
                full(snapshot)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "laptopcomputer").font(.title2)
                Text("Open Wingman once").font(.caption)
            }
            .foregroundStyle(Look.secondary)
        }
    }

    private func full(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(snapshot.connected ? Color.green : Look.secondary).frame(width: 7, height: 7)
                Text(snapshot.laptopName ?? "Laptop").font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(Look.text)
            HStack(spacing: 14) {
                Label(batteryText(snapshot), systemImage: snapshot.charging ? "battery.100.bolt" : "battery.75")
                if let temp = snapshot.cpuTemp {
                    Label("\(temp)°", systemImage: "thermometer.medium")
                        .foregroundStyle(temp >= 85 ? Look.warm : Look.text)
                }
            }
            .font(.system(size: family == .systemSmall ? 15 : 17, weight: .semibold))
            .foregroundStyle(Look.text)
            Spacer(minLength: 0)
            if let song = snapshot.songTitle {
                VStack(alignment: .leading, spacing: 1) {
                    Label(song, systemImage: snapshot.playing ? "music.note" : "pause.fill")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let artist = snapshot.songArtist, !artist.isEmpty {
                        Text(artist).font(.system(size: 12)).foregroundStyle(Look.secondary).lineLimit(1)
                    }
                }
                .foregroundStyle(Look.text)
            }
            Text(snapshot.updated, style: .relative)
                .font(.system(size: 11))
                .foregroundStyle(Look.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func batteryText(_ snapshot: WidgetSnapshot) -> String {
        snapshot.battery.map { "\($0)%" } ?? "–"
    }
}

// MARK: - Shortcuts: one tap opens Wingman and runs it

struct ShortcutsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "shortcuts", provider: SnapshotProvider()) { entry in
            ShortcutsWidgetView(snapshot: entry.snapshot)
                .containerBackground(Look.background, for: .widget)
        }
        .configurationDisplayName("Shortcuts")
        .description("Your Wingman shortcuts. A tap opens Wingman and runs it on the laptop.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ShortcutsWidgetView: View {
    let snapshot: WidgetSnapshot?
    @Environment(\.widgetFamily) private var family

    private var columns: Int { family == .systemSmall ? 2 : 4 }
    private var count: Int { family == .systemSmall ? 4 : family == .systemMedium ? 4 : 8 }

    var body: some View {
        let items = Array((snapshot?.shortcuts ?? []).prefix(count))
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2").font(.title2)
                Text("Open Wingman once").font(.caption)
            }
            .foregroundStyle(Look.secondary)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(items) { item in
                    Link(destination: WingmanLink.shortcut(item.id)) {
                        VStack(spacing: 4) {
                            icon(item)
                                .frame(width: 26, height: 26)
                            if family != .systemSmall {
                                Text(item.title).font(.system(size: 10)).foregroundStyle(Look.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: family == .systemSmall ? 52 : 58)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Look.tile))
                    }
                }
            }
        }
    }

    @ViewBuilder private func icon(_ item: WidgetSnapshot.Item) -> some View {
        if let base64 = item.image, let data = Data(base64Encoded: base64), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: item.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(Look.text)
        }
    }
}

// MARK: - The Dock timer, on the Lock Screen and in the Dynamic Island

struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivity.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.state.finished ? "bell.fill" : "timer")
                    .font(.title2)
                    .foregroundStyle(context.state.finished ? Look.warm : Look.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wingman timer").font(.caption).foregroundStyle(Look.secondary)
                    countdown(context.state).font(.system(size: 30, weight: .light)).monospacedDigit()
                }
                Spacer(minLength: 0)
                if let end = context.state.end {
                    ProgressView(timerInterval: end.addingTimeInterval(-context.state.total)...end, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.circular)
                    .tint(Look.accent)
                    .frame(width: 34)
                }
            }
            .padding(16)
            .activityBackgroundTint(Look.background)
            .foregroundStyle(Look.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Timer", systemImage: "timer").foregroundStyle(Look.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context.state).monospacedDigit().font(.title3)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let end = context.state.end {
                        ProgressView(timerInterval: end.addingTimeInterval(-context.state.total)...end,
                                     countsDown: true) {
                            EmptyView()
                        } currentValueLabel: {
                            EmptyView()
                        }
                        .tint(Look.accent)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.finished ? "bell.fill" : "timer")
                    .foregroundStyle(context.state.finished ? Look.warm : Look.accent)
            } compactTrailing: {
                countdown(context.state).monospacedDigit().frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(Look.accent)
            }
            .widgetURL(WingmanLink.dock)
        }
    }

    @ViewBuilder private func countdown(_ state: TimerActivity.ContentState) -> some View {
        if state.finished {
            Text("Time's up")
        } else if let end = state.end {
            Text(timerInterval: Date.now...max(end, Date.now), countsDown: true)
        } else if let left = state.pausedRemaining {
            Text(Self.format(left) + " ⏸")
        } else {
            Text("–")
        }
    }

    private static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Control Center buttons

struct LockLaptopControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.extenddisplay.app.lock") {
            ControlWidgetButton(action: OpenURLIntent(WingmanLink.lock)) {
                Label("Lock laptop", systemImage: "lock.laptopcomputer")
            }
        }
        .displayName("Lock laptop")
        .description("Opens Wingman and locks the laptop.")
    }
}

struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.extenddisplay.app.playpause") {
            ControlWidgetButton(action: OpenURLIntent(WingmanLink.playPause)) {
                Label("Laptop play/pause", systemImage: "playpause.fill")
            }
        }
        .displayName("Laptop play/pause")
        .description("Opens Wingman and plays or pauses the laptop's music.")
    }
}
