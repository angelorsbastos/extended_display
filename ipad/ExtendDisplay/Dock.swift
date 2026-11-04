import AudioToolbox
import Combine
import SwiftUI

/// The Dock: for an iPad or iPhone standing next to the laptop. At rest there
/// is only a huge clock, the song that's playing (nothing when nothing plays),
/// a running timer, and a slow glow in the song's colour, on true black. A tap
/// brings up the controls (music, timer, up to 6 chosen shortcuts), which fade
/// away again by themselves. Night mode turns it all dim red. The clock drifts a
/// few points every minute so it can't burn into the screen.
struct DockView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var timer: DockTimer
    @State private var showingControls = false
    @State private var hideControls: DispatchWorkItem?
    @State private var pickingShortcuts = false
    @AppStorage("dock.night") private var nightSetting = NightMode.auto.rawValue
    @AppStorage("dock.shortcuts") private var chosenIds = ""  // comma-separated; empty: the first six

    enum NightMode: String { case auto, on, off }

    static let controlsSeconds = 5.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            GeometryReader { geometry in
                let wide = geometry.size.width > geometry.size.height
                let night = isNight(context.date)
                ZStack {
                    Color.black
                    glow(night: night, size: geometry.size)
                    Group {
                        if wide {
                            HStack(alignment: .center, spacing: 40) {
                                clock(context.date, size: geometry.size, night: night)
                                Spacer(minLength: 0)
                                song(night: night).frame(maxWidth: geometry.size.width * 0.38)
                            }
                            .padding(.horizontal, isPhone ? 36 : 64)
                        } else {
                            VStack(alignment: .leading, spacing: 40) {
                                clock(context.date, size: geometry.size, night: night)
                                song(night: night)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 28)
                        }
                    }
                    .offset(drift(context.date))
                    .padding(.bottom, showingControls ? (wide ? 150 : 260) : 0)
                    .animation(.easeInOut(duration: 0.45), value: showingControls)

                    VStack {
                        Spacer()
                        if showingControls {
                            controls(night: night)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.35), value: showingControls)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: timer.finished) { finished in
            if finished { showControls() }
        }
        .sheet(isPresented: $pickingShortcuts) {
            DockShortcutPicker(all: model.shortcuts, chosen: chosenList) { ids in
                chosenIds = ids.joined(separator: ",")
            }
        }
    }

    // MARK: at rest

    private func clock(_ date: Date, size: CGSize, night: Bool) -> some View {
        let big = min(size.width, size.height) * (size.width > size.height ? 0.42 : 0.3)
        return VStack(alignment: .leading, spacing: 6) {
            Text(date, format: .dateTime.hour().minute())
                .font(.system(size: big, weight: .thin))
                .monospacedDigit()
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .foregroundStyle(night ? Self.nightRed : Theme.text)
            Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: isPhone ? 17 : 22))
                .foregroundStyle(night ? Self.nightDim : Theme.secondary)
                .padding(.leading, 6)
            if timer.isRunning || timer.finished {
                Label(timer.finished ? "Time's up" : timer.remainingText,
                      systemImage: timer.finished ? "bell.fill" : "timer")
                    .font(.system(size: isPhone ? 17 : 22, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(timer.finished ? Theme.warm : night ? Self.nightRed : Theme.text)
                    .padding(.leading, 6)
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder private func song(night: Bool) -> some View {
        if let playing = model.nowPlaying, !playing.title.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(playing.title)
                    .font(.system(size: isPhone ? 22 : 30, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(night ? Self.nightRed : Theme.text)
                Text(playing.artist.isEmpty ? playing.app : playing.artist)
                    .font(.system(size: isPhone ? 15 : 19))
                    .foregroundStyle(night ? Self.nightDim : Theme.secondary)
                    .lineLimit(1)
                EqualizerBars(playing: playing.playing, color: night ? Self.nightRed : Theme.text)
                    .padding(.top, 8)
            }
        }
    }

    /// A slow breathing light behind everything, in a colour of the song's own.
    private func glow(night: Bool, size: CGSize) -> some View {
        let colour = night ? Color(red: 0.6, green: 0.05, blue: 0.05) : songColour
        return BreathingGlow(colour: colour.opacity(night ? 0.18 : 0.32), diameter: max(size.width, size.height) * 0.9)
            .position(x: size.width * 0.22, y: size.height * 0.25)
            .animation(.easeInOut(duration: 1.5), value: model.nowPlaying?.title)
            .allowsHitTesting(false)
    }

    private var songColour: Color {
        guard let title = model.nowPlaying?.title, !title.isEmpty else {
            return Color(hue: 0.7, saturation: 0.5, brightness: 0.8)
        }
        // the same song gets the same colour every time (hashValue changes per launch)
        let hue = Double(title.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360
        return Color(hue: hue, saturation: 0.6, brightness: 0.9)
    }

    // MARK: controls

    private func controls(night: Bool) -> some View {
        VStack(spacing: 18) {
            if let playing = model.nowPlaying {  // nothing to control when nothing plays
                HStack(spacing: 34) {
                    roundButton("backward.fill", size: 54) { model.media("previous") }
                    roundButton(playing.playing ? "pause.fill" : "play.fill", size: 70, filled: true) {
                        model.media("play_pause")
                    }
                    roundButton("forward.fill", size: 54) { model.media("next") }
                }
            }
            timerRow
            HStack(spacing: 12) {
                ForEach(chosenShortcuts) { shortcut in
                    Button {
                        touch()
                        model.run(shortcut)
                    } label: {
                        Image(systemName: shortcut.icon)
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 52, height: 52)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.tile))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(shortcut.title)
                }
                Spacer(minLength: 0)
                smallButton(nightIcon) { cycleNight() }
                smallButton("slider.horizontal.3") { pickingShortcuts = true }
                smallButton("xmark") { model.goHome() }
            }
        }
        .foregroundStyle(night ? Self.nightRed : Theme.text)
        .padding(.horizontal, isPhone ? 20 : 48)
        .padding(.vertical, 22)
        .frame(maxWidth: 820)
        .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Color.white.opacity(0.06)))
        .padding(.horizontal, 16)
        .padding(.bottom, isPhone ? 20 : 36)
        .onTapGesture { touch() }  // taps inside keep it open, and don't close it
    }

    /// Below the music: start a timer (5 to 60 minutes), or see, pause and stop one.
    @ViewBuilder private var timerRow: some View {
        if timer.isRunning || timer.isPaused || timer.finished {
            HStack(spacing: 16) {
                Image(systemName: timer.finished ? "bell.fill" : "timer")
                    .foregroundStyle(timer.finished ? Theme.warm : Theme.secondary)
                Text(timer.finished ? "Time's up" : timer.remainingText)
                    .font(.system(size: 28, weight: .light))
                    .monospacedDigit()
                ProgressView(value: timer.progress)
                    .tint(Theme.on)
                    .frame(maxWidth: 220)
                Spacer(minLength: 0)
                if !timer.finished {
                    smallButton(timer.isPaused ? "play.fill" : "pause.fill") { timer.togglePause() }
                }
                smallButton("stop.fill") { timer.stop() }
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "timer").foregroundStyle(Theme.secondary)
                ForEach([5, 15, 25, 45, 60], id: \.self) { minutes in
                    Button {
                        touch()
                        timer.start(minutes: minutes)
                    } label: {
                        Text("\(minutes) min")
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(Capsule().fill(Theme.tile))
                    }
                    .buttonStyle(PressableStyle())
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func roundButton(_ icon: String, size: CGFloat, filled: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button {
            touch()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(filled ? Color.black : Theme.text)
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? Theme.on : Theme.tile))
        }
        .buttonStyle(PressableStyle())
    }

    private func smallButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            touch()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.tile))
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: behaviour

    private func toggleControls() {
        if showingControls {
            showingControls = false
            hideControls?.cancel()
        } else {
            showControls()
        }
    }

    private func showControls() {
        showingControls = true
        touch()
    }

    /// Any touch on the controls keeps them up a little longer.
    private func touch() {
        model.tap()
        hideControls?.cancel()
        let hide = DispatchWorkItem { showingControls = false }
        hideControls = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.controlsSeconds, execute: hide)
    }

    private var chosenList: [String] {
        chosenIds.isEmpty ? model.shortcuts.prefix(6).map(\.id) : chosenIds.components(separatedBy: ",")
    }

    private var chosenShortcuts: [Shortcut] {
        chosenList.compactMap { id in model.shortcuts.first { $0.id == id } }
    }

    /// Night: dim red. Auto = 22:00 to 7:00.
    private func isNight(_ date: Date) -> Bool {
        switch NightMode(rawValue: nightSetting) ?? .auto {
        case .on: return true
        case .off: return false
        case .auto:
            let hour = Calendar.current.component(.hour, from: date)
            return hour >= 22 || hour < 7
        }
    }

    private var nightIcon: String {
        switch NightMode(rawValue: nightSetting) ?? .auto {
        case .auto: return "moon.haze"
        case .on: return "moon.fill"
        case .off: return "sun.max"
        }
    }

    private func cycleNight() {
        switch NightMode(rawValue: nightSetting) ?? .auto {
        case .auto: nightSetting = NightMode.on.rawValue
        case .on: nightSetting = NightMode.off.rawValue
        case .off: nightSetting = NightMode.auto.rawValue
        }
    }

    /// A few points this way or that, changing every minute: no burn-in.
    private func drift(_ date: Date) -> CGSize {
        let minute = Double(Calendar.current.component(.minute, from: date))
        return CGSize(width: sin(minute * 0.7) * 8, height: cos(minute * 1.3) * 8)
    }

    static let nightRed = Color(red: 0.78, green: 0.2, blue: 0.18)
    static let nightDim = Color(red: 0.43, green: 0.12, blue: 0.11)
}

