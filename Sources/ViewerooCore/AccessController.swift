import CommonCrypto
import Foundation
import LocalAuthentication
import Security

public enum AccessError: LocalizedError {
    case invalidPIN
    case incorrectPIN
    case invalidKey
    case unavailable
    case recoveryFailed
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidPIN: "Enter a PIN of 4 to 12 digits."
        case .incorrectPIN: "The current PIN is incorrect."
        case .invalidKey: "Enter your personal PRDB API key."
        case .unavailable: "The saved credential could not be read."
        case .recoveryFailed: "macOS authentication did not complete. Your existing PIN is still active."
        case let .keychain(status):
            "Keychain access failed. \(SecCopyErrorMessageString(status, nil) as String? ?? "Check your login keychain permissions.")"
        }
    }
}

@MainActor
protocol SecretStore {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data?, account: String) throws
}

@MainActor
protocol LegacyCredentials {
    func read(_ account: String) throws -> Data?
    func remove(_ account: String) throws
}

@MainActor
struct LegacyKeychain: LegacyCredentials {
    private func query(_ account: String) -> [String: Any] {
        // Keep these identifiers stable across releases. The login keychain associates
        // access with the executable and can prompt for authorization after an update.
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "net.prdb.vieweroo",
         kSecAttrAccount as String: account]
    }

    func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { throw AccessError.keychain(status) }
        guard let data = value as? Data else { throw AccessError.unavailable }
        return data
    }

    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccessError.keychain(status) }
    }
}

@MainActor
public final class AccessController {
    private let store: any SecretStore
    private let authenticate: @MainActor () async throws -> Bool
    static let keyAccount = "PRDB API key"
    static let pinAccount = "PIN verifier"
    private var validationAttempt: UUID?

    public convenience init(directory: URL = URL.applicationSupportDirectory.appending(path: "net.prdb.vieweroo")) {
        self.init(store: SettingsStore(directory: directory, legacy: LegacyKeychain()))
    }

    convenience init(store: any SecretStore) {
        self.init(store: store) {
            try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                                                 localizedReason: "Set a new PIN for Vieweroo.")
        }
    }

    init(store: any SecretStore, authenticate: @escaping @MainActor () async throws -> Bool) {
        self.store = store
        self.authenticate = authenticate
    }

    /// Only successfully validated keys are persisted. Storage and migration failures propagate to the access gate.
    public func apiKey() throws -> String? {
        guard let data = try store.read(Self.keyAccount) else { return nil }
        guard let key = String(data: data, encoding: .utf8), !key.isEmpty else { throw AccessError.unavailable }
        return key
    }

    public func validateAndStore(key: String, client: PRDBClient,
                                 while isCurrent: () -> Bool = { true }) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw AccessError.invalidKey }
        let attempt = UUID()
        validationAttempt = attempt
        do {
            try await client.validate(key: key)
        } catch PRDBError.invalidKey {
            try Task.checkCancellation()
            if validationAttempt == attempt, isCurrent() { try reject(key: key) }
            throw PRDBError.invalidKey
        }
        try Task.checkCancellation()
        guard validationAttempt == attempt, isCurrent() else { throw CancellationError() }
        try store.write(Data(key.utf8), account: Self.keyAccount)
    }

    public func reject(key: String) throws {
        if try apiKey() == key { try store.write(nil, account: Self.keyAccount) }
    }

    private static let catalogAccount = "Local catalog API key"

    public func catalogKey() throws -> String? {
        guard let data = try store.read(Self.catalogAccount) else { return nil }
        guard data.count == 32 else { throw AccessError.unavailable }
        return data.base64EncodedString()
    }

    public func enableCatalogAPI() throws {
        if try catalogKey() != nil { return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AccessError.unavailable
        }
        try store.write(Data(bytes), account: Self.catalogAccount)
    }

    public func revokeCatalogKey() throws { try store.write(nil, account: Self.catalogAccount) }

    public var hasPIN: Bool { get throws { try store.read(Self.pinAccount) != nil } }

    public func unlock(pin: String) throws {
        guard let saved = try store.read(Self.pinAccount) else { return }
        try verify(pin: pin, saved: saved)
    }

    public func setPIN(current: String?, new: String?) throws {
        if let saved = try store.read(Self.pinAccount) {
            guard let current else { throw AccessError.incorrectPIN }
            try verify(pin: current, saved: saved)
        }
        try store.write(try new.map(makeVerifier), account: Self.pinAccount)
    }

    public func recoverPIN(new: String) async throws {
        try validatePIN(new)
        guard let saved = try store.read(Self.pinAccount) else { throw AccessError.recoveryFailed }
        guard (try? await authenticate()) == true else { throw AccessError.recoveryFailed }
        try Task.checkCancellation()
        guard try store.read(Self.pinAccount) == saved else { throw AccessError.recoveryFailed }
        try store.write(try makeVerifier(new), account: Self.pinAccount)
    }

    private func validatePIN(_ pin: String) throws {
        guard (4...12).contains(pin.utf8.count), pin.utf8.allSatisfy({ (48...57).contains($0) })
        else { throw AccessError.invalidPIN }
    }

    // Version byte, 16-byte random salt and 32-byte PBKDF2-HMAC-SHA256 output.
    private func makeVerifier(_ pin: String) throws -> Data {
        try validatePIN(pin)
        var salt = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        guard status == errSecSuccess else { throw AccessError.unavailable }
        return Data([1] + salt + (try derive(pin, salt: salt)))
    }

    private func verify(pin: String, saved: Data) throws {
        guard saved.count == 49, saved.first == 1 else { throw AccessError.unavailable }
        try validatePIN(pin)
        let actual = try derive(pin, salt: Array(saved.dropFirst().prefix(16)))
        let difference = zip(actual, saved.suffix(32)).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0 else { throw AccessError.incorrectPIN }
    }

    private func derive(_ pin: String, salt: [UInt8]) throws -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pin, pin.utf8.count, salt, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 150_000, &derived, derived.count)
        guard status == kCCSuccess else { throw AccessError.unavailable }
        return derived
    }
}
