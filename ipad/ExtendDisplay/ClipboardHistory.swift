import UIKit

/// One thing that was copied, on the iPad or on the laptop.
struct ClipItem: Codable, Identifiable, Equatable {
    enum Source: String, Codable { case iPad, laptop }

    let id: UUID
    var date: Date
    let source: Source
    let text: String?       // set for text
    let imageFile: String?  // set for images: a PNG in the history folder

    var isImage: Bool { imageFile != nil }
}

/// The last few things copied on either side, newest first. Everything the
/// clipboard sync moves passes through the iPad, so it is all recorded here.
/// Kept in Application Support/ClipboardHistory (a JSON list plus the images).
/// Main thread only.
final class ClipboardHistory: ObservableObject {
    static let limit = 10

    @Published private(set) var items: [ClipItem] = []

    private let folder: URL
    private var listFile: URL { folder.appendingPathComponent("history.json") }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("ClipboardHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: listFile),
           let saved = try? JSONDecoder().decode([ClipItem].self, from: data) {
            items = saved
        }
    }

    func addText(_ text: String, from source: ClipItem.Source) {
        guard !text.isEmpty else { return }
        // copying the same thing again just moves it to the top
        if let index = items.firstIndex(where: { $0.text == text }) {
            var item = items.remove(at: index)
            item.date = Date()
            items.insert(item, at: 0)
        } else {
            items.insert(ClipItem(id: UUID(), date: Date(), source: source, text: text, imageFile: nil), at: 0)
        }
        trimAndSave()
    }

    func addImage(png: Data, from source: ClipItem.Source) {
        let id = UUID()
        let name = "\(id.uuidString).png"
        guard (try? png.write(to: folder.appendingPathComponent(name))) != nil else { return }
        items.insert(ClipItem(id: id, date: Date(), source: source, text: nil, imageFile: name), at: 0)
        trimAndSave()
    }

    /// Bring an item back to the top (it was just copied or pasted again).
    func touch(_ item: ClipItem) {
        guard let index = items.firstIndex(of: item) else { return }
        var moved = items.remove(at: index)
        moved.date = Date()
        items.insert(moved, at: 0)
        save()
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        deleteImage(of: item)
        save()
    }

    func clear() {
        items.forEach { deleteImage(of: $0) }
        items.removeAll()
        save()
    }

    func png(of item: ClipItem) -> Data? {
        item.imageFile.flatMap { try? Data(contentsOf: folder.appendingPathComponent($0)) }
    }

    func image(of item: ClipItem) -> UIImage? {
        png(of: item).flatMap(UIImage.init(data:))
    }

    private func trimAndSave() {
        while items.count > Self.limit {
            deleteImage(of: items.removeLast())
        }
        save()
    }

    private func deleteImage(of item: ClipItem) {
        if let file = item.imageFile {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: listFile, options: .atomic)
        }
    }
}
