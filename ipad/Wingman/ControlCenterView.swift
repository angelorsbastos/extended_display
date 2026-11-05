import SwiftUI

/// The home screen, as a Control Center for the laptop: the things done most
/// work right here (volume, brightness, music, sound, shortcuts, the keyboard
/// switch), and the big blue tile is the main action (Extend on the iPad,
/// Trackpad on the iPhone). The header's pills open the connection details,
/// Controls and the Dashboard.
struct ControlCenterView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var history: ClipboardHistory
    @ObservedObject var files: FileTransfers
    @State private var showingConnection = false

    private var gap: CGFloat { Theme.gap }

    var body: some View {
        VStack(alignment: .leading, spacing: isPhone ? 14 : 18) {
            header
            if isPhone {
                GeometryReader { geometry in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: gap) {
                            if !model.connected {
                                ConnectCard(model: model)
                            }
                            phoneTiles(width: geometry.size.width)
                        }
                        .padding(.bottom, 20)
                    }
                }
            } else {
                GeometryReader { geometry in
                    padTiles(geometry.size)
                        // not connected: the Connect card floats over the dimmed tiles
                        .overlay {
                            if !model.connected {
                                ConnectCard(model: model).padding(24)
                            }
                        }
                }
            }
        }
        .screenPadding()
        .foregroundStyle(Theme.text)
        .sheet(isPresented: $showingConnection) {
            NavigationStack {
                ScrollView { ConnectionPanel(model: model).padding() }
                    .navigationTitle("Connection")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingConnection = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.laptopName ?? "Wingman")
                    .font(.system(size: isPhone ? 28 : 34, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(model.connected ? Theme.secondary : Theme.warm)
            }
            Spacer(minLength: 8)
            Pill(icon: "gearshape.fill", text: nil) { model.open(.settings) }
            Pill(icon: connectionIcon, text: isPhone ? nil : connectionWord,
                 tint: model.connected ? Theme.good : Theme.warm) { showingConnection = true }
            if model.connected {
                if let battery = model.controls?.battery, let percent = battery.percent {
                    Pill(icon: battery.charging ? "battery.100.bolt" : "battery.75", text: "\(percent)%") {
                        model.open(.controls)
                    }
                }
                Pill(icon: "thermometer.medium", text: model.controls?.cpuTemp.map { "\($0)°" } ?? "–",
                     tint: Theme.temperature(model.controls?.cpuTemp)) { model.open(.dashboard) }
            }
        }
    }

    private var statusLine: String {
        switch model.transport {
        case .usb: return "Connected by cable"
        case .wifi: return "Connected over Wi-Fi"
        case .remote: return "Connected from afar"
        case nil: return model.connectStage == nil ? "Not connected" : "Connecting…"
        }
    }

    private var connectionWord: String {
        switch model.transport {
        case .usb: return "Cable"
        case .wifi: return "Wi-Fi"
        case .remote: return "Remote"
        case nil: return "Offline"
        }
    }

    private var connectionIcon: String {
        switch model.transport {
        case .usb: return "cable.connector"
        case .wifi: return "wifi"
        case .remote: return "globe"
        case nil: return "bolt.horizontal.circle"
        }
    }

    // MARK: layouts

    /// iPad: a 4 x 5 grid, like the mockup.
    private func padTiles(_ size: CGSize) -> some View {
        let w = (size.width - 3 * gap) / 4
        let h = max((size.height - 4 * gap) / 5, 60)
        return VStack(spacing: gap) {
            HStack(spacing: gap) {
                extendTile.frame(width: 2 * w + gap, height: 2 * h + gap)
                VStack(spacing: gap) {
                    mirrorTile.frame(width: w, height: h)
                    soundTile.frame(width: w, height: h)
                }
                volumeTile.frame(width: w, height: 2 * h + gap)
            }
            HStack(alignment: .top, spacing: gap) {
                VStack(spacing: gap) {
                    nowPlayingTile.frame(width: 2 * w + gap, height: h)
                    keyboardTile.frame(width: 2 * w + gap, height: h)
                    HStack(spacing: gap) {  // three small tiles in two columns' room
                        let third = (2 * w - gap) / 3
                        dockTile.frame(width: third, height: h)
                        clipboardTile.frame(width: third, height: h)
                        filesTile.frame(width: third, height: h)
                    }
                }
                brightnessTile.frame(width: w, height: 3 * h + 2 * gap)
                shortcutsTile(columns: 2).frame(width: w, height: 3 * h + 2 * gap)
            }
        }
    }

    /// iPhone: two columns, scrolling.
    private func phoneTiles(width: CGFloat) -> some View {
        let w = (width - gap) / 2
        let h: CGFloat = 92
        return VStack(spacing: gap) {
            HStack(spacing: gap) {
                trackpadTile.frame(width: w, height: 2 * h + gap)
                VStack(spacing: gap) {
                    mirrorTile.frame(width: w, height: h)
                    dockTile.frame(width: w, height: h)
                }
            }
            nowPlayingTile.frame(width: width, height: h)
            HStack(spacing: gap) {
                volumeTile.frame(width: w, height: 2 * h + gap)
                brightnessTile.frame(width: w, height: 2 * h + gap)
            }
            shortcutsTile(columns: 4).frame(width: width, height: 2 * h + gap)
            HStack(spacing: gap) {
                let third = (width - 2 * gap) / 3
                soundTile.frame(width: third, height: h)
                clipboardTile.frame(width: third, height: h)
                filesTile.frame(width: third, height: h)
            }
        }
    }

    // MARK: tiles

    /// Tiles that need the laptop: dimmed and inactive without it.
    private func needsLaptop<V: View>(_ tile: V) -> some View {
        tile.disabled(!model.connected).opacity(model.connected ? 1 : 0.35)
    }

    private var extendTile: some View {
        needsLaptop(Tile(style: .accent, action: { model.open(.video(.extend)) }) {
            ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 26, weight: .semibold))
                    Spacer()
                    Text("Extend")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Use the iPad as a second screen")
                        .font(.subheadline)
                        .opacity(0.8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // a little screen at the iPad's side
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.45), lineWidth: 2))
                    .frame(width: 120, height: 82)
                    .padding(4)
            }
        })
    }

    private var mirrorTile: some View {
        needsLaptop(Tile(action: { model.open(.video(.mirror)) }) {
            TileLabel(icon: "rectangle.on.rectangle", title: "Mirror", detail: "Same picture")
        })
    }

    private var trackpadTile: some View {
        needsLaptop(Tile(style: .accent, action: { model.open(.trackpad) }) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "rectangle.and.hand.point.up.left")
                    .font(.system(size: 26, weight: .semibold))
                Spacer()
                Text("Trackpad")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Point, click, type")
                    .font(.footnote)
                    .opacity(0.8)
            }
        })
    }

    private var dockTile: some View {
        Tile(action: { model.open(.dock) }) {  // a clock and timer work without the laptop too
            TileLabel(icon: "clock", title: "Dock", detail: "Focus clock")
        }
    }

    private var soundTile: some View {
        needsLaptop(Tile(style: model.soundOnIPad ? .on : .normal,
                         action: { model.setSoundOnIPad(!model.soundOnIPad) }) {
            TileLabel(icon: model.soundOnIPad ? "speaker.wave.2.fill" : "speaker.slash",
                      title: "Sound here", detail: model.soundOnIPad ? "On" : "On the laptop",
                      on: model.soundOnIPad)
        })
    }

    private var keyboardTile: some View {
        needsLaptop(Tile(style: model.laptopInput ? .on : .normal,
                         action: { model.setLaptopInput(!model.laptopInput) }) {
            HStack(spacing: 14) {
                Image(systemName: "keyboard")
                    .font(.system(size: 26, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Laptop keyboard and trackpad")
                        .font(.system(size: 15, weight: .semibold))
                    Text(model.laptopInput ? "Typing on this iPad" : "Or Ctrl+Alt+I on the laptop")
                        .font(.system(size: 12))
                        .foregroundStyle(model.laptopInput ? Theme.onText.opacity(0.65) : Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        })
    }

    private var volumeTile: some View {
        needsLaptop(SliderTile(icon: volumeIcon, value: model.controls?.volume) {
            model.controls?.volume = $0
            model.control("volume", $0)
        })
    }

    private var volumeIcon: String {
        guard let volume = model.controls?.volume, model.controls?.muted != true, volume > 0 else {
            return "speaker.slash.fill"
        }
        return volume < 34 ? "speaker.wave.1.fill" : volume < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    private var brightnessTile: some View {
        needsLaptop(SliderTile(icon: "sun.max.fill", value: model.controls?.brightness) {
            model.controls?.brightness = $0
            model.control("brightness", $0)
        })
    }

    private var nowPlayingTile: some View {
        needsLaptop(Tile(action: nil) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.tileRaised)
                    .overlay(Image(systemName: "music.note").foregroundStyle(Theme.secondary))
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.nowPlaying?.title ?? "Not playing")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(nowPlayingDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: isPhone ? 14 : 18) {
                    mediaButton("backward.fill", "previous")
                    mediaButton(model.nowPlaying?.playing == true ? "pause.fill" : "play.fill", "play_pause")
                    mediaButton("forward.fill", "next")
                }
            }
            .frame(maxHeight: .infinity)
        })
    }

    private var nowPlayingDetail: String {
        guard let playing = model.nowPlaying else { return "Music on the laptop" }
        return playing.artist.isEmpty ? playing.app : "\(playing.artist), \(playing.app)"
    }

    private func mediaButton(_ icon: String, _ action: String) -> some View {
        Button {
            model.tap()
            model.media(action)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 34, height: 44)
        }
        .buttonStyle(PressableStyle())
    }

    private func shortcutsTile(columns: Int) -> some View {
        needsLaptop(Tile(action: nil) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    model.open(.shortcuts)
                } label: {
                    HStack {
                        Text("Shortcuts").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.secondary)
                    }
                }
                .buttonStyle(.plain)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                          spacing: 8) {
                    ForEach(model.shortcuts.prefix(columns * (isPhone ? 2 : 4))) { shortcut in
                        Button {
                            model.tap()
                            model.run(shortcut)
                        } label: {
                            VStack(spacing: 4) {
                                ShortcutIcon(shortcut: shortcut, size: 18)
                                Text(shortcut.title)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.tileRaised))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                Spacer(minLength: 0)
            }
        })
    }

    private var clipboardTile: some View {
        Tile(action: { model.open(.clipboard) }) {
            TileLabel(icon: "list.clipboard", title: "Clipboard",
                      detail: history.items.isEmpty ? "Nothing yet" : "\(history.items.count) recent")
        }
    }

    private var filesTile: some View {
        Tile(action: { model.open(.files) }) {
            TileLabel(icon: "folder", title: "Files",
                      detail: files.received.first?.name ?? "Send and receive")
        }
    }
}
