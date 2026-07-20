import Foundation
import Combine

// MARK: - Models

enum OperationalItemStatus: String, Codable, CaseIterable, Identifiable {
    case done
    case todo
    case blocked

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .done: return "fatto"
        case .todo: return "da fare"
        case .blocked: return "bloccato"
        }
    }

    var next: OperationalItemStatus {
        switch self {
        case .todo: return .done
        case .done: return .blocked
        case .blocked: return .todo
        }
    }
}

struct OperationalItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var status: OperationalItemStatus
    var ownerInitials: String
    var notes: String

    init(
        id: UUID = UUID(),
        title: String,
        status: OperationalItemStatus = .todo,
        ownerInitials: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.ownerInitials = ownerInitials
        self.notes = notes
    }
}

struct OperationalPhase: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var sortOrder: Int
    var items: [OperationalItem]
    /// Optional banner above cards (e.g. "ADESSO").
    var highlightLabel: String

    init(
        id: UUID = UUID(),
        title: String,
        sortOrder: Int,
        items: [OperationalItem] = [],
        highlightLabel: String = ""
    ) {
        self.id = id
        self.title = title
        self.sortOrder = sortOrder
        self.items = items
        self.highlightLabel = highlightLabel
    }
}

struct OperationalPlan: Codable, Equatable {
    var workspacePath: String
    var phases: [OperationalPhase]
    var updatedAt: Date

    var sortedPhases: [OperationalPhase] {
        phases.sorted { $0.sortOrder < $1.sortOrder }
    }

    var allItems: [OperationalItem] {
        sortedPhases.flatMap(\.items)
    }

    var counts: (done: Int, todo: Int, blocked: Int, total: Int) {
        let items = allItems
        let done = items.filter { $0.status == .done }.count
        let todo = items.filter { $0.status == .todo }.count
        let blocked = items.filter { $0.status == .blocked }.count
        return (done, todo, blocked, items.count)
    }
}

struct OperationalPlanPayload: Codable, Equatable {
    var plans: [String: OperationalPlan]
}

// MARK: - Store

@MainActor
final class OperationalPlanStore: ObservableObject {
    static let shared = OperationalPlanStore()

    @Published private(set) var activePlan: OperationalPlan?
    @Published private(set) var activeWorkspacePath: String?

    private var plans: [String: OperationalPlan] = [:]
    private let storeName = "operational_plans_v1"

    init() { load() }

    func bind(workspacePath: String?) {
        let normalized = Self.normalize(workspacePath)
        activeWorkspacePath = normalized
        guard let key = normalized else {
            activePlan = nil
            return
        }
        if plans[key] == nil {
            plans[key] = Self.makeSeedPlan(workspacePath: key)
            persist()
        }
        activePlan = plans[key]
    }

    // MARK: Mutations

    func addPhase(title: String? = nil) {
        guard var plan = activePlan, let key = activeWorkspacePath else { return }
        let nextOrder = (plan.phases.map(\.sortOrder).max() ?? -1) + 1
        let name = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(L("Fase")) \(nextOrder + 1)"
        plan.phases.append(OperationalPhase(title: name, sortOrder: nextOrder))
        plan.updatedAt = .now
        plans[key] = plan
        activePlan = plan
        persist()
    }

    func renamePhase(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var plan = activePlan, let key = activeWorkspacePath,
              let i = plan.phases.firstIndex(where: { $0.id == id }) else { return }
        plan.phases[i].title = trimmed
        plan.updatedAt = .now
        plans[key] = plan
        activePlan = plan
        persist()
    }

    func deletePhase(_ id: UUID) {
        guard var plan = activePlan, let key = activeWorkspacePath else { return }
        plan.phases.removeAll { $0.id == id }
        for i in plan.phases.indices {
            plan.phases[i].sortOrder = i
        }
        plan.updatedAt = .now
        plans[key] = plan
        activePlan = plan
        persist()
    }

    func setPhaseHighlight(_ id: UUID, label: String) {
        guard var plan = activePlan, let key = activeWorkspacePath,
              let i = plan.phases.firstIndex(where: { $0.id == id }) else { return }
        plan.phases[i].highlightLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.updatedAt = .now
        plans[key] = plan
        activePlan = plan
        persist()
    }

    func addItem(phaseID: UUID, title: String? = nil) {
        guard var plan = activePlan, let key = activeWorkspacePath,
              let i = plan.phases.firstIndex(where: { $0.id == phaseID }) else { return }
        let name = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? L("Nuovo item")
        plan.phases[i].items.append(OperationalItem(title: name, status: .todo, ownerInitials: "QS"))
        plan.updatedAt = .now
        plans[key] = plan
        activePlan = plan
        persist()
    }

