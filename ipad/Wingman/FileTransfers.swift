import Combine
import Foundation

/// Files between the iPad and the laptop (the other side is pc/files.py).
///
/// Wire, either direction: file_start {id, name, size}, then pieces as message
/// type 5 ([u32 id][bytes]), then file_end {id}. The receiver answers
/// file_saved {id, name} or file_failed {id, message}.
///
/// - iPad -> laptop: one file at a time, from a copy in the temporary folder
///   (photos, Files, "Open in"); it lands in the laptop's Downloads.
/// - laptop -> iPad: saved in Documents/From laptop, which the Files app shows
///   under On My iPad > Wingman.
///
/// The transfer work happens on its own queue; published state changes on the
/// main thread only.
final class FileTransfers: ObservableObject {
    enum Direction { case toLaptop, fromLaptop }

    enum State: Equatable {
        case waiting, moving, done, failed(String)
    }

    struct Transfer: Identifiable, Equatable {
        let id: UUID
        let name: String
        let direction: Direction
        let size: Int64
        var moved: Int64 = 0
        var state: State = .waiting
        var progress: Double { size > 0 ? Double(moved) / Double(size) : 1 }
    }

    struct ReceivedFile: Identifiable, Equatable {
        let url: URL
        let size: Int64
        let date: Date
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    static let chunk = 64 * 1024

    @Published private(set) var transfers: [Transfer] = []  // this session's, newest first
    @Published private(set) var received: [ReceivedFile] = []
    /// A file from the laptop was saved here (AppModel puts it on the clipboard).
    var onReceived: ((URL) -> Void)?
    /// A short note when something finished (e.g. a file arrived), for a banner.
    @Published var note: String?

    let folder: URL
    private let work = DispatchQueue(label: "file-transfers")
    private weak var server: StreamServer?

    // on `work` only
    private var outbox: [(transfer: UUID, file: URL)] = []
    private var sending: (transfer: UUID, wireId: UInt32, handle: FileHandle, file: URL)?
    private var nextWireId: UInt32 = 1
    private var waitingForSave: [UInt32: UUID] = [:]  // sent, laptop hasn't confirmed yet
    private var incoming: [Int: (transfer: UUID, handle: FileHandle, part: URL, final: URL, size: Int64, got: Int64)] = [:]

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = documents.appendingPathComponent("From laptop", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        refreshReceived()
    }

    func attach(_ server: StreamServer) {
        self.server = server
    }

    // MARK: sending

    /// Send files to the laptop. They must be copies this class may delete when done
    /// (see makeSendableCopy).
    func send(_ files: [URL]) {
        for file in files {
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let transfer = Transfer(id: UUID(), name: file.lastPathComponent, direction: .toLaptop, size: size)
            DispatchQueue.main.async { self.transfers.insert(transfer, at: 0) }
            work.async {
                self.outbox.append((transfer.id, file))
                self.sendNextFile()
            }
        }
    }

    /// Copy a file from elsewhere (Files, another app) into the temporary folder,
    /// under `name`, so it can be sent later. Handles security-scoped URLs.
    static func makeSendableCopy(of url: URL, name: String? = nil) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let copy = folder.appendingPathComponent(name ?? url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    private func sendNextFile() {
        guard sending == nil, !outbox.isEmpty, let server else { return }
        let (transferId, file) = outbox.removeFirst()
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            finish(transferId, .failed("Couldn't read the file."))
            cleanUp(file)
            sendNextFile()
            return
        }
        let wireId = nextWireId
        nextWireId += 1
        sending = (transferId, wireId, handle, file)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        server.send(json: ["type": "file_start", "id": Int(wireId), "name": file.lastPathComponent, "size": size])
        update(transferId) { $0.state = .moving }
        sendNextChunk()
    }

    private func sendNextChunk() {
        guard let current = sending, let server else { return }
        let piece = (try? current.handle.read(upToCount: Self.chunk)) ?? nil
        guard let piece, !piece.isEmpty else {
            // all of it went out: the laptop confirms with file_saved
            try? current.handle.close()
            server.send(json: ["type": "file_end", "id": Int(current.wireId)])
            waitingForSave[current.wireId] = current.transfer
            cleanUp(current.file)
            sending = nil
            sendNextFile()
            return
        }
        var message = withUnsafeBytes(of: current.wireId.bigEndian) { Data($0) }
        message.append(piece)
        server.send(.file, message) { [weak self] connected in
            self?.work.async {
                guard let self, self.sending?.wireId == current.wireId else { return }
                guard connected else {
                    self.failSending("The laptop disconnected.")
                    return
                }
                let moved = Int64(piece.count)
                self.update(current.transfer) { $0.moved += moved }
                self.sendNextChunk()
            }
        }
    }

    private func failSending(_ reason: String) {
        if let current = sending {
            try? current.handle.close()
            cleanUp(current.file)
            finish(current.transfer, .failed(reason))
            sending = nil
        }
        for (transfer, file) in outbox {
            cleanUp(file)
            finish(transfer, .failed(reason))
        }
        outbox.removeAll()
        for transfer in waitingForSave.values {
            finish(transfer, .failed(reason))
        }
        waitingForSave.removeAll()
    }

