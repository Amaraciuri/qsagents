import XCTest
@testable import QS_Agents

final class WorkspacePathSandboxTests: XCTestCase {
    func testSiblingAbsoluteEscapeRejected() {
        let root = "/tmp/qs-sandbox-proj"
        XCTAssertTrue(WorkspacePathSandbox.contains(candidate: root + "/src/a.swift", workspaceRoot: root))
        XCTAssertFalse(WorkspacePathSandbox.contains(candidate: "/tmp/qs-sandbox-proj-evil/secret", workspaceRoot: root))
    }

    func testParentTraversalRejectedAfterResolve() {
        let root = "/tmp/qs-sandbox-proj"
        // standardizingPath collapses .. before we check — joined path must still be inside
        let outside = root + "/../qs-sandbox-proj-evil/x"
        XCTAssertFalse(WorkspacePathSandbox.contains(candidate: outside, workspaceRoot: root))
    }

    func testSymlinkEscapeRejected() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("qs-sandbox-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("proj", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let secret = outside.appendingPathComponent("secret.txt")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "leak".write(to: secret, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("escape-link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
        defer { try? fm.removeItem(at: base) }

        XCTAssertTrue(WorkspacePathSandbox.contains(candidate: root.path + "/ok.txt", workspaceRoot: root.path))
        XCTAssertFalse(
            WorkspacePathSandbox.contains(candidate: link.path + "/secret.txt", workspaceRoot: root.path),
            "symlink pointing outside workspace must fail containment"
        )
    }

    @MainActor
    func testSanitizedWorkspaceRejectsHome() {
        XCTAssertNil(AgentToolRunner.sanitizedWorkspace(NSHomeDirectory()))
        XCTAssertNil(AgentToolRunner.sanitizedWorkspace(nil))
        XCTAssertNil(AgentToolRunner.sanitizedWorkspace(""))
    }
}