/// A soft light that slowly grows and shrinks.
private struct BreathingGlow: View {
    let colour: Color
    let diameter: CGFloat
    @State private var big = false

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [colour, colour.opacity(0)], center: .center,
                                 startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
            .scaleEffect(big ? 1.12 : 1)
            .opacity(big ? 1 : 0.75)
            .onAppear {
                withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { big = true }
            }
    }
}

/// Four bars bouncing while music plays, still when it's paused.
private struct EqualizerBars: View {
    let playing: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: playing ? 4 + 12 * abs(sin(t * 3.2 + Double(i) * 1.1)) : 4)
                }
            }
            .frame(height: 16, alignment: .bottom)
        }
    }
}

/// The Dock's timer. Lives in the app model, so it keeps going after leaving the Dock.
final class DockTimer: ObservableObject {
    @Published private(set) var end: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var total: TimeInterval = 1
    @Published private(set) var finished = false
    private var ticker: AnyCancellable?

    var isRunning: Bool { end != nil }
    var isPaused: Bool { pausedRemaining != nil }

    var remaining: TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let end else { return 0 }
        return max(0, end.timeIntervalSinceNow)
    }

    var progress: Double { finished ? 1 : 1 - remaining / total }

    var remainingText: String {
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func start(minutes: Int) {
        total = TimeInterval(minutes * 60)
        end = Date().addingTimeInterval(total)
        pausedRemaining = nil
        finished = false
        watch()
    }

    func togglePause() {
        if let pausedRemaining {
            end = Date().addingTimeInterval(pausedRemaining)
            self.pausedRemaining = nil
            watch()
        } else if end != nil {
            pausedRemaining = remaining
            end = nil
            ticker = nil
        }
    }

    func stop() {
        end = nil
        pausedRemaining = nil
        finished = false
        ticker = nil
    }

    private func watch() {
        ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, let end = self.end, end.timeIntervalSinceNow <= 0 else { return }
            self.end = nil
            self.ticker = nil
            self.finished = true
            AudioServicesPlaySystemSound(1005)  // a short chime
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

/// Choose up to six shortcuts for the Dock.
struct DockShortcutPicker: View {
    let all: [Shortcut]
    @State var chosen: [String]
    let done: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    init(all: [Shortcut], chosen: [String], done: @escaping ([String]) -> Void) {
        self.all = all
        _chosen = State(initialValue: chosen)
        self.done = done
    }

    var body: some View {
        NavigationStack {
            List(all) { shortcut in
                Button {
                    if let index = chosen.firstIndex(of: shortcut.id) {
                        chosen.remove(at: index)
                    } else if chosen.count < 6 {
                        chosen.append(shortcut.id)
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: shortcut.icon).frame(width: 28)
                        Text(shortcut.title)
                        Spacer()
                        if chosen.contains(shortcut.id) {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
                .foregroundStyle(Theme.text)
                .disabled(!chosen.contains(shortcut.id) && chosen.count >= 6)
            }
            .navigationTitle("Dock shortcuts (\(chosen.count) of 6)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        done(chosen)
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
