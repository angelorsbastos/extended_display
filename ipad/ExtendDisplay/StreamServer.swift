import Foundation
import Network
import UIKit

/// Waits for the laptop, over two ports:
/// - USB (7000): the laptop reaches it through the cable (usbmux forwards to the
///   iPad's localhost). Unencrypted, so it only accepts localhost connections.
/// - Wi-Fi (7001): announced over Bonjour. A connection must log in with the
///   pairing key (pairing first, with the 6-digit code, if there is none), and
///   is encrypted from then on. See Pairing.swift and pc/secure.py.
///
/// Wire format: [u8 type][u32 big-endian length][payload]. All callbacks run on
/// the server's own queue, not the main thread.
final class StreamServer {
    static let usbPort: UInt16 = 7000
    static let wifiPort: UInt16 = 7001
    static let bonjourType = "_extenddisplay._tcp"

    var onConnected: ((Transport) -> Void)?
    var onDisconnected: (() -> Void)?
    var onVideo: ((Data) -> Void)?
    var onMessage: ((LaptopMessage) -> Void)?
    /// A laptop wants to pair over Wi-Fi: show a screen where the user types its code.
    var onPairingRequest: ((String) -> Void)?
    /// Pairing is over: nil when it worked, otherwise what went wrong.
    var onPairingEnded: ((String?) -> Void)?
    /// What the Wi-Fi side is doing, for the home screen.
    var onWifiState: ((WifiState) -> Void)?

    enum WifiState: Equatable {
        case starting
        case visible(name: String)  // announced on the network, laptops can find it
        case noPermission           // Settings > Privacy & Security > Local Network is off
        case problem(String)
    }

    /// iPadOS refuses Bonjour with this DNS-SD error when Local Network access is off.
    private static let policyDenied: Int32 = -65570  // kDNSServiceErr_PolicyDenied

    private let queue = DispatchQueue(label: "stream-server")
    private let deviceName = UIDevice.current.name
    private var listeners: [UInt16: NWListener] = [:]
    private var active: Link?       // the connection the app is using
    private var pairingLink: Link?  // a Wi-Fi connection waiting for the typed code

    private final class Link {
        let connection: NWConnection
        let transport: Transport
        var ready: Bool  // set up (cable: right away; Wi-Fi: after login)
        var cipher: Cipher?
        var pairing: PairingExchange?
        var login: (key: Data, laptopNonce: Data, ipadNonce: Data)?

        init(_ connection: NWConnection, _ transport: Transport) {
            self.connection = connection
            self.transport = transport
            ready = transport == .usb
        }
    }

    func start() throws {
        try listen(port: Self.usbPort, transport: .usb)
        try listen(port: Self.wifiPort, transport: .wifi)
    }

    /// Send a JSON message to the laptop (ignored when it isn't connected).
    func send(json object: [String: Any]) {
        queue.async { [weak self] in
            guard let self, let link = self.active else { return }
            self.sendJSON(object, on: link)
        }
    }

    /// The user typed the code shown on the laptop.
    func submitPairingCode(_ typed: String) {
        queue.async { [weak self] in
            guard let self, let link = self.pairingLink, let exchange = link.pairing,
                  let key = exchange.key, let code = exchange.code else { return }
            self.pairingLink = nil
            if typed == code {
                self.sendJSON(["type": "pair_confirm",
                               "mac": Crypto.mac(key, "ipad confirm").base64EncodedString()], on: link)
            } else {
                self.onPairingEnded?("That code was wrong. The laptop will offer pairing again in a minute.")
                self.sendJSON(["type": "pair_failed", "message": "wrong code"], on: link) { [weak self] in
                    self?.close(link)
                }
            }
        }
    }

    func cancelPairing() {
        queue.async { [weak self] in
            guard let self, let link = self.pairingLink else { return }
            self.pairingLink = nil
            self.onPairingEnded?("Pairing cancelled.")
            self.sendJSON(["type": "pair_failed", "message": "pairing was cancelled on the iPad"], on: link) {
                [weak self] in self?.close(link)
            }
        }
    }

