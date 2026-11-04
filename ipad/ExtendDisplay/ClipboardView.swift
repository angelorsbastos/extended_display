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

/// Clipboard history over the video (four-finger tap), without leaving Extend
/// or Mirror. Pasting closes it, so the laptop screen is visible again.
struct ClipboardPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Clipboard", systemImage: "list.clipboard")
                        .font(.title2.bold())
                    Spacer()
                    Button {
                        model.showingClipboard = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                }
                ClipboardList(model: model, history: model.clipboardHistory) {
                    model.showingClipboard = false
                }
            }
            .padding(24)
            .frame(width: 420)
            .frame(maxHeight: .infinity)
            .background(Rectangle().fill(.ultraThinMaterial))
            .foregroundStyle(.white)
        }
        .background(Color.black.opacity(0.3).onTapGesture { model.showingClipboard = false })
        .transition(.move(edge: .trailing))
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
