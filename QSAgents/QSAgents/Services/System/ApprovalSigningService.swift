import Foundation
import CryptoKit
import AppKit
import Security

/// Tamper-evident approval audit trail (JSONL + HMAC chain) under Application Support.
/// Retention: operators may prune old `approval-chain.jsonl` lines periodically; exports are redacted.
@MainActor
final class ApprovalSigningService: ObservableObject {
    @Published private(set) var lastWritePath: String?
    @Published private(set) var lastError: String?
    @Published private(set) var recentRecords: [SignedApprovalRecord] = []

    private let directory: URL
    private let logFile: URL
    private var secretKey: SymmetricKey
    private var lastHash: String = "GENESIS"

    private let secretAccount = "QSAgents.ApprovalLog.HMAC"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QSAgents", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
        directory = base
        logFile = base.appendingPathComponent("approval-chain.jsonl")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // Never block app launch on Keychain: securityd has been observed hanging forever on
        // legacy ACL items for this secret, freezing the main thread (spinning cursor, no window).
        // Start with an ephemeral key; resolve Keychain off the main actor after first frame.
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        secretKey = SymmetricKey(data: Data(bytes))

        loadTail()

        let account = secretAccount
        let ephemeralB64 = Data(bytes).base64EncodedString()
        Task(priority: .utility) { [weak self] in
            let existing = await Task.detached(priority: .utility) {
                KeychainStore.get(account, interactive: false)
            }.value
            if let existing, let data = Data(base64Encoded: existing) {
                await MainActor.run {
                    guard let self else { return }
                    self.secretKey = SymmetricKey(data: data)
                    AppLogger.info("Approval HMAC secret loaded from Keychain (async)")
                }
                return
            }
            let saved = await Task.detached(priority: .utility) {
                KeychainStore.set(ephemeralB64, for: account)
            }.value
            if !saved {
                AppLogger.info("Approval HMAC secret is session-only (Keychain unavailable)")
            }
        }
    }

    var logDirectoryPath: String { directory.path }
    var logFilePath: String { logFile.path }

    /// Export recent signed records + full JSONL as CSV (Fase 10).
    /// Caller should warn the user that exports may contain hostnames and shortened paths.
    @discardableResult
    func exportCSV() -> URL? {
        let out = directory.appendingPathComponent("audit-export-\(Int(Date().timeIntervalSince1970)).csv")
        var csv = "id,timestamp,event,command,path,environment,rule,role,source,user,prevHash\n"
        let records = recentRecords
        for r in records {
            let row = [
                r.payload.id,
                r.payload.timestamp,
                r.payload.event,
                r.payload.command.replacingOccurrences(of: "\"", with: "'"),
                r.payload.path ?? "",
                r.payload.environment,
                r.payload.ruleName ?? "",
                r.payload.role ?? "",
                r.payload.source,
                r.payload.user,
                r.payload.prevHash,
            ].map { "\"\($0)\"" }.joined(separator: ",")
            csv += row + "\n"
        }
        csv = SecretRedactor.redact(csv)
        do {
            try csv.write(to: out, atomically: true, encoding: .utf8)
            lastWritePath = out.path
            return out
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Append

    @discardableResult
    func append(
        event: ApprovalEventKind,
        command: String,
        path: String?,
        environment: String,
        ruleName: String?,
        role: String?,
        source: String,
        firstApprover: String?,
        secondApprover: String?,
        remoteCode: String? = nil,
        metadata: [String: String] = [:]
    ) -> SignedApprovalRecord? {
        let payload = ApprovalPayload(
            id: UUID().uuidString,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            event: event.rawValue,
            command: Self.sanitizeForAudit(command),
            path: path.map { SecretRedactor.shortenPaths($0) },
            environment: environment,
            ruleName: ruleName,
            role: role,
            source: source,
            firstApprover: firstApprover,
            secondApprover: secondApprover,
            remoteCode: remoteCode.map { SecretRedactor.hashPrefix($0) },
            prevHash: lastHash,
            host: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            user: NSUserName(),
            metadata: metadata.mapValues { SecretRedactor.redact($0) }
        )

        guard let bodyData = try? JSONEncoder().encode(payload) else {
            lastError = "Encode payload fallito"
            return nil
        }
        let bodyB64 = bodyData.base64EncodedString()
        let signature = hmac(bodyData)
        let record = SignedApprovalRecord(
            payload: payload,
            signature: signature,
            chainHash: sha256Hex(Data((lastHash + signature).utf8))
        )

        guard let lineData = try? JSONEncoder().encode(record),
              var line = String(data: lineData, encoding: .utf8) else {
            lastError = "Encode record fallito"
            return nil
        }
        line += "\n"

        do {
            if !FileManager.default.fileExists(atPath: logFile.path) {
                try Data().write(to: logFile)
            }
            let handle = try FileHandle(forWritingTo: logFile)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let d = line.data(using: .utf8) {
                try handle.write(contentsOf: d)
            }
            lastHash = record.chainHash
            lastWritePath = logFile.path
            recentRecords.insert(record, at: 0)
            if recentRecords.count > 40 {
                recentRecords = Array(recentRecords.prefix(40))
            }
            lastError = nil
            return record
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Verify entire chain integrity.
    func verifyChain() -> (ok: Bool, message: String) {
        guard FileManager.default.fileExists(atPath: logFile.path),
              let data = try? Data(contentsOf: logFile),
              let text = String(data: data, encoding: .utf8) else {
            return (true, "Log vuoto o assente")
        }
        var prev = "GENESIS"
        var count = 0
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let row = try? JSONDecoder().decode(SignedApprovalRecord.self, from: Data(line.utf8)) else {
                return (false, "Riga non decodificabile #\(count + 1)")
            }
            guard let bodyData = try? JSONEncoder().encode(row.payload) else {
                return (false, "Payload non ri-encodabile")
            }
            let expectedSig = hmac(bodyData)
            guard expectedSig == row.signature else {
                return (false, "Firma invalida su record \(row.payload.id)")
            }
            guard row.payload.prevHash == prev else {
                return (false, "Catena rotta su record \(row.payload.id)")
            }
            let expectedChain = sha256Hex(Data((prev + row.signature).utf8))
            guard expectedChain == row.chainHash else {
                return (false, "Chain hash invalido \(row.payload.id)")
            }
            prev = row.chainHash
            count += 1
        }
        return (true, "OK · \(count) record verificati")
    }

    func revealInFinder() {
        NSWorkspace.shared.selectFile(logFile.path, inFileViewerRootedAtPath: directory.path)
    }

    // MARK: - Private

    private func loadTail() {
        guard FileManager.default.fileExists(atPath: logFile.path),
              let data = try? Data(contentsOf: logFile),
              let text = String(data: data, encoding: .utf8) else { return }
        var prev = "GENESIS"
        var loaded: [SignedApprovalRecord] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            if let row = try? JSONDecoder().decode(SignedApprovalRecord.self, from: Data(line.utf8)) {
                loaded.append(row)
                prev = row.chainHash
            }
        }
        lastHash = prev
        recentRecords = Array(loaded.suffix(40).reversed())
    }

    private func hmac(_ data: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: secretKey)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizeForAudit(_ command: String) -> String {
        SecretRedactor.redact(String(command.prefix(2000)))
    }
}

enum ApprovalEventKind: String {
    case pendingSingle = "PENDING_SINGLE"
    case pendingDual = "PENDING_DUAL"
    case firstApproved = "FIRST_APPROVED"
    case dualApproved = "DUAL_APPROVED"
    case approved = "APPROVED"
    case denied = "DENIED"
    case remoteNotified = "REMOTE_NOTIFIED"
    case remoteCodeUsed = "REMOTE_CODE_USED"
    case pinDenied = "PIN_DENIED"
}

struct ApprovalPayload: Codable, Equatable {
    let id: String
    let timestamp: String
    let event: String
    let command: String
    let path: String?
    let environment: String
    let ruleName: String?
    let role: String?
    let source: String
    let firstApprover: String?
    let secondApprover: String?
    let remoteCode: String?
    let prevHash: String
    let host: String
    let user: String
    let metadata: [String: String]
}

struct SignedApprovalRecord: Codable, Equatable, Identifiable {
    var id: String { payload.id }
    let payload: ApprovalPayload
    let signature: String
    let chainHash: String
}

import AppKit
