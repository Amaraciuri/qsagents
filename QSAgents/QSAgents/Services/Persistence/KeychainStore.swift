import Foundation
import Security

/// Thread-safe Keychain wrapper with in-memory cache.
///
/// Dev builds are **ad-hoc signed** (no Team ID). Without data-protection attributes,
/// macOS shows “wants to use your confidential information in the keychain” on almost
/// every rebuild / relaunch. We:
/// - store in the data-protection keychain (`kSecUseDataProtectionKeychain`)
/// - use `AfterFirstUnlockThisDeviceOnly` accessibility
/// - cache successful reads for the process lifetime
/// - support non-interactive reads (no UI prompt storms during bootstrap)
/// - dual-write legacy keychain so ad-hoc builds keep working across rebuilds
enum KeychainPersistResult: Equatable {
    case persisted
    /// In-memory only — gone after quit (BUG: never claim Keychain success).
    case sessionOnly
    case failed
}

enum KeychainStore {
    private static let service = "com.qsagents.mac"
    private static let lock = NSLock()
    /// Positive cache: account → secret
    private static var cache: [String: String] = [:]
    /// Accounts known missing (avoid hammering SecItem on every status refresh)
    private static var missCache: Set<String> = []
    /// Accounts that only live in process cache (UI badge).
    private static var sessionOnlyAccounts: Set<String> = []

    // MARK: - Public API

    static func isSessionOnly(_ account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessionOnlyAccounts.contains(account)
    }

    /// Persist secret. Always updates the process cache first so callers can use the key
    /// even if Keychain ACL briefly refuses a non-interactive re-read.
    /// Returns `true` only when persisted to Keychain (not session-only).
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        persist(value, for: account) == .persisted
    }

    @discardableResult
    static func persist(_ value: String, for account: String) -> KeychainPersistResult {
        let data = Data(value.utf8)
        lock.lock()
        cache[account] = value
        missCache.remove(account)
        lock.unlock()

        // 1) Prefer update on data-protection item (avoids ACL churn).
        var query = baseQuery(account: account)
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if status == errSecSuccess {
            _ = setLegacy(data: data, account: account, quiet: true)
            markPersisted(account)
            return .persisted
        }

        // 2) Not found → add DP
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecSuccess {
                _ = setLegacy(data: data, account: account, quiet: true)
                markPersisted(account)
                return .persisted
            }
        }

        // 3) Locked / ACL / duplicate / param → delete both slots and re-add
        if status != errSecSuccess {
            SecItemDelete(query as CFDictionary)
            SecItemDelete(legacyQuery(account: account) as CFDictionary)
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecSuccess {
                _ = setLegacy(data: data, account: account, quiet: true)
                markPersisted(account)
                return .persisted
            }
        }

        // 4) Legacy-only (no data-protection flag) — common on ad-hoc signed apps
        if setLegacy(data: data, account: account, quiet: false) {
            AppLogger.info("Keychain set(\(account)) OK via legacy fallback")
            markPersisted(account)
            return .persisted
        }

        // 5) Session-only: cache holds the key for this process — do NOT claim Keychain success.
        AppLogger.error("Keychain set(\(account)) SecItem failed (\(status) \(secMessage(status))); session cache only")
        lock.lock()
        sessionOnlyAccounts.insert(account)
        lock.unlock()
        return .sessionOnly
    }

    private static func markPersisted(_ account: String) {
        lock.lock()
        sessionOnlyAccounts.remove(account)
        lock.unlock()
    }

    static func delete(_ account: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: account)
        missCache.insert(account)
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        // Also wipe possible legacy item
        SecItemDelete(legacyQuery(account: account) as CFDictionary)
    }

    /// Read secret. `interactive: false` avoids keychain UI (returns nil if locked / denied).
    static func get(_ account: String, interactive: Bool = false) -> String? {
        lock.lock()
        if let cached = cache[account] {
            lock.unlock()
            return cached
        }
        if missCache.contains(account) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        // Try data-protection keychain first
        if let value = copyMatching(account: account, dataProtection: true, interactive: interactive) {
            lock.lock()
            cache[account] = value
            missCache.remove(account)
            lock.unlock()
            return value
        }
        // Migrate from legacy keychain if present (cache only — avoid re-entry into set)
        if let legacy = copyMatching(account: account, dataProtection: false, interactive: interactive) {
            lock.lock()
            cache[account] = legacy
            missCache.remove(account)
            lock.unlock()
            // Best-effort dual-write without going through set() (set returns via cache already)
            let data = Data(legacy.utf8)
            var add = baseQuery(account: account)
            SecItemDelete(add as CFDictionary)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            _ = SecItemAdd(add as CFDictionary, nil)
            return legacy
        }

        lock.lock()
        missCache.insert(account)
        lock.unlock()
        return nil
    }

    /// Cheap presence check (uses cache; non-interactive SecItem).
    static func hasValue(_ account: String) -> Bool {
        if let v = get(account, interactive: false), !v.isEmpty { return true }
        return false
    }

    /// Drop in-memory caches (e.g. after user disconnects an integration).
    static func invalidateCache(for account: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let account {
            cache.removeValue(forKey: account)
            missCache.remove(account)
        } else {
            cache.removeAll()
            missCache.removeAll()
        }
    }

    // MARK: - Internals

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func legacyQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func copyMatching(account: String, dataProtection: Bool, interactive: Bool) -> String? {
        var query: [String: Any] = dataProtection ? baseQuery(account: account) : legacyQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Avoid modal “Allow / Always Allow” storms during bootstrap / status polling.
        if !interactive {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return s
        }
        if status != errSecItemNotFound && status != errSecInteractionNotAllowed {
            AppLogger.info("Keychain get(\(account)) dp=\(dataProtection) → \(status) \(secMessage(status))")
        }
        return nil
    }

    @discardableResult
    private static func setLegacy(data: Data, account: String, quiet: Bool = false) -> Bool {
        var query = legacyQuery(account: account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { return true }
        // Update if add races / duplicate
        if status == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let u = SecItemUpdate(legacyQuery(account: account) as CFDictionary, update as CFDictionary)
            if u == errSecSuccess { return true }
            if !quiet {
                AppLogger.error("Keychain legacy update(\(account)) failed: \(u) \(secMessage(u))")
            }
            return false
        }
        if !quiet {
            AppLogger.error("Keychain legacy set(\(account)) failed: \(status) \(secMessage(status))")
        }
        return false
    }

    private static func secMessage(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "osStatus=\(status)"
    }
}