    // MARK: listening

    private func listen(port: UInt16, transport: Transport) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if transport == .usb {
            // the cable arrives on localhost; nothing on the network may reach this
            // unencrypted port
            parameters.requiredInterfaceType = .loopback
        }
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        if transport == .wifi {
            listener.service = NWListener.Service(
                name: nil, type: Self.bonjourType, domain: nil,
                txtRecord: NWTXTRecord(["id": PairingStore.ipadId, "name": deviceName]))
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, transport) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .waiting(let error), .failed(let error):
                if transport == .wifi {
                    if case .dns(let code) = error, code == Self.policyDenied {
                        self.onWifiState?(.noPermission)
                    } else {
                        self.onWifiState?(.problem(error.localizedDescription))
                    }
                }
                // e.g. after the app was suspended for a long time: start listening again
                if case .failed = state {
                    self.queue.asyncAfter(deadline: .now() + 2) {
                        self.listeners[port]?.cancel()
                        try? self.listen(port: port, transport: transport)
                    }
                }
            default:
                break
            }
        }
        if transport == .wifi {
            onWifiState?(.starting)
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                if case .add(let endpoint) = change, case .service(let name, _, _, _) = endpoint {
                    self?.onWifiState?(.visible(name: name))
                }
            }
        }
        listener.start(queue: queue)
        listeners[port] = listener
    }

    private func accept(_ connection: NWConnection, _ transport: Transport) {
        let link = Link(connection, transport)
        connection.start(queue: queue)
        sendJSON(["type": "identity", "ipad_id": PairingStore.ipadId, "ipad_name": deviceName,
                  "paired_laptops": PairingStore.laptopIds], on: link)
        if link.ready {
            activate(link)
        }
        readHeader(link)
    }

    /// Only one laptop connection at a time: a newly ready one replaces the old one.
    private func activate(_ link: Link) {
        let previous = active
        active = link
        if let previous, previous !== link {
            previous.connection.cancel()
        }
        onConnected?(link.transport)
    }

    // MARK: reading

    private func readHeader(_ link: Link) {
        link.connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, _, error in
            guard let self, let data, data.count == 5, error == nil else {
                self?.close(link)
                return
            }
            let bytes = [UInt8](data)
            let length = bytes[1...4].reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= 64 << 20 else {
                self.close(link)
                return
            }
            self.readBody(link, type: bytes[0], length: length)
        }
    }

    private func readBody(_ link: Link, type: UInt8, length: Int) {
        link.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, let data, data.count == length, error == nil else {
                self?.close(link)
                return
            }
            var type = type
            var payload = data
            if let cipher = link.cipher {
                // an encrypted link accepts nothing else, and nothing that fails its check
                guard type == MessageType.sealed.rawValue, let opened = try? cipher.open(data),
                      let inner = opened.first else {
                    self.close(link)
                    return
                }
                type = inner
                payload = Data(opened.dropFirst())
            } else if type == MessageType.sealed.rawValue {
                self.close(link)
                return
            }
            if self.handle(link, type: type, payload: payload) {
                self.readHeader(link)
            }
        }
    }

    /// Returns false once the link has been closed.
    private func handle(_ link: Link, type: UInt8, payload: Data) -> Bool {
        guard link.ready else {
            guard type == MessageType.json.rawValue,
                  let message = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
                close(link)
                return false
            }
            return setUp(link, message)
        }
        switch MessageType(rawValue: type) {
        case .video:
            if link === active { onVideo?(payload) }
        case .json:
            if link.transport == .usb,
               let message = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
               message["type"] as? String == "pair_usb" {
                // the cable is trusted: just keep the key the laptop sends
                if let laptopId = message["laptop_id"] as? String, let key = Data(base64: message["key"]) {
                    PairingStore.save(key: key, for: laptopId)
                    sendJSON(["type": "pair_usb_ok"], on: link)
                }
            } else if link === active, let message = LaptopMessage.decode(payload) {
                onMessage?(message)
            }
        default:
            break
        }
        return true
    }

    /// Pairing and login on a Wi-Fi connection (the order is fixed by secure.py).
    private func setUp(_ link: Link, _ message: [String: Any]) -> Bool {
        switch message["type"] as? String {
        case "pair_hello":
            guard let laptopId = message["laptop_id"] as? String else { break }
            let exchange = PairingExchange(laptopId: laptopId,
                                           laptopName: message["laptop_name"] as? String ?? "your laptop")
            link.pairing = exchange
            sendJSON(["type": "pair_commit", "ipad_id": PairingStore.ipadId, "ipad_name": deviceName,
                      "commit": exchange.commitment.base64EncodedString()], on: link)
            return true

        case "pair_key":
            guard let exchange = link.pairing, let laptopPublic = Data(base64: message["public"]),
                  let laptopNonce = Data(base64: message["nonce"]),
                  (try? exchange.receiveLaptopKey(laptopPublic, nonce: laptopNonce)) != nil else { break }
            sendJSON(["type": "pair_reveal", "public": exchange.publicKey.base64EncodedString(),
                      "nonce": exchange.nonce.base64EncodedString()], on: link)
            pairingLink?.connection.cancel()
            pairingLink = link
            onPairingRequest?(exchange.laptopName)
            return true

        case "pair_done":
            guard let exchange = link.pairing, let key = exchange.key,
                  Crypto.matches(Data(base64: message["mac"]), Crypto.mac(key, "laptop confirm")) else { break }
            PairingStore.save(key: key, for: exchange.laptopId)
            link.pairing = nil
            onPairingEnded?(nil)
            return true  // the login follows on this same connection

        case "auth_hello":
            guard let laptopId = message["laptop_id"] as? String,
                  let laptopNonce = Data(base64: message["nonce"]) else { break }
            guard let key = PairingStore.key(for: laptopId) else {
                // e.g. the app was reinstalled: tells the laptop to pair again
                sendJSON(["type": "auth_unknown"], on: link) { [weak self] in self?.close(link) }
                return false
            }
            let ipadNonce = Crypto.random(16)
            link.login = (key, laptopNonce, ipadNonce)
            sendJSON(["type": "auth_reply", "nonce": ipadNonce.base64EncodedString(),
                      "mac": Crypto.mac(key, "ipad auth", laptopNonce, ipadNonce).base64EncodedString()],
                     on: link)
            return true

        case "auth_finish":
            guard let login = link.login,
                  Crypto.matches(Data(base64: message["mac"]),
                                 Crypto.mac(login.key, "laptop auth", login.laptopNonce, login.ipadNonce))
            else { break }
            let keys = Crypto.sessionKeys(key: login.key, laptopNonce: login.laptopNonce,
                                          ipadNonce: login.ipadNonce)
            link.cipher = Cipher(sendKey: keys.send, receiveKey: keys.receive)
            link.login = nil
            link.ready = true
            activate(link)
            return true

        default:
            break
        }
        close(link)
        return false
    }

    // MARK: sending and closing

    /// `then` runs (on the queue) once the message has been handed to the network,
    /// e.g. to close the connection without cutting off this last message.
    private func sendJSON(_ object: [String: Any], on link: Link, then: (() -> Void)? = nil) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        var type = MessageType.json.rawValue
        var payload = body
        if let cipher = link.cipher {
            guard let sealed = try? cipher.seal(Data([type]) + body) else { return }
            type = MessageType.sealed.rawValue
            payload = sealed
        }
        let n = UInt32(payload.count)
        var frame = Data([type, UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                          UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
        frame.append(payload)
        link.connection.send(content: frame, completion: .contentProcessed { _ in then?() })
    }

    private func close(_ link: Link) {
        link.connection.cancel()
        if link === pairingLink {
            pairingLink = nil
            onPairingEnded?("The laptop stopped pairing.")
        }
        // ignore links that were already replaced by a newer one
        guard link === active else { return }
        active = nil
        onDisconnected?()
    }
}