    private func cleanUp(_ file: URL) {
        // makeSendableCopy puts each copy in its own folder
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    // MARK: messages from the laptop (called on the server's queue)

    func handle(_ message: LaptopMessage) {
        work.async {
            switch message.type {
            case "file_start":
                self.startReceiving(message)
            case "file_end":
                self.endReceiving(message.id)
            case "file_cancel":
                self.dropIncoming(message.id)
            case "file_saved":
                if let id = message.id, let transfer = self.waitingForSave.removeValue(forKey: UInt32(id)) {
                    self.finish(transfer, .done)
                    self.show("Saved in the laptop's Downloads as “\(message.name ?? "")”")
                }
            case "file_failed":
                if let id = message.id, let transfer = self.waitingForSave.removeValue(forKey: UInt32(id)) {
                    self.finish(transfer, .failed(message.message ?? "The laptop couldn't save it."))
                }
            default:
                break
            }
        }
    }

    func receive(_ payload: Data) {
        work.async {
            guard payload.count >= 4 else { return }
            let id = payload.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard var current = self.incoming[id] else { return }
            let piece = payload.dropFirst(4)
            do {
                try current.handle.write(contentsOf: piece)
            } catch {
                self.dropIncoming(id, reason: "Couldn't save it: \(error.localizedDescription)")
                return
            }
            current.got += Int64(piece.count)
            self.incoming[id] = current
            let moved = current.got
            self.update(current.transfer) { $0.moved = moved }
        }
    }

    /// The laptop disconnected: whatever was moving won't finish.
    func disconnected() {
        work.async {
            self.failSending("The laptop disconnected.")
            for id in self.incoming.keys {
                self.dropIncoming(id, reason: "The laptop disconnected.")
            }
        }
    }

    private func startReceiving(_ message: LaptopMessage) {
        guard let id = message.id else { return }
        let name = Self.safeName(message.name ?? "file")
        let final = uniqueURL(for: name)
        let part = final.appendingPathExtension("part")
        let transfer = Transfer(id: UUID(), name: final.lastPathComponent, direction: .fromLaptop,
                                size: message.size ?? 0, state: .moving)
        DispatchQueue.main.async { self.transfers.insert(transfer, at: 0) }
        guard FileManager.default.createFile(atPath: part.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: part) else {
            finish(transfer.id, .failed("Couldn't create the file on the iPad."))
            return
        }
        incoming[id] = (transfer.id, handle, part, final, message.size ?? 0, 0)
    }

    private func endReceiving(_ id: Int?) {
        guard let id, let current = incoming.removeValue(forKey: id) else { return }
        try? current.handle.close()
        guard current.got == current.size else {
            try? FileManager.default.removeItem(at: current.part)
            finish(current.transfer, .failed("Only part of the file arrived."))
            return
        }
        do {
            try FileManager.default.moveItem(at: current.part, to: current.final)
        } catch {
            finish(current.transfer, .failed("Couldn't save it: \(error.localizedDescription)"))
            return
        }
        server?.send(json: ["type": "file_saved", "id": id, "name": current.final.lastPathComponent])
        finish(current.transfer, .done)
        let saved = current.final
        DispatchQueue.main.async { self.onReceived?(saved) }
        show("Received “\(current.final.lastPathComponent)” from the laptop")
        DispatchQueue.main.async { self.refreshReceived() }
    }

    private func dropIncoming(_ id: Int?, reason: String = "The laptop cancelled it.") {
        guard let id, let current = incoming.removeValue(forKey: id) else { return }
        try? current.handle.close()
        try? FileManager.default.removeItem(at: current.part)
        finish(current.transfer, .failed(reason))
    }

    private func uniqueURL(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: url.appendingPathExtension("part").path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    /// Just a file name: no folders, nothing hidden.
    private static func safeName(_ name: String) -> String {
        let last = name.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? ""
        let trimmed = last.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return trimmed.isEmpty ? "file" : String(trimmed.prefix(200))
    }

    // MARK: received files (main thread)

    func refreshReceived() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        received = urls.filter { $0.pathExtension != "part" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return ReceivedFile(url: url, size: Int64(values?.fileSize ?? 0),
                                date: values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }
    }

    func delete(_ file: ReceivedFile) {
        try? FileManager.default.removeItem(at: file.url)
        refreshReceived()
    }

    // MARK: helpers

    private func update(_ id: UUID, _ change: @escaping (inout Transfer) -> Void) {
        DispatchQueue.main.async {
            if let index = self.transfers.firstIndex(where: { $0.id == id }) {
                change(&self.transfers[index])
            }
        }
    }

    private func finish(_ id: UUID, _ state: State) {
        update(id) { transfer in
            transfer.state = state
            if state == .done { transfer.moved = transfer.size }
        }
    }

    private func show(_ text: String) {
        DispatchQueue.main.async { self.note = text }
    }
}
