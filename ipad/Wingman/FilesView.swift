import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Send photos, videos and files to the laptop's Downloads, and see, open and
/// share what the laptop sent (right-click > Send to > iPad on the laptop).
struct FilesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var files: FileTransfers
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var choosingFiles = false
    @State private var preparing = false
    @State private var preview: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TopBar(title: "Files", model: model)

            HStack(spacing: 16) {
                PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos])) {
                    bigButton("Send photos or videos", icon: "photo.on.rectangle.angled")
                }
                Button { choosingFiles = true } label: {
                    bigButton("Send files", icon: "folder")
                }
            }
            .buttonStyle(PressableStyle())
            .disabled(!model.connected || preparing)
            .opacity(model.connected ? 1 : 0.4)

            if preparing {
                ProgressView("Getting them ready…")
                    .tint(.white)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !files.transfers.isEmpty {
                        section("This session") {
                            ForEach(files.transfers) { TransferRow(transfer: $0) }
                        }
                    }
                    section("From the laptop") {
                        if files.received.isEmpty {
                            Text("Nothing yet. On the laptop, right-click a file > Show more options > "
                                 + "Send to > iPad (Wingman).")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(files.received) { file in
                            ReceivedRow(file: file, open: { preview = file.url }, delete: { files.delete(file) })
                        }
                    }
                    Text("What you send lands in the laptop's Downloads folder. Files from the laptop are "
                         + "also in the Files app: On My iPad > Wingman > From laptop. Other apps can "
                         + "send here too: Share > Wingman.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .screenPadding()
        .foregroundStyle(.white)
        .onAppear { files.refreshReceived() }
        .quickLookPreview($preview)
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            preparing = true
            Task.detached {
                let copies = urls.compactMap { FileTransfers.makeSendableCopy(of: $0) }
                await MainActor.run {
                    preparing = false
                    files.send(copies)
                }
            }
        }
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            preparing = true
            Task {
                let copies = await PhotoCopies.make(from: items)
                photoItems = []
                preparing = false
                files.send(copies)
            }
        }
    }

    private func bigButton(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.tile))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}

struct TransferRow: View {
    let transfer: FileTransfers.Transfer

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: transfer.direction == .toLaptop ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 6) {
                Text(transfer.name)
                    .lineLimit(1)
                switch transfer.state {
                case .waiting:
                    Text("Waiting…").font(.footnote).foregroundStyle(.secondary)
                case .moving:
                    ProgressView(value: transfer.progress)
                        .tint(Theme.on)
                    Text("\(bytes(transfer.moved)) of \(bytes(transfer.size))")
                        .font(.footnote).foregroundStyle(.secondary)
                case .done:
                    Text(transfer.direction == .toLaptop ? "In the laptop's Downloads" : "Received")
                        .font(.footnote).foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(reason).font(.footnote).foregroundStyle(Color.red)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.tile))
    }

    private var color: Color {
        switch transfer.state {
        case .done: return .green
        case .failed: return .red
        default: return Theme.text
        }
    }
}

struct ReceivedRow: View {
    let file: FileTransfers.ReceivedFile
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: open) {
                HStack(spacing: 14) {
                    Image(systemName: "doc.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name)
                            .lineLimit(1)
                            .foregroundStyle(.white)
                        HStack(spacing: 8) {
                            Text(bytes(file.size))
                            Text(file.date, format: .relative(presentation: .named))
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            ShareLink(item: file.url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
            }
            Button(action: delete) {
                Image(systemName: "trash")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.tile))
    }
}

private func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

/// "Received …" / "Saved in the laptop's Downloads …" for a few seconds, on any screen.
struct FileNoteBanner: View {
    @ObservedObject var files: FileTransfers

    var body: some View {
        VStack {
            if let note = files.note {
                Label(note, systemImage: "doc.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .padding(.top, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .allowsHitTesting(false)
        .animation(.easeOut, value: files.note)
        .onChange(of: files.note) { note in
            guard note != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if files.note == note { files.note = nil }
            }
        }
    }
}

/// Copies of photos and videos picked in PhotosPicker, as files that can be sent.
/// iPad photos are often HEIC, which Windows can't always open: those become JPEG.
enum PhotoCopies {
    static func make(from items: [PhotosPickerItem]) async -> [URL] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: Date())
        var copies: [URL] = []
        for (n, item) in items.enumerated() {
            let number = items.count > 1 ? " \(n + 1)" : ""
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { continue }
                let ext = movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension
                let named = movie.url.deletingLastPathComponent().appendingPathComponent("Video \(stamp)\(number).\(ext)")
                if (try? FileManager.default.moveItem(at: movie.url, to: named)) != nil {
                    copies.append(named)
                }
            } else if var data = try? await item.loadTransferable(type: Data.self) {
                var ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                if ["heic", "heif"].contains(ext.lowercased()),
                   let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) {
                    data = jpeg
                    ext = "jpg"
                }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let file = folder.appendingPathComponent("Photo \(stamp)\(number).\(ext)")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: file)
                    copies.append(file)
                } catch {
                    continue
                }
            }
        }
        return copies
    }
}

/// A video from PhotosPicker, delivered as a file (videos are too big for memory).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            // the picker's file is deleted after this returns: keep a copy, in its
            // own folder like FileTransfers.makeSendableCopy
            guard let copy = FileTransfers.makeSendableCopy(of: received.file) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return PickedMovie(url: copy)
        }
    }
}
