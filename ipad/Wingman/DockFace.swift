import SwiftUI

/// The Dock at rest, drawn the way one style says: the clock, the date, a
/// running timer, the song (with its volume line) and the chosen shortcuts, in
/// one of three layouts. Used by the Dock itself and by the style editor's
/// preview. At night everything turns dim red, whatever the style.
struct DockFace: View {
    @ObservedObject var model: AppModel
    @ObservedObject var timer: DockTimer
    let style: DockStyle
    let night: Bool
    let date: Date
    let size: CGSize
    let shortcuts: [Shortcut]
    /// The editor's preview: buttons and the volume line don't act.
    var preview = false

    private var text: Color { night ? DockView.nightRed : style.text }
    private var dim: Color { night ? DockView.nightDim : style.text.opacity(0.55) }
    private var accent: Color { night ? DockView.nightRed : style.accent }
    private var landscape: Bool { size.width > size.height }
    private var phone: Bool { min(size.width, size.height) < 500 }

    var body: some View {
        Group {
            switch (style.layout, landscape) {
            case (.side, true): side
            case (.centred, _): centred
            default: stacked  // .stacked, and .side when upright
            }
        }
        .foregroundStyle(text)
    }

    // MARK: layouts

    /// On its side: the clock on the left; the song on top and the shortcuts
    /// below on the right, the column as tall as the clock block.
    private var side: some View {
        let column = size.width * (phone ? 0.36 : 0.34)
        let block = size.height * (phone ? 0.78 : 0.62)
        return HStack(alignment: .center, spacing: size.width * 0.06) {
            clockBlock(height: size.height * (phone ? 0.42 : 0.32), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if style.showSong || style.showShortcuts {
                VStack(alignment: .leading, spacing: 0) {
                    if style.showSong { song(alignment: .leading) }
                    Spacer(minLength: size.height * 0.05)
                    if style.showShortcuts { shortcutGrid(columns: 3, width: column) }
                }
                .frame(width: column, height: block, alignment: .topLeading)
            }
        }
        .padding(.horizontal, size.width * 0.06)
    }

    /// Everything centred: the clock big in the middle, the song under it, the
    /// shortcuts in one row at the bottom.
    private var centred: some View {
        let base = landscape ? size.height * (phone ? 0.4 : 0.3) : size.width * 0.28
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            clockBlock(height: base, alignment: .center)
            if style.showSong {
                song(alignment: .center)
                    .frame(maxWidth: min(size.width * 0.6, 520))
                    .padding(.top, size.height * 0.04)
            }
            Spacer(minLength: size.height * 0.05)
            if style.showShortcuts {
                shortcutRow(width: min(size.width * 0.8, 760))
            }
        }
        .padding(.vertical, size.height * 0.07)
        .frame(maxWidth: .infinity)
    }

    /// Top to bottom on the left: clock, date, song; the shortcuts across the bottom.
    private var stacked: some View {
        let base = landscape ? size.height * (phone ? 0.36 : 0.26) : size.width * 0.3
        return VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            clockBlock(height: base, alignment: .leading)
            if style.showSong {
                song(alignment: .leading)
                    .frame(maxWidth: landscape ? size.width * 0.5 : .infinity, alignment: .leading)
                    .padding(.top, size.height * 0.04)
            }
            Spacer(minLength: size.height * 0.06)
            if style.showShortcuts {
                if landscape {
                    shortcutRow(width: size.width * 0.84)
                } else {
                    shortcutGrid(columns: phone ? 3 : 6, width: size.width * 0.84)
                }
            }
        }
        .padding(.horizontal, size.width * (landscape ? 0.06 : 0.08))
        .padding(.vertical, size.height * 0.07)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: pieces

    /// The clock with the date and a running timer under it.
    private func clockBlock(height: CGFloat, alignment: HorizontalAlignment) -> some View {
        let clockHeight = height * min(max(style.clockSize, 0.6), 1.4)
        let small = max(15, clockHeight * 0.13)
        return VStack(alignment: alignment, spacing: clockHeight * 0.05) {
            DockClock(style: style, date: date, height: clockHeight, color: text, accent: accent)
            if style.showDate {
                Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: small))
                    .foregroundStyle(dim)
            }
            if style.showTimer, timer.isRunning || timer.isPaused || timer.finished {
                Label(timer.finished ? "Time's up" : timer.remainingText,
                      systemImage: timer.finished ? "bell.fill" : timer.isPaused ? "pause.fill" : "timer")
                    .font(.system(size: small, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeInOut(duration: 0.3), value: timer.remainingText)
                    .foregroundStyle(timer.finished ? Theme.warm : accent)
            }
        }
    }

    /// What's playing (nothing when nothing plays), with the volume line beside it.
    @ViewBuilder private func song(alignment: HorizontalAlignment) -> some View {
        if let playing = model.nowPlaying, !playing.title.isEmpty {
            VStack(alignment: alignment, spacing: 4) {
                EqualizerBars(playing: playing.playing, color: accent)
                    .padding(.bottom, 6)
                HStack(alignment: .center, spacing: phone ? 12 : 20) {
                    Text(playing.title)
                        .font(.system(size: phone ? 19 : 28, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(alignment == .center ? .center : .leading)
                    if style.showVolume, model.controls?.volume != nil {
                        if alignment == .leading { Spacer(minLength: 0) }
                        DockVolume(model: model, color: accent)
                            .frame(width: phone ? 72 : 120)
                            .allowsHitTesting(!preview)
                    }
                }
                Text(playing.artist.isEmpty ? playing.app : playing.artist)
                    .font(.system(size: phone ? 14 : 18))
                    .foregroundStyle(dim)
                    .lineLimit(1)
            }
            .animation(.easeInOut(duration: 0.6), value: playing.title)
        }
    }

    /// The chosen shortcuts in a grid filling `width`: tiles grow with the room.
    private func shortcutGrid(columns: Int, width: CGFloat) -> some View {
        let gap = width * (columns > 3 ? 0.04 : 0.08)
        let fit = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let side = min(fit, (phone ? 84 : 110) * scale)
        let spread = (width - side * CGFloat(columns)) / CGFloat(max(columns - 1, 1))
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spread), count: columns),
                         alignment: .leading, spacing: min(spread, side * 0.4)) {
            ForEach(shortcuts) { shortcutButton($0, side: side) }
        }
    }

    /// The chosen shortcuts in one centred row.
    private func shortcutRow(width: CGFloat) -> some View {
        let count = max(shortcuts.count, 1)
        let gap: CGFloat = phone ? 12 : 20
        let side = min((width - gap * CGFloat(count - 1)) / CGFloat(count), (phone ? 64 : 90) * scale)
        return HStack(spacing: gap) {
            ForEach(shortcuts) { shortcutButton($0, side: side) }
        }
        .frame(maxWidth: .infinity)
    }

    private var scale: CGFloat { CGFloat(min(max(style.shortcutSize, 0.7), 1.3)) }

    private func shortcutButton(_ shortcut: Shortcut, side: CGFloat) -> some View {
        Button {
            guard !preview else { return }
            model.tap()
            model.run(shortcut)
        } label: {
            ShortcutIcon(shortcut: shortcut, size: side * 0.36)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .fill(night ? DockView.nightRed.opacity(0.12) : Color.white.opacity(0.07)))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(shortcut.title)
    }
}
