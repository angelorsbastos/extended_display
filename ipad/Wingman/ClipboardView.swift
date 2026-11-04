import SwiftUI

/// Clipboard history as its own screen, opened from the home screen.
struct ClipboardScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            TopBar(title: "Clipboard", model: model)
            ClipboardList(model: model, history: model.clipboardHistory, onPaste: nil)
        }
        .screenPadding()
        .foregroundStyle(.white)
    }
}

/// The quick panel over Extend and Mirror, without leaving them: the laptop's
/// controls, the shortcuts and the clipboard history. Opened by the small
/// floating button (Controls) or a four-finger tap (Clipboard). Pasting closes
/// it, so the laptop screen is visible again.
struct QuickPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Picker("Panel", selection: $model.panelTab) {
                        Text("Shortcuts").tag(AppModel.PanelTab.shortcuts)
                        Text("Controls").tag(AppModel.PanelTab.controls)
                        Text("Clipboard").tag(AppModel.PanelTab.clipboard)
                    }
                    .pickerStyle(.segmented)
                    Button {
                        model.showingClipboard = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.tileRaised))
                    }
                    .buttonStyle(PressableStyle())
                }
                switch model.panelTab {
                case .controls: controls
                case .shortcuts: shortcuts
                case .clipboard:
                    ClipboardList(model: model, history: model.clipboardHistory) {
                        model.showingClipboard = false
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(width: 420)
            .frame(maxHeight: .infinity)
            .background(Theme.background.opacity(0.96))
            .foregroundStyle(Theme.text)
        }
        .background(Color.black.opacity(0.3).onTapGesture { model.showingClipboard = false })
        .transition(.move(edge: .trailing))
    }

    private var controls: some View {
        VStack(spacing: Theme.gap) {
            HStack(spacing: Theme.gap) {
                SliderTile(icon: "speaker.wave.2.fill", value: model.controls?.volume) {
                    model.controls?.volume = $0
                    model.control("volume", $0)
                }
                SliderTile(icon: "sun.max.fill", value: model.controls?.brightness) {
                    model.controls?.brightness = $0
                    model.control("brightness", $0)
                }
            }
            .frame(height: 220)
            Tile(action: nil) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.nowPlaying?.title ?? "Not playing").font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(model.nowPlaying?.artist ?? "Music on the laptop").font(.system(size: 12))
                            .foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    mediaButton("backward.fill", "previous")
                    mediaButton(model.nowPlaying?.playing == true ? "pause.fill" : "play.fill", "play_pause")
                    mediaButton("forward.fill", "next")
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 84)
            Tile(style: model.soundOnIPad ? .on : .normal, action: { model.setSoundOnIPad(!model.soundOnIPad) }) {
                HStack {
                    Image(systemName: model.soundOnIPad ? "speaker.wave.2.fill" : "speaker.slash")
                    Text("Sound here").font(.system(size: 15, weight: .semibold))
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 64)
        }
    }

    private func mediaButton(_ icon: String, _ action: String) -> some View {
        Button {
            model.tap()
            model.media(action)
        } label: {
            Image(systemName: icon).font(.system(size: 19, weight: .semibold)).frame(width: 38, height: 44)
        }
        .buttonStyle(PressableStyle())
    }

    private var shortcuts: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(model.shortcuts) { shortcut in
                    Button {
                        model.tap()
                        model.run(shortcut)
                    } label: {
                        VStack(spacing: 8) {
                            ShortcutIcon(shortcut: shortcut, size: 22)
                            Text(shortcut.title).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 92)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.tile))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }
}

/// The items, newest first, each with Copy and Paste on laptop.
struct ClipboardList: View {
    @ObservedObject var model: AppModel
    @ObservedObject var history: ClipboardHistory
    /// Called after "Paste on laptop" (the panel closes itself with it).
    let onPaste: (() -> Void)?
    @State private var copied: UUID?

    var body: some View {
        if history.items.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Nothing copied yet")
                    .font(.title3.bold())
                Text("Copy text or an image on the laptop, or on the iPad and then come back to this app. "
                     + "The last \(ClipboardHistory.limit) things show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(history.items) { item in
                        row(item)
                    }
                    Button("Clear history", role: .destructive) { history.clear() }
                        .padding(.top, 8)
                }
            }
        }
    }

    private func row(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let text = item.text {
                Text(text)
                    .font(.body)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let image = history.image(of: item) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 10) {
                Label(item.source == .laptop ? "Laptop" : "iPad",
                      systemImage: item.source == .laptop ? "laptopcomputer" : "ipad.landscape")
                Text(item.date, format: .relative(presentation: .named))
                Spacer()
                Button {
                    history.remove(item)
                } label: {
                    Image(systemName: "trash")
                }
                .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    model.copy(item)
                    copied = item.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copied == item.id { copied = nil }
                    }
                } label: {
                    Label(copied == item.id ? "Copied" : "Copy",
                          systemImage: copied == item.id ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    model.copy(item, paste: true)
                    onPaste?()
                } label: {
                    Label("Paste on laptop", systemImage: "arrow.right.doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.connected)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.tile))
    }
}
