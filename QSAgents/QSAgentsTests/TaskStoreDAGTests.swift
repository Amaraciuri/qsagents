import XCTest
@testable import QS_Agents

@MainActor
final class TaskStoreDAGTests: XCTestCase {
    private func makeStore() -> TaskStore {
        let s = TaskStore()
        s.suspendPersistence = true
        s.tasks = []
        return s
    }

    private func task(
        _ title: String,
        column: TaskColumn,
        dependsOn: [UUID] = [],
        workspace: String? = "/tmp/proj"
    ) -> AgentTask {
        AgentTask(
            title: title,
            priority: .medio,
            column: column,
            assigneeModel: "test",
            workspacePath: workspace,
            dependsOn: dependsOn
        )
    }

    func testReviewDoesNotUnblockDependents() {
        let store = makeStore()
        let a = task("A", column: .review)
        var b = task("B", column: .todo, dependsOn: [a.id])
        store.tasks = [a, b]
        XCTAssertFalse(store.isUnblocked(b), "BUG-009: REVIEW must not unlock B")
        store.tasks[0].column = .done
        b = store.tasks[1]
        XCTAssertTrue(store.isUnblocked(b))
    }

    func testUpdateProgressNeverAutoCompletes() {
        let store = makeStore()
        let t = task("X", column: .inProgress)
        store.tasks = [t]
        store.updateProgress(t.id, 1.0)
        XCTAssertEqual(store.task(id: t.id)?.column, .inProgress)
        XCTAssertEqual(store.task(id: t.id)?.progress, 0.99)
    }

    func testClearCompletedRefusesWhileDependentsOpen() {
        let store = makeStore()
        let done = task("Done", column: .done)
        let child = task("Child", column: .todo, dependsOn: [done.id])
        store.tasks = [done, child]
        let removed = store.clearColumns([.done], workspacePath: nil, onlyCurrentWorkspace: false)
        XCTAssertEqual(removed, 0, "must not delete DONE while open child depends on it")
        XCTAssertEqual(store.tasks.count, 2)
    }

    func testMissingDependencyKeepsBlocked() {
        let store = makeStore()
        let child = task("Child", column: .todo, dependsOn: [UUID()])
        store.tasks = [child]
        XCTAssertFalse(store.isUnblocked(child), "missing dep id must block (no silent edge strip)")
    }

    func testFilteredEmptyWithoutWorkspaceWhenFilterOn() {
        let store = makeStore()
        store.tasks = [task("A", column: .todo, workspace: "/tmp/a")]
        XCTAssertTrue(store.filtered(workspacePath: nil, onlyCurrentWorkspace: true).isEmpty)
    }
}
