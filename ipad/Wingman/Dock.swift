import AVFoundation
import Combine
import SwiftUI
import UserNotifications

/// The Dock: for an iPad or iPhone standing next to the laptop, mostly on its
/// side. At rest: a huge clock with the date and a running timer, the song
/// that's playing (nothing when nothing plays) and six chosen shortcuts, on true
/// black with a slow glow in the song's colour. A tap on empty space brings up
/// the controls (music, every shortcut in a sliding row, the timer), which fade
/// away by themselves. Night (dim red) switches itself on at 22:00 and off at
/// 7:00, and can be switched by hand. Everything that changes eases: the
/// minutes roll, the burn-in drift glides, night fades in.
struct DockView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var timer: DockTimer
    @ObservedObject private var styles = DockStyleStore.shared
    @State private var showingControls = false
    @State private var hideControls: DispatchWorkItem?
    @State private var pickingShortcuts = false
    @State private var pickingTimer = false
    @State private var styleNote: String?  // the style's name, briefly, after sliding to it
    @State private var hideStyleNote: DispatchWorkItem?
    @AppStorage("dock.shortcuts") private var chosenIds = ""  // comma-separated; empty: the first six
    // a hand-picked night setting, until the next automatic switch (22:00 / 7:00)
    @AppStorage("dock.nightOverride") private var nightOverride = -1  // -1 none, 0 day, 1 night
    @AppStorage("dock.nightOverrideUntil") private var nightOverrideUntil = 0.0

    static let nightRed = Color(red: 0.78, green: 0.2, blue: 0.18)
    static let nightDim = Color(red: 0.43, green: 0.12, blue: 0.11)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let night = isNight(context.date)
            let style = styles.current
            GeometryReader { geometry in
                ZStack {
                    DockBackground(style: style, night: night, songColour: songColour, artwork: model.artwork,
                                   size: geometry.size)
                        .animation(.easeInOut(duration: 2), value: model.nowPlaying?.title)
                    DockFace(model: model, timer: timer, style: style, night: night, date: context.date,
                             size: geometry.size, shortcuts: chosenShortcuts)
                        .id(style.id)
                        .transition(.opacity)
                        .offset(drift(context.date))
                        .animation(.easeInOut(duration: 8), value: Calendar.current.component(.minute, from: context.date))
                        .opacity(showingControls ? 0.25 : 1)
                    if let styleNote {
                        styleBadge(styleNote, night: night)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 24)
                            .transition(.opacity)
                    }
                    if showingControls {
                        controls(night: night, size: geometry.size)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .animation(.easeInOut(duration: 0.4), value: showingControls)
                .animation(.easeInOut(duration: 0.5), value: styles.currentId)
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
                // slide sideways: the next or previous style
                .gesture(DragGesture(minimumDistance: 40).onEnded { drag in
                    guard !showingControls, abs(drag.translation.width) > 80,
                          abs(drag.translation.width) > abs(drag.translation.height) * 1.5 else { return }
                    slideStyle(drag.translation.width < 0 ? 1 : -1)
                })
            }
            .foregroundStyle(night ? Self.nightRed : style.text)
            .animation(.easeInOut(duration: 2.5), value: night)
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { styles.resetToDefault() }  // each time the Dock opens: the default style
        .onChange(of: timer.finished) { finished in
            if finished { showControls() }
        }
        .sheet(isPresented: $pickingShortcuts) {
            DockShortcutPicker(all: model.shortcuts, chosen: chosenList) { ids in
                chosenIds = ids.joined(separator: ",")
            }
        }
        .sheet(isPresented: $pickingTimer) {
            TimerPicker { seconds in timer.start(seconds: seconds) }
        }
    }

    // MARK: styles

    private func slideStyle(_ by: Int) {
        guard styles.styles.count > 1 else { return }
        model.tap()
        styles.step(by)
        styleNote = styles.current.name
        hideStyleNote?.cancel()
        let hide = DispatchWorkItem { styleNote = nil }
        hideStyleNote = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: hide)
    }

    /// The style's name and a dot for each style, after sliding.
    private func styleBadge(_ name: String, night: Bool) -> some View {
        VStack(spacing: 8) {
            Text(name).font(.system(size: 15, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(styles.styles) { style in
                    Circle()
                        .fill(style.id == styles.currentId ? Color.white : Color.white.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.6)))
        .foregroundStyle(night ? Self.nightRed : .white)
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

    /// Player on top, every shortcut in a sliding row, the timer, then the
    /// Dock's own buttons. Fades away after a few seconds without touches.
    private func controls(night: Bool, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: isPhone ? 14 : 22) {
            if let playing = model.nowPlaying {  // nothing to control when nothing plays
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playing.title).font(.system(size: isPhone ? 16 : 20, weight: .semibold)).lineLimit(1)
                        Text(playing.artist.isEmpty ? playing.app : playing.artist)
                            .font(.system(size: 13)).foregroundStyle(night ? Self.nightDim : Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    roundButton("backward.fill", size: isPhone ? 46 : 56) { model.media("previous") }
                    roundButton(playing.playing ? "pause.fill" : "play.fill", size: isPhone ? 58 : 70, filled: true,
                                night: night) { model.media("play_pause") }
                    roundButton("forward.fill", size: isPhone ? 46 : 56) { model.media("next") }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(model.shortcuts) { shortcut in
                        Button {
                            touch()
                            model.run(shortcut)
                        } label: {
                            VStack(spacing: 6) {
                                ShortcutIcon(shortcut: shortcut, size: 20)
                                    .frame(width: 54, height: 54)
                                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.tile))
                                Text(shortcut.title)
                                    .font(.system(size: 11))
                                    .foregroundStyle(night ? Self.nightDim : Theme.secondary)
                                    .lineLimit(1)
                                    .frame(width: 70)
                            }
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            timerRow(night: night)
            HStack(spacing: 10) {
                pillButton(night ? "Day" : "Night", icon: night ? "sun.max.fill" : "moon.fill") { switchNight() }
                pillButton("Choose shortcuts", icon: "square.grid.3x2") { pickingShortcuts = true }
                Spacer(minLength: 0)
                roundButton("xmark", size: 44) { model.goHome() }
            }
        }
        .padding(isPhone ? 18 : 28)
        .frame(maxWidth: 900)
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Color(white: 0.09).opacity(0.94)))
        .padding(isPhone ? 12 : 32)
        .frame(maxHeight: .infinity, alignment: size.width > size.height ? .center : .bottom)
        .onTapGesture { touch() }  // taps inside keep it open
    }

    /// Start a timer (quick lengths or any length up to 23 h 59 min), or see,
    /// pause and stop the one running.
    @ViewBuilder private func timerRow(night: Bool) -> some View {
        if timer.isRunning || timer.isPaused || timer.finished {
            HStack(spacing: 14) {
                Image(systemName: timer.finished ? "bell.fill" : "timer")
                    .foregroundStyle(timer.finished ? Theme.warm : night ? Self.nightDim : Theme.secondary)
                Text(timer.finished ? "Time's up" : timer.remainingText)
                    .font(.system(size: isPhone ? 24 : 30, weight: .light))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeInOut(duration: 0.3), value: timer.remainingText)
                ProgressView(value: timer.progress)
                    .tint(night ? Self.nightRed : Theme.on)
                    .frame(maxWidth: 260)
                Spacer(minLength: 0)
                if !timer.finished {
                    roundButton(timer.isPaused ? "play.fill" : "pause.fill", size: 44) { timer.togglePause() }
                }
                roundButton("stop.fill", size: 44) { timer.stop() }
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Image(systemName: "timer").foregroundStyle(night ? Self.nightDim : Theme.secondary)
                    ForEach([5, 15, 25, 45, 60, 90, 120], id: \.self) { minutes in
                        pillButton(minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h"
                                   : "\(minutes / 60) h \(minutes % 60)", icon: nil) {
                            timer.start(seconds: TimeInterval(minutes * 60))
                        }
                    }
                    pillButton("Custom", icon: "slider.horizontal.3") { pickingTimer = true }
                }
            }
        }
    }

    private func roundButton(_ icon: String, size: CGFloat, filled: Bool = false, night: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button {
            touch()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(filled ? AnyShapeStyle(Color.black) : AnyShapeStyle(.primary))
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? (night ? Self.nightRed : Theme.on) : Theme.tile))
        }
        .buttonStyle(PressableStyle())
    }

    private func pillButton(_ title: String, icon: String?, action: @escaping () -> Void) -> some View {
        Button {
            touch()
            action()
        } label: {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(Capsule().fill(Theme.tile))
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Prefs.dockFadeSeconds, execute: hide)
    }

    /// The chosen shortcuts' ids, leaving out any since deleted: a deleted one
    /// would otherwise keep its slot, shown nowhere, and block choosing a sixth.
    private var chosenList: [String] {
        let existing = Set(model.shortcuts.map(\.id))
        let chosen = chosenIds.components(separatedBy: ",").filter { existing.contains($0) }
        return chosen.isEmpty ? model.shortcuts.prefix(6).map(\.id) : chosen
    }

    private var chosenShortcuts: [Shortcut] {
        chosenList.compactMap { id in model.shortcuts.first { $0.id == id } }
    }

    /// Night between the hours set in Settings (22:00 to 7:00 at first), unless switched by hand since the last change.
    private func isNight(_ date: Date) -> Bool {
        if nightOverride >= 0, date.timeIntervalSince1970 < nightOverrideUntil {
            return nightOverride == 1
        }
        let hour = Calendar.current.component(.hour, from: date)
        let start = Prefs.nightStartHour, end = Prefs.nightEndHour
        return start > end ? (hour >= start || hour < end) : (hour >= start && hour < end)
    }

    /// Switch now; it holds until the next automatic change.
    private func switchNight() {
        let now = Date()
        nightOverride = isNight(now) ? 0 : 1
        let calendar = Calendar.current
        let hours: [Int] = [Prefs.nightStartHour, Prefs.nightEndHour]
        let changes: [Date] = hours.compactMap { hour in
            calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: 0), matchingPolicy: .nextTime)
        }
        let next: Date = changes.min() ?? now.addingTimeInterval(12 * 3600)
        nightOverrideUntil = next.timeIntervalSince1970
    }

    /// A few points this way or that, gliding each minute: no burn-in.
    private func drift(_ date: Date) -> CGSize {
        let minute = Double(Calendar.current.component(.minute, from: date))
        return CGSize(width: sin(minute * 0.7) * 10, height: cos(minute * 1.3) * 10)
    }
}

