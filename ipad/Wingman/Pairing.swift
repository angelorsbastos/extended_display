import CryptoKit
import Foundation
import Security

/// The iPad half of pc/secure.py: pairing keys in the Keychain, the 6-digit code
/// exchange, the per-connection login and the per-message encryption. Every
/// label, field order and key split here has to match secure.py exactly.

enum PairingStore {
    // the original name, kept: renaming it would lose every pairing already made
    private static let service = "dev.extenddisplay.pairing"

    /// This iPad's id, announced over Bonjour so the laptop can find its key.
    static let ipadId: String = {
        if let id = UserDefaults.standard.string(forKey: "ipad_id") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "ipad_id")
        return id
    }()

    static func key(for laptopId: String) -> Data? {
        var query = item(laptopId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(key: Data, for laptopId: String) {
        SecItemDelete(item(laptopId) as CFDictionary)
        var add = item(laptopId)
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Laptops this iPad has a key for (sent in "identity", so a laptop whose key
    /// was lost here knows to pair again).
    static var laptopIds: [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func item(_ laptopId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: laptopId]
    }
}

enum Crypto {
    static func random(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Compare a received MAC in constant time, so timing reveals nothing.
    static func matches(_ received: Data?, _ expected: Data) -> Bool {
        guard let received, received.count == expected.count else { return false }
        return zip(received, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func mac(_ key: Data, _ label: String, _ parts: Data...) -> Data {
        var message = Data(label.utf8)
        parts.forEach { message.append($0) }
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// The 6 digits the user types; the laptop shows the same number.
    static func pairingCode(ipadPublic: Data, laptopPublic: Data,
                            ipadNonce: Data, laptopNonce: Data) -> String {
        var input = Data("extend-display code v1".utf8)
        [ipadPublic, laptopPublic, ipadNonce, laptopNonce].forEach { input.append($0) }
        let d = [UInt8](sha256(input))
        let number = (UInt32(d[0]) << 24) | (UInt32(d[1]) << 16) | (UInt32(d[2]) << 8) | UInt32(d[3])
        return String(format: "%06u", number % 1_000_000)
    }

    /// Per-connection keys from the pairing key: first half laptop -> iPad,
    /// second half iPad -> laptop (as in secure.authenticate).
    static func sessionKeys(key: Data, laptopNonce: Data, ipadNonce: Data) -> (receive: Data, send: Data) {
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key),
                                             salt: laptopNonce + ipadNonce,
                                             info: Data("extend-display session v1".utf8),
                                             outputByteCount: 64)
        let bytes = derived.withUnsafeBytes { Data($0) }
        return (receive: bytes.prefix(32), send: bytes.suffix(32))
    }
}

/// One pairing attempt over Wi-Fi, from the iPad's side.
final class PairingExchange {
    let laptopId: String
    let laptopName: String
    let nonce = Crypto.random(16)
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private(set) var key: Data?
    private(set) var code: String?

    init(laptopId: String, laptopName: String) {
        self.laptopId = laptopId
        self.laptopName = laptopName
    }

    var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// Sent before seeing the laptop's key, so a fake laptop can't pick a key to match.
    var commitment: Data { Crypto.sha256(publicKey + nonce) }

    func receiveLaptopKey(_ laptopPublic: Data, nonce laptopNonce: Data) throws {
        let shared = try privateKey.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: laptopPublic))
        key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: nonce + laptopNonce,
                                             sharedInfo: Data("extend-display pairing v1".utf8),
                                             outputByteCount: 32).withUnsafeBytes { Data($0) }
        code = Crypto.pairingCode(ipadPublic: publicKey, laptopPublic: laptopPublic,
                                  ipadNonce: nonce, laptopNonce: laptopNonce)
    }
}

/// ChaCha20-Poly1305 per message, like secure.Cipher: each direction has its own
/// key and counts its messages; the count is the nonce, so nothing can be
/// replayed or reordered. Only used on the server's queue.
final class Cipher {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    init(sendKey: Data, receiveKey: Data) {
        self.sendKey = SymmetricKey(data: sendKey)
        self.receiveKey = SymmetricKey(data: receiveKey)
    }

    func seal(_ data: Data) throws -> Data {
        let box = try ChaChaPoly.seal(data, using: sendKey, nonce: try Self.nonce(sent))
        sent += 1
        return box.ciphertext + box.tag
    }

    func open(_ data: Data) throws -> Data {
        guard data.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
        let box = try ChaChaPoly.SealedBox(nonce: try Self.nonce(received),
                                           ciphertext: data.dropLast(16), tag: data.suffix(16))
        let opened = try ChaChaPoly.open(box, using: receiveKey)
        received += 1
        return opened
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }
}

extension Data {
    init?(base64 value: Any?) {
        guard let text = value as? String, let data = Data(base64Encoded: text) else { return nil }
        self = data
    }
}
