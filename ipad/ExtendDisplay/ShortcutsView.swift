import SwiftUI

/// The buttons come from pc/shortcuts.json on the laptop, sent when it connects.
struct ShortcutsView: View {
    @ObservedObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 20)]

    var body: some View {
        VStack(spacing: 28) {
            TopBar(title: "Shortcuts", model: model)

            if model.shortcuts.isEmpty {
                Spacer()
                Text("No shortcuts yet. Add them in pc/shortcuts.json on the laptop.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(model.shortcuts) { shortcut in
                            Button {
                                model.run(shortcut)
                            } label: {
                                VStack(spacing: 14) {
                                    Image(systemName: shortcut.icon)
                                        .font(.system(size: 40, weight: .semibold))
                                        .foregroundStyle(Color.orange)
                                    Text(shortcut.title)
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                }
                                .frame(maxWidth: .infinity, minHeight: 160)
                                .background(RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(0.08)))
                            }
                            .buttonStyle(PressableStyle())
                            .disabled(!model.connected)
                        }
                    }
                }
            }
        }
        .padding(40)
    }
}
