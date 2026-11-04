import SwiftUI

/// Buttons that run things on the laptop. They're kept on the laptop
/// (pc/shortcuts.user.json, the defaults in pc/shortcuts.json) and edited here:
/// Edit shows a + tile, arrows to move each one, and opens the editor on tap.
struct ShortcutsView: View {
    @ObservedObject var model: AppModel
    @State private var editing = false
    @State private var editor: Shortcut?  // the one being edited (a new one has an unused id)

    private let columns = [GridItem(.adaptive(minimum: isPhone ? 140 : 200), spacing: isPhone ? 12 : 20)]

    var body: some View {
        VStack(spacing: isPhone ? 14 : 28) {
            TopBar(title: "Shortcuts", model: model)
            HStack {
                Spacer()
                Button(editing ? "Done" : "Edit") { editing.toggle() }
                    .font(.title3.weight(.semibold))
                    .disabled(!model.connected)
            }
            if let error = model.videoError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color.red)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(model.shortcuts) { shortcut in
                        tile(shortcut)
                    }
                    if editing {
                        Button {
                            editor = Shortcut(id: UUID().uuidString, title: "", icon: "star", keys: ["ctrl", "c"])
                        } label: {
                            VStack(spacing: 14) {
                                Image(systemName: "plus")
                                    .font(.system(size: 40, weight: .semibold))
                                Text("New shortcut")
                                    .font(.headline)
                            }
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                                .strokeBorder(Theme.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8])))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                if model.shortcuts.isEmpty && !editing {
                    Text("No shortcuts yet. Tap Edit to add some.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 60)
                }
            }
        }
        .screenPadding()
        .foregroundStyle(.white)
        .sheet(item: $editor) { draft in
            ShortcutEditor(model: model, draft: draft,
                           isNew: !model.shortcuts.contains { $0.id == draft.id }) { result in
                var list = model.shortcuts
                switch result {
                case .save(let shortcut):
                    if let index = list.firstIndex(where: { $0.id == shortcut.id }) {
                        list[index] = shortcut
                    } else {
                        list.append(shortcut)
                    }
                case .delete(let id):
                    list.removeAll { $0.id == id }
                }
                model.saveShortcuts(list)
                editor = nil
            }
        }
    }

    private func tile(_ shortcut: Shortcut) -> some View {
        Button {
            if editing {
                editor = shortcut
            } else {
                model.run(shortcut)
            }
        } label: {
            VStack(spacing: 14) {
                ShortcutIcon(shortcut: shortcut, size: isPhone ? 30 : 40)
                    .foregroundStyle(Theme.text)
                Text(shortcut.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                if editing {
                    HStack(spacing: 28) {
                        moveButton(shortcut, by: -1, icon: "arrow.left")
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                        moveButton(shortcut, by: 1, icon: "arrow.right")
                    }
                    .font(.title3)
                }
            }
            .frame(maxWidth: .infinity, minHeight: isPhone ? 120 : 160)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(editing ? Theme.tileRaised : Theme.tile))
        }
        .buttonStyle(PressableStyle())
        .disabled(!model.connected)
    }

    private func moveButton(_ shortcut: Shortcut, by step: Int, icon: String) -> some View {
        Button {
            var list = model.shortcuts
            guard let index = list.firstIndex(of: shortcut), list.indices.contains(index + step) else { return }
            list.swapAt(index, index + step)
            model.saveShortcuts(list)
        } label: {
            Image(systemName: icon)
                .foregroundStyle(Theme.text)
        }
        .buttonStyle(.borderless)
    }
}

/// Make or change one shortcut: name, icon, and what it does on the laptop.
struct ShortcutEditor: View {
    enum Result {
        case save(Shortcut)
        case delete(String)
    }

    enum Kind: String, CaseIterable, Identifiable {
        case keys = "Keys", app = "App", website = "Website", command = "Command", lock = "Lock"
        var id: String { rawValue }
    }

