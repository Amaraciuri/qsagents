import XCTest
@testable import QS_Agents

@MainActor
final class ToolParseTests: XCTestCase {
    private let runner = AgentToolRunner()

    func testParseSingleToolObject() {
        let calls = runner.parseToolCalls(from: #"{"tool":"list_dir","path":"."}"#)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, .list_dir)
        XCTAssertEqual(calls.first?.args["path"], ".")
    }

    func testParseNameAlias() {
        let calls = runner.parseToolCalls(from: #"{"name":"read_file","path":"README.md"}"#)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, .read_file)
        XCTAssertEqual(calls.first?.args["path"], "README.md")
    }

    func testParseToolsBatch() {
        let json = #"{"tools":[{"tool":"list_dir","path":"."},{"tool":"read_file","path":"a.swift"}]}"#
        let calls = runner.parseToolCalls(from: json)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, .list_dir)
        XCTAssertEqual(calls[1].name, .read_file)
    }

    func testParseFencedJSON() {
        let text = """
        Ecco il tool:
        ```json
        {"tool":"list_dir","path":"src"}
        ```
        """
        let calls = runner.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, .list_dir)
        XCTAssertEqual(calls.first?.args["path"], "src")
    }

    func testParseIgnoresProseWithoutJSON() {
        XCTAssertTrue(runner.parseToolCalls(from: "Nessun tool qui, solo testo.").isEmpty)
    }

    func testLooksLikeFailedToolAttempt() {
        XCTAssertTrue(AgentToolRunner.looksLikeFailedToolAttempt(#"{"tool":"nope"}"#))
        XCTAssertTrue(AgentToolRunner.looksLikeFailedToolAttempt("devo usare read_file ora"))
        XCTAssertFalse(AgentToolRunner.looksLikeFailedToolAttempt("Tutto ok, nessun tool."))
    }
}
