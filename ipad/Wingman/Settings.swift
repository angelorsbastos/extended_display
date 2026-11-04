import SwiftUI
import UIKit

/// The user's preferences, kept on this device (UserDefaults). Read where they
/// matter; the Settings screen changes them.
enum Prefs {
    // connection
    static let connection = "connection.mode"            // "auto", "cable", "wireless"
    static let allowRemote = "connection.remote"         // Tailscale, away from home
    // screen (sent to the laptop: prefs)
    static let extendScale = "screen.extendScale"        // 175 / 200 / 225
    static let quality = "screen.quality"                // smooth / balanced / sharp
    // sound: the keys AppModel already uses
    static let soundHome = "soundOnIPad.home"
    static let soundRemote = "soundOnIPad.remote"
    // iPhone trackpad
    static let pointerSpeed = "trackpad.pointerSpeed"
    static let scrollSpeed = "trackpad.scrollSpeed"
    static let naturalScroll = "trackpad.naturalScroll"
    // dock
    static let nightStart = "dock.nightStart"
    static let nightEnd = "dock.nightEnd"
    static let dockFade = "dock.fadeSeconds"
    // general
    static let haptics = "general.haptics"
    static let quickButton = "general.quickButton"

    private static func value<T>(_ key: String, _ fallback: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? fallback
    }

    static var connectionMode: String { value(connection, "auto") }
    static var remoteAllowed: Bool { value(allowRemote, true) }
    static var extendScaleValue: Int { value(extendScale, 200) }
    static var qualityValue: String { value(quality, "balanced") }
    static var pointerSpeedValue: Double { value(pointerSpeed, 2.2) }
    static var scrollSpeedValue: Double { value(scrollSpeed, 1.0) }
    static var naturalScrollValue: Bool { value(naturalScroll, true) }
    static var nightStartHour: Int { value(nightStart, 22) }
    static var nightEndHour: Int { value(nightEnd, 7) }
    static var dockFadeSeconds: Double { value(dockFade, 6.0) }
    static var hapticsOn: Bool { value(haptics, true) }

    /// May the laptop connect this way, by the user's connection setting?
    static func allows(_ transport: Transport) -> Bool {
        switch transport {
        case .usb: return connectionMode != "wireless"
        case .wifi: return connectionMode != "cable"
        case .remote: return connectionMode != "cable" && remoteAllowed
        }
    }
}

/// A light tap felt in the hand, unless haptics are switched off in Settings.
func haptic() {
    guard Prefs.hapticsOn else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
}

/// Settings: how to connect, the Extend screen, sound, the iPhone's trackpad,
/// the Dock, and general preferences.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    @AppStorage(Prefs.connection) private var connection = "auto"
    @AppStorage(Prefs.allowRemote) private var allowRemote = true
    @AppStorage(Prefs.extendScale) private var extendScale = 200
    @AppStorage(Prefs.quality) private var quality = "balanced"
    @AppStorage(Prefs.soundHome) private var soundHome = false
    @AppStorage(Prefs.soundRemote) private var soundRemote = true
    @AppStorage(Prefs.pointerSpeed) private var pointerSpeed = 2.2
    @AppStorage(Prefs.scrollSpeed) private var scrollSpeed = 1.0
    @AppStorage(Prefs.naturalScroll) private var naturalScroll = true
    @AppStorage(Prefs.nightStart) private var nightStart = 22
    @AppStorage(Prefs.nightEnd) private var nightEnd = 7
    @AppStorage(Prefs.dockFade) private var dockFade = 6.0
    @AppStorage(Prefs.haptics) private var haptics = true
    @AppStorage(Prefs.quickButton) private var quickButton = true
    @State private var showingDetails = false

    var body: some View {
        VStack(spacing: isPhone ? 12 : 20) {
            TopBar(title: "Settings", model: model)
            Form {
                Section {
                    Picker("Connect by", selection: $connection) {
                        Text("Automatic").tag("auto")
                        Text("Cable only").tag("cable")
                        Text("Wireless only").tag("wireless")
                    }
                    Toggle("Connect from afar (Tailscale)", isOn: $allowRemote)
                        .disabled(connection == "cable")
                    Button("Connection details") { showingDetails = true }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Automatic uses the cable when it's plugged in, then Wi-Fi, then Tailscale.")
                }

                if !isPhone {
                    Section {
                        Picker("Text size on Extend", selection: $extendScale) {
                            Text("More space").tag(175)
                            Text("Default").tag(200)
                            Text("Larger").tag(225)
                        }
                        Picker("Picture quality", selection: $quality) {
                            Text("Smooth").tag("smooth")
                            Text("Balanced").tag("balanced")
                            Text("Sharp").tag("sharp")
                        }
                        Toggle("Quick button over Extend and Mirror", isOn: $quickButton)
                    } header: {
                        Text("Screen")
                    } footer: {
                        Text("Changes apply the next time you start Extend or Mirror. Sharp uses more of the "
                             + "connection; Smooth stutters less on slow Wi-Fi.")
                    }
                }

                Section("Sound") {
                    Toggle("Play the laptop's sound here at home", isOn: $soundHome)
                    Toggle("Play the laptop's sound here when away", isOn: $soundRemote)
                }

                if isPhone {
                    Section("Trackpad") {
                        LabeledSlider(title: "Pointer speed", value: $pointerSpeed, range: 0.8...5)
                        LabeledSlider(title: "Scrolling speed", value: $scrollSpeed, range: 0.3...3)
                        Toggle("Natural scrolling", isOn: $naturalScroll)
                    }
                }

                Section {
                    Picker("Night starts", selection: $nightStart) {
                        ForEach(18..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }
                    Picker("Night ends", selection: $nightEnd) {
                        ForEach(4..<11) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }
                    Picker("Controls stay for", selection: $dockFade) {
                        Text("3 seconds").tag(3.0)
                        Text("6 seconds").tag(6.0)
                        Text("10 seconds").tag(10.0)
                    }
                } header: {
                    Text("Dock")
                } footer: {
                    Text("At night the Dock turns dim red.")
                }

                Section("General") {
                    Toggle("Haptics", isOn: $haptics)
                }

                Section("About") {
                    LabeledContent("Wingman", value: Bundle.main.object(forInfoDictionaryKey:
                        "CFBundleShortVersionString") as? String ?? "")
                    LabeledContent("Laptop", value: model.laptopName ?? "Not connected")
                }
            }
            .scrollContentBackground(.hidden)
            .tint(Theme.accent)
        }
        .screenPadding()
        .foregroundStyle(Theme.text)
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ScrollView { ConnectionPanel(model: model).padding() }
                    .navigationTitle("Connection details")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDetails = false } }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .onChange(of: connection) { _ in model.applyConnectionPrefs() }
        .onChange(of: allowRemote) { _ in model.applyConnectionPrefs() }
        .onChange(of: extendScale) { _ in model.sendPrefs() }
        .onChange(of: quality) { _ in model.sendPrefs() }
        .onChange(of: soundHome) { _ in model.applySoundPrefs() }
        .onChange(of: soundRemote) { _ in model.applySoundPrefs() }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            Slider(value: $value, in: range)
        }
    }
}
