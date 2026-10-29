import Foundation
import Network

/// Listens for the PC streamer. The PC reaches this port through the USB cable
/// (usbmux forwards its connection to the iPad's localhost).
///
/// Wire format, PC -> iPad: [u8 type][u32 big-endian length][payload]
final class StreamServer {
    static let port: UInt16 = 7000
    static let msgVideo: UInt8 = 1

    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onVideo: ((Data) -> Void)?

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

    private func accept(_ conn: NWConnection) {
        // only one PC at a time: a new connection replaces the old one
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
            if type == Self.msgVideo {
                self.onVideo?(data)
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