/// Hours and minutes for a timer of any length (iOS's own countdown wheel).
private struct TimerPicker: View {
    let start: (TimeInterval) -> Void
    @State private var duration: TimeInterval = 30 * 60
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CountdownWheel(duration: $duration)
                .padding()
                .navigationTitle("Timer")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Start") {
                            start(duration)
                            dismiss()
                        }
                        .disabled(duration < 60)
                    }
                }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}

private struct CountdownWheel: UIViewRepresentable {
    @Binding var duration: TimeInterval

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .countDownTimer
        picker.countDownDuration = duration
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(duration: $duration) }

    final class Coordinator: NSObject {
        var duration: Binding<TimeInterval>
        init(duration: Binding<TimeInterval>) { self.duration = duration }
        @objc func changed(_ picker: UIDatePicker) { duration.wrappedValue = picker.countDownDuration }
    }
}

/// Four bars bouncing while music plays, still when it's paused.
/// The laptop's volume as a thin line next to the song. It fades out after a
/// few seconds so the Dock stays calm, but keeps working: sliding where it was
/// brings it back. Sliding moves it from where it is (it doesn't jump to the
/// finger), so touching the hidden line never changes the volume by surprise.
struct DockVolume: View {
    @ObservedObject var model: AppModel
    let color: Color
    static let visibleSeconds = 3.0

