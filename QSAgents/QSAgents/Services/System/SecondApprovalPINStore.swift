import Foundation
import CryptoKit
import Security

/// Keychain-backed second-approval PIN with salted PBKDF2 and brute-force lockout.
enum SecondApprovalPINStore {
    private static let keychainAccount = "QSAgents.SecondApproval.PIN"
    private static let legacyDefaultsKey = "qs.safety.second.pin"
    private static let attemptsKey = "qs.safety.pin.attempts"
    private static let lockoutUntilKey = "qs.safety.pin.lockoutUntil"
    private static let pbkdf2Iterations = 120_000
    private static let maxAttempts = 5
    private static let baseLockoutSeconds: TimeInterval = 30

    struct StoredRecord: Codable {
        var salt: String
        var derivedKey: String
        var iterations: Int
        /// Legacy unsalted SHA256 hex from UserDefaults — cleared after successful verify or re-set.
        var legacySha256: String?
    }

    enum VerifyResult {
        case ok
        case notConfigured
        case invalid
        case lockedOut(until: Date, message: String)
    }

    static var isConfigured: Bool {
        guard let record = loadRecord() else { return false }
        if let legacy = record.legacySha256, !legacy.isEmpty { return true }
        return !record.derivedKey.isEmpty
    }

    // MARK: - Public

    static func setPIN(_ pin: String) -> Bool {
        guard pin.count >= 4 else { return false }
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else { return false }
        let saltData = Data(salt)
        let derived = deriveKey(password: pin, salt: saltData, iterations: pbkdf2Iterations)
        let record = StoredRecord(
            salt: saltData.base64EncodedString(),
            derivedKey: derived.base64EncodedString(),
            iterations: pbkdf2Iterations,
            legacySha256: nil
        )
        guard persist(record) else { return false }
        clearLegacyUserDefaults()
        resetAttempts()
        return true
    }

    static func clearPIN() {
        KeychainStore.delete(keychainAccount)
        clearLegacyUserDefaults()
        resetAttempts()
    }

    static func verify(_ pin: String) -> VerifyResult {
        if let lockout = lockoutActive() {
            return .lockedOut(until: lockout, message: lockoutMessage(until: lockout))
        }
        guard let record = loadRecord() else {
            return .notConfigured
        }

        if let legacy = record.legacySha256, !legacy.isEmpty {
            let legacyHash = legacySHA256(pin)
            if legacyHash == legacy {
                // Upgrade to PBKDF2 on successful legacy verify.
                _ = setPIN(pin)
                resetAttempts()
                return .ok
            }
            return registerFailedAttempt()
        }

        guard let salt = Data(base64Encoded: record.salt),
              let expected = Data(base64Encoded: record.derivedKey) else {
            return .notConfigured
        }
        let derived = deriveKey(password: pin, salt: salt, iterations: record.iterations)
        guard derived == expected else {
            return registerFailedAttempt()
        }
        resetAttempts()
        return .ok
    }

    /// On launch: migrate legacy UserDefaults hash into Keychain marker, then remove from defaults.
    static func migrateLegacyIfNeeded() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: legacyDefaultsKey),
              !legacy.isEmpty else { return }

        defaults.removeObject(forKey: legacyDefaultsKey)

        if var record = loadRecord(), record.legacySha256 == nil, !record.derivedKey.isEmpty {
            // Already on PBKDF2 — drop stale defaults only.
            return
        }

        let record = StoredRecord(
            salt: "",
            derivedKey: "",
            iterations: pbkdf2Iterations,
            legacySha256: legacy
        )
        _ = persist(record)
    }

    // MARK: - Lockout

    private static func lockoutActive() -> Date? {
        let until = UserDefaults.standard.double(forKey: lockoutUntilKey)
        guard until > 0 else { return nil }
        let date = Date(timeIntervalSince1970: until)
        if date > Date() { return date }
        UserDefaults.standard.removeObject(forKey: lockoutUntilKey)
        UserDefaults.standard.set(0, forKey: attemptsKey)
        return nil
    }

    private static func registerFailedAttempt() -> VerifyResult {
        let attempts = UserDefaults.standard.integer(forKey: attemptsKey) + 1
        UserDefaults.standard.set(attempts, forKey: attemptsKey)
        if attempts >= maxAttempts {
            let exponent = min(attempts - maxAttempts, 5)
            let seconds = baseLockoutSeconds * pow(2.0, Double(exponent))
            let until = Date().addingTimeInterval(seconds)
            UserDefaults.standard.set(until.timeIntervalSince1970, forKey: lockoutUntilKey)
            return .lockedOut(until: until, message: lockoutMessage(until: until))
        }
        return .invalid
    }

    private static func resetAttempts() {
        UserDefaults.standard.set(0, forKey: attemptsKey)
        UserDefaults.standard.removeObject(forKey: lockoutUntilKey)
    }

    private static func lockoutMessage(until: Date) -> String {
        let secs = max(1, Int(until.timeIntervalSinceNow))
        return "Troppi tentativi PIN — riprova tra \(secs)s"
    }

    // MARK: - Storage

    private static func loadRecord() -> StoredRecord? {
        guard let raw = KeychainStore.get(keychainAccount, interactive: false),
              let data = raw.data(using: .utf8),
              let record = try? JSONDecoder().decode(StoredRecord.self, from: data) else {
            return nil
        }
        if record.derivedKey.isEmpty && (record.legacySha256?.isEmpty ?? true) {
            return nil
        }
        return record
    }

    @discardableResult
    private static func persist(_ record: StoredRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record),
              let json = String(data: data, encoding: .utf8) else { return false }
        return KeychainStore.set(json, for: keychainAccount)
    }

    private static func clearLegacyUserDefaults() {
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }

    private static func legacySHA256(_ pin: String) -> String {
        SHA256.hash(data: Data(pin.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - PBKDF2 (HMAC-SHA256, RFC 8018)

    private static func deriveKey(password: String, salt: Data, iterations: Int) -> Data {
        let passwordData = Data(password.utf8)
        let keyLength = 32
        var derived = Data()
        var blockIndex: UInt32 = 1
        while derived.count < keyLength {
            var bigEndian = blockIndex.bigEndian
            let blockSalt = salt + Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
            var u = Data(HMAC<SHA256>.authenticationCode(for: blockSalt, using: SymmetricKey(data: passwordData)))
            var block = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: SymmetricKey(data: passwordData)))
                    for i in 0..<block.count {
                        block[i] ^= u[i]
                    }
                }
            }
            derived.append(block)
            blockIndex += 1
        }
        return derived.prefix(keyLength)
    }
}