    static let modifiers = ["win", "ctrl", "shift", "alt"]
    static let keyNames: [String] =
        (UInt8(ascii: "a")...UInt8(ascii: "z")).map { String(UnicodeScalar($0)) } + (0...9).map { "\($0)" }
        + (1...12).map { "f\($0)" }
        + ["tab", "esc", "enter", "space", "delete", "printscreen", "left", "right", "up", "down"]
    /// Symbols to choose from, grouped loosely: system, files, work, media, web, other.
    static let icons = [
        // system and windows
        "desktopcomputer", "laptopcomputer", "display", "macwindow", "square.grid.2x2", "rectangle.split.3x1",
        "uiwindow.split.2x1", "rectangle.on.rectangle", "camera.viewfinder", "crop", "lock.fill", "power",
        "moon.fill", "sun.max.fill", "gearshape.fill", "slider.horizontal.3", "keyboard", "command",
        "option", "magnifyingglass", "arrow.clockwise", "trash", "battery.100", "wifi", "printer.fill",
        // files and documents
        "folder.fill", "folder.badge.plus", "tray.full.fill", "archivebox.fill", "doc.fill", "doc.text.fill",
        "doc.on.clipboard", "list.bullet.clipboard", "note.text", "book.fill", "books.vertical.fill",
        "bookmark.fill", "paperclip", "externaldrive.fill", "icloud.fill", "arrow.down.circle.fill",
        // work and study
        "chevron.left.forwardslash.chevron.right", "terminal.fill", "curlybraces", "hammer.fill",
        "wrench.and.screwdriver.fill", "cpu", "memorychip", "chart.bar.xaxis", "chart.pie.fill",
        "tablecells", "function", "graduationcap.fill", "pencil.and.ruler.fill", "calendar", "clock.fill",
        "timer", "checklist", "list.bullet", "briefcase.fill", "lightbulb.fill", "brain.head.profile",
        // media and creative
        "music.note", "music.note.list", "headphones", "speaker.wave.2.fill", "mic.fill", "play.fill",
        "play.rectangle.fill", "video.fill", "film.fill", "tv.fill", "photo.fill", "camera.fill",
        "paintbrush.fill", "paintpalette.fill", "scribble", "wand.and.stars", "gamecontroller.fill",
        "dice.fill", "puzzlepiece.fill",
        // web and people
        "globe", "safari.fill", "link", "envelope.fill", "message.fill", "bubble.left.fill", "phone.fill",
        "video.bubble.left.fill", "person.fill", "person.2.fill", "cart.fill", "bag.fill", "creditcard.fill",
        "map.fill", "location.fill", "airplane", "car.fill", "tram.fill",
        // other
        "star.fill", "heart.fill", "flag.fill", "bell.fill", "bolt.fill", "flame.fill", "leaf.fill",
        "drop.fill", "cup.and.saucer.fill", "fork.knife", "house.fill", "building.2.fill", "sparkles",
        "app.badge", "square.and.arrow.up", "arrow.triangle.2.circlepath", "shield.fill", "key.fill",
    ]

    @ObservedObject var model: AppModel
    let isNew: Bool
    let done: (Result) -> Void