    @State private var level = 0.0
    @State private var startLevel: Double?
    @State private var visible = true
    @State private var hide: DispatchWorkItem?
    @State private var lastSent = Date.distantPast

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let dragging = startLevel != nil
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.2))
                Capsule().fill(color).frame(width: max(width * level, dragging ? 8 : 5))
            }
            .frame(height: dragging ? 8 : 5)
            .frame(maxHeight: .infinity)
            .opacity(visible ? 1 : 0)
            .contentShape(Rectangle())  // still there to slide when it's hidden
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if startLevel == nil {
                        startLevel = level
                        appear()
                    }
                    level = min(max((startLevel ?? level) + drag.translation.width / width, 0), 1)
                    if Date().timeIntervalSince(lastSent) > 0.1 {
                        lastSent = Date()
                        send()
                    }
                }
                .onEnded { _ in
                    startLevel = nil
                    send()
                    haptic()
                    fadeLater()
                })
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 44)
        .animation(.easeInOut(duration: 0.6), value: visible)
        .animation(.interactiveSpring(response: 0.25), value: level)
        .onAppear {
            level = Double(model.controls?.volume ?? 0) / 100
            fadeLater()
        }
        .onChange(of: model.controls?.volume) { newValue in
            if startLevel == nil, let newValue { level = Double(newValue) / 100 }
        }
        .accessibilityLabel("Laptop volume")
    }

    private func send() {
        let value = Int((level * 100).rounded())
        model.controls?.volume = value
        model.control("volume", value)
    }

    private func appear() {
        hide?.cancel()
        visible = true
    }

    private func fadeLater() {
        hide?.cancel()
        let work = DispatchWorkItem { visible = false }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds, execute: work)
    }
}

