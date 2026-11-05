import SwiftUI
import UIKit

/// The user's preferences, kept on this device (UserDefaults). Read where they
/// matter; the Settings screen changes them.
enum Prefs {
    // connection: per way, "auto" (connect by itself), "ask" (wait for a tap on
    // Connect) or "off"
    static func connectKey(_ transport: Transport) -> String { "connect.\(transport.rawValue)" }
    // the settings before that (still read once, to carry them over)
    private static let oldMode = "connection.mode"       // "auto", "cable", "wireless"
    private static let oldRemote = "connection.remote"   // Tailscale on/off
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

    /// How this way of connecting behaves: "auto", "ask" or "off". New: "ask"
    /// (nothing connects until you tap Connect); a way the old settings had
    /// switched off stays off.
    static func connectMode(_ transport: Transport) -> String {
        if let mode = UserDefaults.standard.string(forKey: connectKey(transport)) { return mode }
        let old = UserDefaults.standard.string(forKey: oldMode) ?? "auto"
        let oldRemoteOn = UserDefaults.standard.object(forKey: oldRemote) as? Bool ?? true
        switch transport {
        case .usb: return old == "wireless" ? "off" : "ask"
        case .wifi: return old == "cable" ? "off" : "ask"
        case .remote: return old == "cable" || !oldRemoteOn ? "off" : "ask"
        }
    }
    static var extendScaleValue: Int { value(extendScale, 200) }
    static var qualityValue: String { value(quality, "balanced") }
    static var pointerSpeedValue: Double { value(pointerSpeed, 2.2) }
    static var scrollSpeedValue: Double { value(scrollSpeed, 1.0) }
    static var naturalScrollValue: Bool { value(naturalScroll, true) }
    static var nightStartHour: Int { value(nightStart, 22) }
    static var nightEndHour: Int { value(nightEnd, 7) }
    static var dockFadeSeconds: Double { value(dockFade, 6.0) }
    static var hapticsOn: Bool { value(haptics, true) }

    /// May the laptop connect this way at all (automatically or on a tap)?
    static func allows(_ transport: Transport) -> Bool {
        connectMode(transport) != "off"
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

    @AppStorage(Prefs.connectKey(.usb)) private var cableMode = Prefs.connectMode(.usb)
    @AppStorage(Prefs.connectKey(.wifi)) private var wifiMode = Prefs.connectMode(.wifi)
    @AppStorage(Prefs.connectKey(.remote)) private var remoteMode = Prefs.connectMode(.remote)
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
                    modePicker("Cable", icon: "cable.connector", selection: $cableMode)
                    modePicker("Wi-Fi", icon: "wifi", selection: $wifiMode)
                    modePicker("Tailscale (away)", icon: "globe", selection: $remoteMode)
                    Button("Connection details") { showingDetails = true }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Automatic connects by itself. Ask waits until you tap Connect on the home "
                         + "screen. With several ways available, the cable wins, then Wi-Fi, then Tailscale.")
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

                Section("Trackpad") {
                    LabeledSlider(title: "Pointer speed", value: $pointerSpeed, range: 0.8...5)
                    LabeledSlider(title: "Scrolling speed", value: $scrollSpeed, range: 0.3...3)
                    Toggle("Natural scrolling", isOn: $naturalScroll)
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
                    Text("At night the Dock turns dim red, whatever its style.")
                }

                DockStylesSection(model: model)

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
        .onChange(of: cableMode) { _ in model.applyConnectionPrefs() }
        .onChange(of: wifiMode) { _ in model.applyConnectionPrefs() }
        .onChange(of: remoteMode) { _ in model.applyConnectionPrefs() }
        .onChange(of: extendScale) { _ in model.sendPrefs() }
        .onChange(of: quality) { _ in model.sendPrefs() }
        .onChange(of: soundHome) { _ in model.applySoundPrefs() }
        .onChange(of: soundRemote) { _ in model.applySoundPrefs() }
    }
}

private func modePicker(_ title: String, icon: String, selection: Binding<String>) -> some View {
    Picker(selection: selection) {
        Text("Automatic").tag("auto")
        Text("Ask").tag("ask")
        Text("Off").tag("off")
    } label: {
        Label(title, systemImage: icon)
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
