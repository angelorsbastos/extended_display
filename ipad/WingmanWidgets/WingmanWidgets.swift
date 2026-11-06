import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Wingman's widgets and its timer Live Activity. They show what the app last
/// saved (WidgetSnapshot) and open the app to act: only the open app can reach
/// the laptop.
@main
struct WingmanWidgetBundle: WidgetBundle {
    var body: some Widget {
        LauncherWidget()
        ShortcutsWidget()
        TimerLiveActivity()
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

// MARK: - The launcher: straight into a part of Wingman

/// The laptop's name, when it was last seen, and buttons straight into
/// Extend, Mirror, the Dock, the trackpad and keys, and Files. Nothing here
/// goes stale: Wingman opens on that screen and connects.
struct LauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "launcher", provider: SnapshotProvider()) { entry in
            LauncherView(snapshot: entry.snapshot)
                .containerBackground(Look.background, for: .widget)
        }
        .configurationDisplayName("Wingman")
        .description("Open Extend, Mirror, the Dock, the trackpad or Files in one tap.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: WidgetSnapshot(laptopName: "Laptop", battery: 80, updated: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load() ?? placeholder(in: context).snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // the app asks for a reload whenever it saves something new
        completion(Timeline(entries: [SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load())], policy: .never))
    }
}

private struct Destination: Identifiable {
    let id: String
    let title: String
    let icon: String
    var accent = false
    var url: URL { URL(string: "wingman://open/\(id)")! }

    static let all = [
        Destination(id: "extend", title: "Extend", icon: "rectangle.on.rectangle.angled", accent: true),
        Destination(id: "mirror", title: "Mirror", icon: "rectangle.on.rectangle"),
        Destination(id: "dock", title: "Dock", icon: "clock"),
        Destination(id: "trackpad", title: "Trackpad", icon: "keyboard"),
        Destination(id: "files", title: "Files", icon: "folder"),
    ]
}

struct LauncherView: View {
    let snapshot: WidgetSnapshot?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(snapshot?.laptopName ?? "Wingman", systemImage: "laptopcomputer").font(.headline).lineLimit(1)
                if let snapshot, let battery = snapshot.battery, snapshot.updated > .distantPast {
                    // the last known battery, with when it was: honest about being old
                    Text("\(battery)% at \(snapshot.updated, style: .time)")
                }
                Text("Tap to open").foregroundStyle(.secondary)
            }
            .widgetURL(WingmanLink.dock)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "laptopcomputer").font(.title3)
            }
            .widgetURL(Destination.all[0].url)
        case .systemSmall:
            VStack(alignment: .leading, spacing: 8) {
                header
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { button(Destination.all[0], compact: true); button(Destination.all[1], compact: true) }
                    GridRow { button(Destination.all[2], compact: true); button(Destination.all[3], compact: true) }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                header
                HStack(spacing: 8) {
                    ForEach(Destination.all) { button($0, compact: false) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer").font(.system(size: 13, weight: .semibold))
            Text(snapshot?.laptopName ?? "Wingman").font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if let snapshot, snapshot.updated > .distantPast {
                Text(snapshot.updated, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(Look.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
        }
        .foregroundStyle(Look.text)
    }

    private func button(_ destination: Destination, compact: Bool) -> some View {
        Link(destination: destination.url) {
            VStack(spacing: 5) {
                Image(systemName: destination.icon)
                    .font(.system(size: compact ? 20 : 22, weight: .semibold))
                if !compact {
                    Text(destination.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(destination.accent ? Color.white : Look.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(destination.accent ? Look.accent : Look.tile))
        }
        .accessibilityLabel(destination.title)
    }
}

// MARK: - Shortcuts: pick them, one tap runs them

/// A shortcut as the widget's settings offer it (Edit Widget > Shortcuts).
struct ShortcutEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Shortcut"
    static var defaultQuery = ShortcutQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct ShortcutQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ShortcutEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ShortcutEntity] {
        all()
    }

    private func all() -> [ShortcutEntity] {
        (WidgetSnapshot.load()?.shortcuts ?? []).map { ShortcutEntity(id: $0.id, title: $0.title) }
    }
}

struct ChooseShortcuts: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose shortcuts"
    static var description = IntentDescription("Pick the shortcuts this widget shows. Empty: your first ones.")

    @Parameter(title: "Shortcuts", size: [.systemSmall: 4, .systemMedium: 4, .systemLarge: 8])
    var shortcuts: [ShortcutEntity]?
}

struct ShortcutsEntry: TimelineEntry {
    let date: Date
    let items: [WidgetSnapshot.Item]
}

struct ShortcutsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ShortcutsEntry {
        ShortcutsEntry(date: .now, items: [])
    }

    func snapshot(for configuration: ChooseShortcuts, in context: Context) async -> ShortcutsEntry {
        ShortcutsEntry(date: .now, items: items(configuration, family: context.family))
    }

    func timeline(for configuration: ChooseShortcuts, in context: Context) async -> Timeline<ShortcutsEntry> {
        Timeline(entries: [ShortcutsEntry(date: .now, items: items(configuration, family: context.family))],
                 policy: .never)
    }

    /// The chosen shortcuts in the chosen order, or the first ones if none were chosen.
    private func items(_ configuration: ChooseShortcuts, family: WidgetFamily) -> [WidgetSnapshot.Item] {
        let all = WidgetSnapshot.load()?.shortcuts ?? []
        let count = family == .systemLarge ? 8 : 4
        let chosen = (configuration.shortcuts ?? []).compactMap { pick in all.first { $0.id == pick.id } }
        return Array((chosen.isEmpty ? all : chosen).prefix(count))
    }
}

struct ShortcutsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "shortcuts", intent: ChooseShortcuts.self, provider: ShortcutsProvider()) { entry in
            ShortcutsView(items: entry.items)
                .containerBackground(Look.background, for: .widget)
        }
        .configurationDisplayName("Shortcuts")
        .description("Your Wingman shortcuts. Edit the widget to choose them; a tap runs one on the laptop.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ShortcutsView: View {
    let items: [WidgetSnapshot.Item]
    @Environment(\.widgetFamily) private var family

    /// Small: 2 x 2. Medium: one row of 4. Large: 2 rows of 4, big tiles.
    private var columns: Int { family == .systemSmall ? 2 : 4 }

    var body: some View {
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2").font(.title2)
                Text("Open Wingman once").font(.caption)
            }
            .foregroundStyle(Look.secondary)
        } else {
            let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
            VStack(spacing: 8) {
                ForEach(rows.indices, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(rows[row]) { tile($0) }
                        // keep tile sizes even when a row isn't full
                        ForEach(0..<(columns - rows[row].count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ item: WidgetSnapshot.Item) -> some View {
        let small = family == .systemSmall
        return Link(destination: WingmanLink.shortcut(item.id)) {
            VStack(spacing: small ? 0 : 6) {
                icon(item)
                    .frame(width: iconSize, height: iconSize)
                if !small {
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Look.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Look.tile))
        }
        .accessibilityLabel(item.title)
    }

    private var iconSize: CGFloat {
        switch family {
        case .systemLarge: return 44
        case .systemMedium: return 36
        default: return 40
        }
    }

    @ViewBuilder private func icon(_ item: WidgetSnapshot.Item) -> some View {
        if let base64 = item.image, let data = Data(base64Encoded: base64), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: item.symbol)
                .resizable()
                .scaledToFit()
                .padding(iconSize * 0.12)
                .foregroundStyle(Look.text)
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