    func toggleItemStatus(phaseID: UUID, itemID: UUID) {
        guard var plan = activePlan, let key = activeWorkspacePath,
              let pi = plan.phases.firstIndex(where: { $0.id == phaseID }),
              let ii = plan.phases[pi].items.firstIndex(where: { $0.id == itemID }) else { return }
        plan.phases[pi].items[ii].status = plan.phases[pi].items[ii].status.next
        plan.updatedAt = .now
        plans[key] = plan
        activePlan = plan
        persist()
    }

    func setItemStatus(phaseID: UUID, itemID: UUID, status: OperationalItemStatus) {
        guard var plan = activePlan, let key = activeWorkspacePath,
              let pi = plan.phases.firstIndex(where: { $0.id == phaseID }),
              let ii = plan.phases[pi].items.firstIndex(where: { $0.id == itemID }) else { return }
        plan.phases[pi].items[ii].status = status
        plan.updatedAt = .now
        plans[key] = plan
        activePlan = plan
        persist()
    }

    func renameItem(phaseID: UUID, itemID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var plan = activePlan, let key = activeWorkspacePath,
              let pi = plan.phases.firstIndex(where: { $0.id == phaseID }),
              let ii = plan.phases[pi].items.firstIndex(where: { $0.id == itemID }) else { return }
        plan.phases[pi].items[ii].title = trimmed
        plan.updatedAt = .now
        plans[key] = plan
        activePlan = plan
        persist()
    }

    func deleteItem(phaseID: UUID, itemID: UUID) {
        guard var plan = activePlan, let key = activeWorkspacePath,
              let pi = plan.phases.firstIndex(where: { $0.id == phaseID }) else { return }
        plan.phases[pi].items.removeAll { $0.id == itemID }
        plan.updatedAt = .now
        plans[key] = plan
        activePlan = plan
        persist()
    }

    func resetToSeed() {
        guard let key = activeWorkspacePath else { return }
        plans[key] = Self.makeSeedPlan(workspacePath: key)
        activePlan = plans[key]
        persist()
    }

    // MARK: Persistence

    private func load() {
        if let payload: OperationalPlanPayload = JSONStore.load(OperationalPlanPayload.self, name: storeName) {
            plans = payload.plans
        } else if let legacy: [String: OperationalPlan] = JSONStore.load([String: OperationalPlan].self, name: storeName) {
            plans = legacy
        }
    }

    private func persist() {
        JSONStore.save(OperationalPlanPayload(plans: plans), name: storeName)
    }

    private static func normalize(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).standardizingPath
    }

    // MARK: Seed

    static func makeSeedPlan(workspacePath: String) -> OperationalPlan {
        let phases: [OperationalPhase] = [
            OperationalPhase(
                title: L("Foundation"),
                sortOrder: 0,
                items: [
                    OperationalItem(title: L("Setup workspace e repo"), status: .done, ownerInitials: "QS"),
                    OperationalItem(title: L("Config provider / modelli"), status: .todo, ownerInitials: "QS"),
                    OperationalItem(title: L("Indice Knowledge + code brain"), status: .todo, ownerInitials: "QS"),
                ]
            ),
            OperationalPhase(
                title: L("Features"),
                sortOrder: 1,
                items: [
                    OperationalItem(title: L("Feature core end-to-end"), status: .todo, ownerInitials: "QS"),
                    OperationalItem(title: L("Integrazione agent / tools"), status: .todo, ownerInitials: "QS"),
                    OperationalItem(title: L("Persistenza e stato"), status: .blocked, ownerInitials: "QS"),
                ],
                highlightLabel: L("ADESSO")
            ),
            OperationalPhase(
                title: L("Polish"),
                sortOrder: 2,
                items: [
                    OperationalItem(title: L("UI e copy"), status: .todo, ownerInitials: "QS"),
                    OperationalItem(title: L("Empty states e errori"), status: .todo, ownerInitials: "QS"),
                ]
            ),
            OperationalPhase(
                title: L("QA"),
                sortOrder: 3,
                items: [
                    OperationalItem(title: L("Smoke build Debug"), status: .todo, ownerInitials: "QS"),
                    OperationalItem(title: L("Checklist regressioni"), status: .todo, ownerInitials: "QS"),
                    OperationalItem(title: L("Fix bug aperti"), status: .blocked, ownerInitials: "QS"),
                ]
            ),
            OperationalPhase(
                title: L("Ship"),
                sortOrder: 4,
                items: [
                    OperationalItem(title: L("Release notes"), status: .todo, ownerInitials: "QS"),
                    OperationalItem(title: L("Tag / distribuzione"), status: .todo, ownerInitials: "QS"),
                ]
            ),
        ]
        return OperationalPlan(workspacePath: workspacePath, phases: phases, updatedAt: .now)
    }
}