    @State private var id: String
    @State private var title: String
    @State private var icon: String
    @State private var kind: Kind
    @State private var held: Set<String>
    @State private var key: String
    @State private var appOpen: String
    @State private var url: String
    @State private var command: String
    @State private var pickingApp = false
    @State private var confirmingDelete = false
    @State private var useAppIcon: Bool  // an App shortcut shows the app's own icon
    @State private var appImage: String?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, draft: Shortcut, isNew: Bool, done: @escaping (Result) -> Void) {
        self.model = model
        self.isNew = isNew
        self.done = done
        _id = State(initialValue: draft.id)
        _title = State(initialValue: draft.title)
        _icon = State(initialValue: draft.icon)
        let keys = draft.keys ?? []
        _held = State(initialValue: Set(keys.filter { Self.modifiers.contains($0) }))
        _key = State(initialValue: keys.last { !Self.modifiers.contains($0) } ?? "c")
        let open = draft.open ?? ""
        let isWebsite = open.contains("://")
        _appOpen = State(initialValue: isWebsite ? "" : open)
        _url = State(initialValue: isWebsite ? open : "https://")
        _command = State(initialValue: draft.run ?? "")
        _useAppIcon = State(initialValue: draft.image != "")
        _appImage = State(initialValue: draft.image?.isEmpty == false ? draft.image : nil)
        _kind = State(initialValue: draft.keys != nil ? .keys : draft.lock == true ? .lock
                      : draft.run != nil ? .command : draft.open == nil ? .keys : isWebsite ? .website : .app)
    }

    private var shortcut: Shortcut {
        var s = Shortcut(id: id, title: title.trimmingCharacters(in: .whitespaces), icon: icon)
        switch kind {
        case .keys: s.keys = Self.modifiers.filter(held.contains) + [key]
        case .app:
            s.open = appOpen
            // nil: the laptop adds the icon when saving; "": keep the symbol
            s.image = useAppIcon ? (appImage ?? currentAppIcon) : ""
        case .website: s.open = url.trimmingCharacters(in: .whitespaces)
        case .command: s.run = command
        case .lock: s.lock = true
        }
        return s
    }

    /// The picked app's icon, once the laptop has sent it.
    private var currentAppIcon: String? {
        guard let icon = model.appIcons[appOpen], !icon.isEmpty else { return nil }
        return icon
    }

    private var canSave: Bool {
        guard !shortcut.title.isEmpty else { return false }
        switch kind {
        case .app: return !appOpen.isEmpty
        case .website: return url.count > 8
        case .command: return !command.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Screenshot", text: $title)
                }
                Section("Icon") {
                    if kind == .app {
                        Picker("Icon", selection: $useAppIcon) {
                            Text("App's own icon").tag(true)
                            Text("Symbol").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    if kind == .app && useAppIcon {
                        HStack(spacing: 14) {
                            if let picture = ShortcutIcon.image(appImage ?? currentAppIcon) {
                                Image(uiImage: picture).resizable().scaledToFit().frame(width: 48, height: 48)
                                Text("The app's own icon").foregroundStyle(Theme.secondary)
                            } else {
                                Image(systemName: "app.dashed").font(.title).frame(width: 48, height: 48)
                                Text(appOpen.isEmpty ? "Choose an app below" : "The laptop adds it when you save")
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                    } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], spacing: 12) {
                        ForEach(Self.icons, id: \.self) { name in
                            Button {
                                icon = name
                            } label: {
                                Image(systemName: name)
                                    .font(.title2)
                                    .frame(width: 48, height: 48)
                                    .foregroundStyle(icon == name ? Theme.onText : Theme.text)
                                    .background(RoundedRectangle(cornerRadius: 10)
                                        .fill(icon == name ? Theme.on : Theme.tileRaised))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 6)
                    }
                }
                Section("What it does on the laptop") {
                    Picker("Action", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    action
                }
                Section {
                    Button("Try it on the laptop") { model.tryShortcut(shortcut) }
                        .disabled(!canSave)
                    if !isNew {
                        Button("Delete shortcut", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "New shortcut" : "Edit shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { done(.save(shortcut)) }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("Delete “\(title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { done(.delete(id)) }
            }
            .sheet(isPresented: $pickingApp) {
                AppPicker(model: model) { app in
                    appOpen = app.open
                    appImage = nil  // a different app: its own icon
                    model.requestAppIcon(app.open)
                    if title.isEmpty { title = app.name }
                    pickingApp = false
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var action: some View {
        switch kind {
        case .keys:
            HStack {
                ForEach(Self.modifiers, id: \.self) { name in
                    Toggle(name.capitalized, isOn: Binding(
                        get: { held.contains(name) },
                        set: { if $0 { held.insert(name) } else { held.remove(name) } }))
                        .toggleStyle(.button)
                }
                Text("+")
                Picker("Key", selection: $key) {
                    ForEach(Self.keyNames, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Text((Self.modifiers.filter(held.contains) + [key]).map { $0.capitalized }.joined(separator: " + "))
                .foregroundStyle(.secondary)
        case .app:
            Button {
                pickingApp = true
            } label: {
                HStack {
                    Text(appName ?? (appOpen.isEmpty ? "Choose an app…" : appOpen))
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }
            TextField("…or a file or folder on the laptop, e.g. C:\\Users\\me\\Documents", text: $appOpen)
                .font(.callout)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .website:
            TextField("https://", text: $url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .command:
            TextField("e.g. code, notepad, or any command", text: $command)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text("Runs in the laptop's command prompt.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .lock:
            Text("Locks the laptop.")
                .foregroundStyle(.secondary)
        }
    }

    private var appName: String? {
        model.laptopApps?.first { $0.open == appOpen }?.name
    }
}

/// The laptop's Start menu apps, searchable.
struct AppPicker: View {
    @ObservedObject var model: AppModel
    let picked: (LaptopApp) -> Void
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Group {
                if let apps = model.laptopApps {
                    List(apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { app in
                        Button {
                            picked(app)
                        } label: {
                            HStack(spacing: 14) {
                                if let icon = ShortcutIcon.image(model.appIcons[app.open]) {
                                    Image(uiImage: icon).resizable().scaledToFit().frame(width: 32, height: 32)
                                } else {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Theme.tileRaised).frame(width: 32, height: 32)
                                }
                                Text(app.name).foregroundStyle(Theme.text)
                            }
                        }
                        .onAppear { model.requestAppIcon(app.open) }  // icons arrive as rows show
                    }
                    .searchable(text: $search, prompt: "Search the laptop's apps")
                } else {
                    ProgressView("Asking the laptop for its apps…")
                }
            }
            .navigationTitle("Apps on the laptop")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if model.laptopApps == nil { model.requestApps() }
        }
    }
}