struct EqualizerBars: View {
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
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Called when a timer runs out while Wingman is open (the app tells the laptop).
    var onFinish: (() -> Void)?
    private var alarm: AVAudioPlayer?
    private static let notificationId = "wingman.timer"

    func start(seconds: TimeInterval) {
        total = max(seconds, 1)
        end = Date().addingTimeInterval(total)
        pausedRemaining = nil
        finished = false
        stopAlarm()
        scheduleNotification()
        watch()
        updateLiveActivity()
    }

    func togglePause() {
        if let pausedRemaining {
            end = Date().addingTimeInterval(pausedRemaining)
            self.pausedRemaining = nil
            scheduleNotification()
            watch()
        } else if end != nil {
            pausedRemaining = remaining
            end = nil
            ticker = nil
            cancelNotification()
        }
        updateLiveActivity()
    }

    func stop() {
        end = nil
        pausedRemaining = nil
        finished = false
        ticker = nil
        stopAlarm()
        cancelNotification()
        updateLiveActivity()
    }

    /// The timer on the Lock Screen and in the Dynamic Island: started, updated
    /// and ended with the timer (iOS counts down by itself, app open or not).
    private func updateLiveActivity() {
        guard #available(iOS 16.2, *) else { return }
        let state = TimerActivity.ContentState(end: end, pausedRemaining: pausedRemaining, total: total,
                                               finished: finished)
        let active = isRunning || isPaused || finished
        Task { await LiveTimer.show(state, active: active) }
    }

    private func watch() {
        ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, let end = self.end, end.timeIntervalSinceNow <= 0 else { return }
            let late = -end.timeIntervalSinceNow
            self.end = nil
            self.ticker = nil
            self.finished = true
            self.updateLiveActivity()
            // back in the app long after the end: the notification already rang
            if late < 5 {
                self.ringAlarm()
                self.onFinish?()
            }
        }
    }

    // MARK: the alarm: a soft chime, again and again until stopped

    private func ringAlarm() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let session = AVAudioSession.sharedInstance()
        // playback: the iPhone's silent switch doesn't mute it, like the Clock app's timer
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true)
        alarm = try? AVAudioPlayer(data: Self.chime())
        alarm?.numberOfLoops = -1
        alarm?.volume = 0.8
        alarm?.play()
    }

    private func stopAlarm() {
        guard alarm != nil else { return }
        alarm?.stop()
        alarm = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Two soft bell tones and a pause, as a WAV made right here (no sound file needed).
    private static func chime() -> Data {
        let rate = 44_100
        var samples = [Int16]()
        for (start, frequency) in [(0.0, 880.0), (0.28, 1318.5)] {
            let offset = Int(start * Double(rate))
            for i in 0..<Int(1.2 * Double(rate)) {
                let t = Double(i) / Double(rate)
                let bell = sin(2 * .pi * frequency * t) + 0.3 * sin(2 * .pi * frequency * 2 * t)
                let value = bell * exp(-3.2 * t) * 0.32 * Double(Int16.max)
                let index = offset + i
                if index >= samples.count { samples.append(0) }
                samples[index] = Int16(clamping: Int(samples[index]) + Int(value))
            }
        }
        samples += Array(repeating: 0, count: rate * 3 / 4)  // the pause before it rings again
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(samples.count * 2))
        samples.forEach { put($0) }
        return data
    }

    // MARK: a notification, for when Wingman is closed or the screen is locked

    private func scheduleNotification() {
        let center = UNUserNotificationCenter.current()
        let seconds = remaining
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted, seconds > 1 else { return }
            let content = UNMutableNotificationContent()
            content.title = "Time's up"
            content.body = "Your Wingman timer has finished."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            center.add(UNNotificationRequest(identifier: Self.notificationId, content: content, trigger: trigger))
        }
    }

    private func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationId])
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
                        ShortcutIcon(shortcut: shortcut, size: 18).frame(width: 28)
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
