import Foundation
import Network

/// Listens for the laptop. The laptop reaches this port through the USB cable
/// (usbmux forwards its connection to the iPad's localhost).
/// All callbacks run on the server's own queue, not the main thread.
final class StreamServer {
    static let port: UInt16 = 7000

    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onVideo: ((Data) -> Void)?
    var onMessage: ((LaptopMessage) -> Void)?

    private let queue = DispatchQueue(label: "stream-server")
    private var listener: NWListener?
    private var connection: NWConnection?

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp),
                                      on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Send a JSON message to the laptop (ignored when it isn't connected).
    func send(json object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        let n = UInt32(body.count)
        var frame = Data([MessageType.json.rawValue,
                          UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                          UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
        frame.append(body)
        queue.async { [weak self] in
            self?.connection?.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    private func accept(_ conn: NWConnection) {
        // only one laptop at a time: a new connection replaces the old one
        connection?.cancel()
        connection = conn
        conn.start(queue: queue)
        onConnected?()
        readHeader(conn)
    }

    private func readHeader(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, _, error in
            guard let self, let data, data.count == 5, error == nil else {
                self?.close(conn)
                return
            }
            let bytes = [UInt8](data)
            let length = bytes[1...4].reduce(0) { $0 << 8 | Int($1) }
            self.readBody(conn, type: bytes[0], length: length)
        }
    }

    private func readBody(_ conn: NWConnection, type: UInt8, length: Int) {
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, let data, data.count == length, error == nil else {
                self?.close(conn)
                return
            }
            switch MessageType(rawValue: type) {
            case .video:
                self.onVideo?(data)
            case .json:
                if let message = LaptopMessage.decode(data) {
                    self.onMessage?(message)
                }
            case nil:
                break
            }
            self.readHeader(conn)
        }
    }

    private func close(_ conn: NWConnection) {
        conn.cancel()
        // ignore stale connections that were already replaced by a newer one
        guard conn === connection else { return }
        connection = nil
        onDisconnected?()
    }
}
