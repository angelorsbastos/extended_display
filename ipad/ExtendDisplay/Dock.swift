import AudioToolbox
import Combine
import SwiftUI

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
    @State private var showingControls = false
    @State private var hideControls: DispatchWorkItem?
    @State private var pickingShortcuts = false
    @State private var pickingTimer = false
    @AppStorage("dock.shortcuts") private var chosenIds = ""  // comma-separated; empty: the first six
    // a hand-picked night setting, until the next automatic switch (22:00 / 7:00)
    @AppStorage("dock.nightOverride") private var nightOverride = -1  // -1 none, 0 day, 1 night
    @AppStorage("dock.nightOverrideUntil") private var nightOverrideUntil = 0.0

    static let controlsSeconds = 6.0
    static let nightRed = Color(red: 0.78, green: 0.2, blue: 0.18)
    static let nightDim = Color(red: 0.43, green: 0.12, blue: 0.11)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let night = isNight(context.date)
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    glow(night: night, size: geometry.size)
                    resting(context.date, size: geometry.size, night: night)
                        .offset(drift(context.date))
                        .animation(.easeInOut(duration: 8), value: Calendar.current.component(.minute, from: context.date))
                        .opacity(showingControls ? 0.25 : 1)
                    if showingControls {
                        controls(night: night, size: geometry.size)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .animation(.easeInOut(duration: 0.4), value: showingControls)
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
            }
            .foregroundStyle(night ? Self.nightRed : Theme.text)
            .animation(.easeInOut(duration: 2.5), value: night)
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
        .sheet(isPresented: $pickingTimer) {
            TimerPicker { seconds in timer.start(seconds: seconds) }
        }
    }

    // MARK: at rest

    @ViewBuilder
    private func resting(_ date: Date, size: CGSize, night: Bool) -> some View {
        if size.width > size.height {
            // on its side (the usual): clock on the left, music and shortcuts on the right
            HStack(alignment: .center, spacing: size.width * 0.05) {
                clock(date, height: size.height * (isPhone ? 0.44 : 0.34), night: night)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: size.height * 0.08) {
                    song(night: night)
                    shortcutGrid(columns: 3, night: night)
                }
                .frame(width: size.width * (isPhone ? 0.34 : 0.32), alignment: .leading)
            }
            .padding(.horizontal, size.width * 0.06)
            .padding(.vertical, size.height * 0.08)
        } else {
            // upright: clock on top, music under it, shortcuts at the bottom
            VStack(alignment: .leading, spacing: size.height * 0.05) {
                Spacer(minLength: 0)
                clock(date, height: size.width * 0.3, night: night)
                song(night: night)
                Spacer(minLength: 0)
                shortcutGrid(columns: isPhone ? 3 : 6, night: night)
            }
            .padding(.horizontal, size.width * 0.08)
            .padding(.vertical, size.height * 0.07)
        }
    }

    private func clock(_ date: Date, height: CGFloat, night: Bool) -> some View {
        let time = date.formatted(.dateTime.hour().minute())
        return VStack(alignment: .leading, spacing: height * 0.04) {
            Text(time)
                .font(.system(size: height, weight: .thin))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.9), value: time)  // the minutes roll over gently
                .minimumScaleFactor(0.4)
                .lineLimit(1)
            Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: max(15, height * 0.13)))
                .foregroundStyle(night ? Self.nightDim : Theme.secondary)
                .padding(.leading, height * 0.04)
            if timer.isRunning || timer.isPaused || timer.finished {
                Label(timer.finished ? "Time's up" : timer.remainingText,
                      systemImage: timer.finished ? "bell.fill" : timer.isPaused ? "pause.fill" : "timer")
                    .font(.system(size: max(15, height * 0.13), weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeInOut(duration: 0.3), value: timer.remainingText)
                    .foregroundStyle(timer.finished ? Theme.warm : night ? Self.nightRed : Theme.text)
                    .padding(.leading, height * 0.04)
            }
        }
    }

    @ViewBuilder private func song(night: Bool) -> some View {
        if let playing = model.nowPlaying, !playing.title.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                EqualizerBars(playing: playing.playing, color: night ? Self.nightRed : Theme.text)
                    .padding(.bottom, 6)
                Text(playing.title)
                    .font(.system(size: isPhone ? 19 : 28, weight: .semibold))
                    .lineLimit(2)
                Text(playing.artist.isEmpty ? playing.app : playing.artist)
                    .font(.system(size: isPhone ? 14 : 18))
                    .foregroundStyle(night ? Self.nightDim : Theme.secondary)
                    .lineLimit(1)
            }
            .animation(.easeInOut(duration: 0.6), value: playing.title)
        }
    }

    /// The six chosen shortcuts, quiet, one tap each.
    private func shortcutGrid(columns: Int, night: Bool) -> some View {
        let side: CGFloat = isPhone ? 50 : 68
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: isPhone ? 12 : 16), count: columns),
                         alignment: .leading, spacing: isPhone ? 12 : 16) {
            ForEach(chosenShortcuts) { shortcut in
                Button {
                    model.tap()
                    model.run(shortcut)
                } label: {
                    Image(systemName: shortcut.icon)
                        .font(.system(size: side * 0.36, weight: .semibold))
                        .frame(width: side, height: side)
                        .background(RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                            .fill(night ? Self.nightRed.opacity(0.12) : Color.white.opacity(0.07)))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(shortcut.title)
            }
        }
    }

    /// A slow breathing light behind everything, in a colour of the song's own.
    private func glow(night: Bool, size: CGSize) -> some View {
        let colour = night ? Color(red: 0.6, green: 0.05, blue: 0.05) : songColour
        return BreathingGlow(colour: colour.opacity(night ? 0.16 : 0.3), diameter: max(size.width, size.height) * 0.9)
            .position(x: size.width * 0.22, y: size.height * 0.3)
            .animation(.easeInOut(duration: 2), value: model.nowPlaying?.title)
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
                                Image(systemName: shortcut.icon)
                                    .font(.system(size: 20, weight: .semibold))
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.controlsSeconds, execute: hide)
    }

    private var chosenList: [String] {
        chosenIds.isEmpty ? model.shortcuts.prefix(6).map(\.id) : chosenIds.components(separatedBy: ",")
    }

    private var chosenShortcuts: [Shortcut] {
        chosenList.compactMap { id in model.shortcuts.first { $0.id == id } }
    }

    /// Night from 22:00 to 7:00, unless switched by hand since the last change.
    private func isNight(_ date: Date) -> Bool {
        if nightOverride >= 0, date.timeIntervalSince1970 < nightOverrideUntil {
            return nightOverride == 1
        }
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 22 || hour < 7
    }

    /// Switch now; it holds until the next automatic change (22:00 or 7:00).
    private func switchNight() {
        let now = Date()
        nightOverride = isNight(now) ? 0 : 1
        let calendar = Calendar.current
        let next = [22, 7].compactMap {
            calendar.nextDate(after: now, matching: DateComponents(hour: $0, minute: 0), matchingPolicy: .nextTime)
        }.min() ?? now.addingTimeInterval(12 * 3600)
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
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func start(seconds: TimeInterval) {
        total = max(seconds, 1)
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
