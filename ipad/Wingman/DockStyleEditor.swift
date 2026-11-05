import SwiftUI

/// Settings' "Dock styles" section: every style, the default marked; tap one
/// to edit it, or make a new one (a copy of the default to change).
struct DockStylesSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = DockStyleStore.shared
    @State private var editing: DockStyle?
    @State private var confirmingRestore = false

    var body: some View {
        Section {
            ForEach(store.styles) { style in
                Button {
                    editing = style
                } label: {
                    HStack {
                        Text(style.name).foregroundStyle(Theme.text)
                        Spacer()
                        if style.id == store.defaultId {
                            Text("Default").font(.footnote).foregroundStyle(Theme.accent)
                        }
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.secondary)
                    }
                }
            }
            Button {
                let base = store.styles.first { $0.id == store.defaultId } ?? store.styles[0]
                var copy = store.duplicate(base)
                copy.name = "My style"
                store.update(copy)
                editing = copy
            } label: {
                Label("New style", systemImage: "plus")
            }
            Button("Restore the ready-made styles", role: .destructive) { confirmingRestore = true }
        } header: {
            Text("Dock styles")
        } footer: {
            Text("The Dock opens with the default style; slide sideways on the Dock to switch to the others.")
        }
        .sheet(item: $editing) { style in
            DockStyleEditor(model: model, style: style)
        }
        .confirmationDialog("Replace your styles with the four ready-made ones?",
                            isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("Restore", role: .destructive) { store.restoreBuiltIn() }
        }
    }
}

/// Editing one style, with a live preview of the Dock on top.
struct DockStyleEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = DockStyleStore.shared
    @State var style: DockStyle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                Form {
                    Section {
                        TextField("Name", text: $style.name)
                    }
                    clockSection
                    colourSection
                    showSection
                    layoutSection
                    Section {
                        Button {
                            store.defaultId = style.id
                        } label: {
                            Label(style.id == store.defaultId ? "This is the default style" : "Make it the default",
                                  systemImage: style.id == store.defaultId ? "checkmark.circle.fill" : "checkmark.circle")
                        }
                        .disabled(style.id == store.defaultId)
                        Button {
                            store.duplicate(style)
                            dismiss()
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        Button(role: .destructive) {
                            store.delete(style)
                            dismiss()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(store.styles.count <= 1)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .background(Theme.background)
            .navigationTitle(style.name.isEmpty ? "Style" : style.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .tint(Theme.accent)
        }
        .preferredColorScheme(.dark)
        .onChange(of: style) { store.update($0) }
    }

    // MARK: preview

    /// The Dock as this style draws it, scaled down (on its side, like it usually stands).
    private var preview: some View {
        let base = isPhone ? CGSize(width: 852, height: 393) : CGSize(width: 1180, height: 820)
        return GeometryReader { geometry in
            let scale = geometry.size.width / base.width
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ZStack {
                    DockBackground(style: style, night: false, songColour: Color(hue: 0.6, saturation: 0.6, brightness: 0.9),
                                   artwork: model.artwork, size: base)
                    DockFace(model: model, timer: model.dockTimer, style: style, night: false, date: context.date,
                             size: base, shortcuts: Array(model.shortcuts.prefix(6)), preview: true)
                }
                .frame(width: base.width, height: base.height)
                .scaleEffect(scale, anchor: .topLeading)
            }
            .frame(width: geometry.size.width, height: base.height * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        }
        .aspectRatio(base.width / base.height, contentMode: .fit)
        .frame(maxWidth: 560)
    }

    // MARK: sections

    private var clockSection: some View {
        Section("Clock") {
            Picker("Clock", selection: $style.clock) {
                Text("Digital").tag(DockStyle.Clock.digital)
                Text("Flip").tag(DockStyle.Clock.flip)
                Text("Analog").tag(DockStyle.Clock.analog)
            }
            .pickerStyle(.segmented)
            labeledSlider("Size", value: $style.clockSize, range: 0.6...1.4)
            if style.clock != .analog {
                Picker("Thickness", selection: $style.weight) {
                    Text("Thin").tag(DockStyle.Weight.thin)
                    Text("Light").tag(DockStyle.Weight.light)
                    Text("Regular").tag(DockStyle.Weight.regular)
                    Text("Semibold").tag(DockStyle.Weight.semibold)
                    Text("Bold").tag(DockStyle.Weight.bold)
                }
                Toggle("24-hour", isOn: $style.use24h)
            }
            Toggle("Seconds", isOn: $style.showSeconds)
        }
    }

    private var colourSection: some View {
        Section {
            ColorPicker("Text", selection: colour(\.textColor), supportsOpacity: false)
            ColorPicker("Accent", selection: colour(\.accentColor), supportsOpacity: false)
            Picker("Background", selection: $style.background) {
                Text("Black").tag(DockStyle.Background.black)
                Text("Glow in the song's colour").tag(DockStyle.Background.glow)
                Text("The song's cover, blurred").tag(DockStyle.Background.album)
                Text("One colour").tag(DockStyle.Background.solid)
            }
            if style.background == .solid {
                ColorPicker("Background colour", selection: colour(\.backgroundColor), supportsOpacity: false)
            }
        } header: {
            Text("Colours and background")
        } footer: {
            Text("The accent colours the music bars, the volume line, the timer and the second hand. "
                 + "At night every style turns dim red.")
        }
    }

    private var showSection: some View {
        Section("What shows") {
            Toggle("Date", isOn: $style.showDate)
            Toggle("Song", isOn: $style.showSong)
            Toggle("Volume line", isOn: $style.showVolume).disabled(!style.showSong)
            Toggle("Timer", isOn: $style.showTimer)
            Toggle("Shortcuts", isOn: $style.showShortcuts)
        }
    }

    private var layoutSection: some View {
        Section("Layout") {
            Picker("Layout", selection: $style.layout) {
                Text("Side by side").tag(DockStyle.Layout.side)
                Text("Centred").tag(DockStyle.Layout.centred)
                Text("Stacked").tag(DockStyle.Layout.stacked)
            }
            .pickerStyle(.segmented)
            if style.showShortcuts {
                labeledSlider("Shortcut size", value: $style.shortcutSize, range: 0.7...1.3)
            }
        }
    }

    // MARK: helpers

    private func colour(_ key: WritableKeyPath<DockStyle, String>) -> Binding<Color> {
        Binding(get: { Color(hex: style[keyPath: key]) }, set: { style[keyPath: key] = $0.hex })
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
        }
    }
}
