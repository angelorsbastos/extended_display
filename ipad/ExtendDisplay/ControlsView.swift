import SwiftUI

/// Controls for the laptop: music, sound, screen, wireless & power, power buttons.
/// Values come from the laptop every 2 s while this screen is open.
struct ControlsView: View {
    @ObservedObject var model: AppModel
    @State private var confirming: PowerAction?

    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 20, alignment: .top)]

    var body: some View {
        VStack(spacing: 24) {
            TopBar(title: "Controls", model: model)

            if let error = model.videoError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color.red)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    musicCard
                    soundCard
                    screenCard
                    wirelessCard
                    powerCard
                }
                .disabled(!model.connected)
                .opacity(model.connected ? 1 : 0.4)
            }
        }
        .screenPadding()
        .foregroundStyle(.white)
        .confirmationDialog(confirming?.question ?? "", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { action in
            Button(action.title, role: .destructive) { model.control(action.rawValue) }
        }
    }

    // MARK: cards

    private var musicCard: some View {
        Card(title: "Music", icon: "music.note", tint: .green) {
            let np = model.nowPlaying
            VStack(alignment: .leading, spacing: 4) {
                Text(np?.title.isEmpty == false ? np!.title : "Nothing playing")
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(np.map { [$0.artist, $0.app].filter { !$0.isEmpty }.joined(separator: " · ") }
                     ?? "Start music or a video on the laptop")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 28) {
                MediaButton(icon: "backward.fill", size: 26) { model.media("previous") }
                MediaButton(icon: np?.playing == true ? "pause.fill" : "play.fill",
                            size: 34, prominent: true) { model.media("play_pause") }
                MediaButton(icon: "forward.fill", size: 26) { model.media("next") }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var soundCard: some View {
        Card(title: "Sound", icon: "speaker.wave.2.fill", tint: .blue) {
            LevelSlider(icon: "speaker.wave.2.fill", value: model.controls?.volume) {
                model.controls?.volume = $0
                model.control("volume", $0)
            }
            HStack(spacing: 12) {
                ToggleButton(title: "Mute", icon: "speaker.slash.fill",
                             isOn: toggle(\.muted, "muted"))
                ToggleButton(title: "Mic off", icon: "mic.slash.fill",
                             isOn: toggle(\.micMuted, "mic_muted"))
            }
            ToggleButton(title: "Play on iPad", icon: "ipad.landscape",
                         isOn: Binding(get: { model.soundOnIPad }, set: { model.setSoundOnIPad($0) }))
            if model.soundOnIPad {
                Text("The laptop plays it too. Turn the laptop down rather than muting it: muted, the iPad hears nothing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var screenCard: some View {
        Card(title: "Laptop screen", icon: "sun.max.fill", tint: .yellow) {
            LevelSlider(icon: "sun.max.fill", value: model.controls?.brightness) {
                model.controls?.brightness = $0
                model.control("brightness", $0)
            }
            Toggle(isOn: toggle(\.darkMode, "dark_mode")) {
                Label("Dark mode", systemImage: "moon.fill")
            }
            .disabled(model.controls?.darkMode == nil)
        }
    }

    private var wirelessCard: some View {
        Card(title: "Wireless & power", icon: "bolt.fill", tint: .orange) {
            Toggle(isOn: toggle(\.wifi, "wifi")) { Label("Wi-Fi", systemImage: "wifi") }
                .disabled(model.controls?.wifi == nil)
            Toggle(isOn: toggle(\.bluetooth, "bluetooth")) {
                Label("Bluetooth", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(model.controls?.bluetooth == nil)
            Toggle(isOn: toggle(\.keepAwake, "keep_awake")) {
                Label("Keep awake", systemImage: "cup.and.saucer.fill")
            }
            if let plans = model.controls?.powerPlans, !plans.isEmpty {
                Picker("Power plan", selection: Binding(
                    get: { model.controls?.powerPlan ?? "" },
                    set: { model.controls?.powerPlan = $0; model.control("power_plan", $0) })) {
                    ForEach(plans) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
            }
            if let battery = model.controls?.battery, let percent = battery.percent {
                Label("\(percent)%\(battery.charging ? ", plugged in" : "")",
                      systemImage: battery.charging ? "battery.100.bolt" : "battery.75")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var powerCard: some View {
        Card(title: "Power", icon: "power", tint: .red) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(PowerAction.allCases) { action in
                    Button {
                        if action == .lock {
                            model.control(action.rawValue)
                        } else {
                            confirming = action
                        }
                    } label: {
                        Label(action.title, systemImage: action.icon)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    /// A switch bound to one setting: flips right away here, then tells the laptop.
    private func toggle(_ field: WritableKeyPath<ControlsState, Bool?>, _ name: String) -> Binding<Bool> {
        Binding(get: { model.controls?[keyPath: field] ?? false },
                set: { model.controls?[keyPath: field] = $0; model.control(name, $0) })
    }
}

enum PowerAction: String, CaseIterable, Identifiable {
    case lock, sleep, restart, shutdown

    var id: String { rawValue }
    var title: String {
        switch self {
        case .lock: return "Lock"
        case .sleep: return "Sleep"
        case .restart: return "Restart"
        case .shutdown: return "Shut down"
        }
    }
    var icon: String {
        switch self {
        case .lock: return "lock.fill"
        case .sleep: return "moon.zzz.fill"
        case .restart: return "arrow.clockwise"
        case .shutdown: return "power"
        }
    }
    var question: String { "\(title) the laptop?" }
}

/// A rounded panel with a coloured title, holding a group of controls.
struct Card<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let content: Content

    init(title: String, icon: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(0.08)))
    }
}

/// 0-100 slider. While dragging it ignores the laptop's updates (so it doesn't
/// jump under the finger) and sends at most ~10 changes a second.
struct LevelSlider: View {
    let icon: String
    let value: Int?
    let onChange: (Int) -> Void

    @State private var level = 0.0
    @State private var dragging = false
    @State private var lastSent = Date.distantPast

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: 24)
            Slider(value: $level, in: 0...100) { editing in
                dragging = editing
                if !editing {
                    onChange(Int(level))
                }
            }
            Text(value == nil ? "–" : "\(Int(level))%")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .disabled(value == nil)
        .onAppear { level = Double(value ?? 0) }
        .onChange(of: value) { newValue in
            if !dragging, let newValue {
                level = Double(newValue)
            }
        }
        .onChange(of: level) { newLevel in
            guard dragging, Date().timeIntervalSince(lastSent) > 0.1 else { return }
            lastSent = Date()
            onChange(Int(newLevel))
        }
    }
}

/// A button that stays highlighted while its setting is on (mute, mic off).
struct ToggleButton: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(isOn ? Color.black : Color.white)
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(isOn ? Color.blue : Color.white.opacity(0.1)))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Round icon button for play / pause / skip.
struct MediaButton: View {
    let icon: String
    let size: CGFloat
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .frame(width: size * 2.2, height: size * 2.2)
                .background(Circle().fill(prominent ? Color.green : Color.white.opacity(0.1)))
        }
        .buttonStyle(PressableStyle())
    }
}
