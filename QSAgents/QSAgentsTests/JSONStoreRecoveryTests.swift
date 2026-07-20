import XCTest
@testable import QS_Agents

final class JSONStoreRecoveryTests: XCTestCase {
    func testCorruptFileQuarantinedAndBackupRestored() throws {
        let name = "unit_test_store_\(UUID().uuidString.prefix(8))"
        let url = JSONStore.url(for: name)
        let bak = JSONStore.backupURL(for: name)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: bak)
            let dir = AppConfig.dataDirectory
            if let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for i in items where i.hasPrefix(name) {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(i))
                }
            }
        }

        JSONStore.save(["hello": "world"], name: name)
        XCTAssertNotNil(JSONStore.load([String: String].self, name: name))

        // Corrupt primary
        try "{not-json".write(to: url, atomically: true, encoding: .utf8)
        let loaded = JSONStore.load([String: String].self, name: name)
        XCTAssertEqual(loaded?["hello"], "world", "must recover from .bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "corrupt primary quarantined")
    }
}
