import Foundation
import Combine

/// One-click replay of a past coding goal (engine + workspace + prompt).
struct WorkRecipe: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var goal: String
    var workspacePath: String?
    var engineRaw: String
    var createdAt: Date
    var useCount: Int

    init(
        id: UUID = UUID(),
        title: String,
        goal: String,
        workspacePath: String? = nil,
        engineRaw: String,
        createdAt: Date = .now,
        useCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.workspacePath = workspacePath
        self.engineRaw = engineRaw
        self.createdAt = createdAt
        self.useCount = useCount
    }

    var engine: CodingEngineKind {
        CodingEngineKind(rawValue: engineRaw) ?? .auto
    }
}

@MainActor
final class WorkRecipeStore: ObservableObject {
    static let shared = WorkRecipeStore()

    @Published private(set) var recipes: [WorkRecipe] = []

    private let storeName = "work_recipes_v1"
    private let maxRecipes = 40

    init() { load() }

    func add(title: String, goal: String, workspacePath: String?, engine: CodingEngineKind) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { return }
        let recipe = WorkRecipe(
            title: t.isEmpty ? String(g.prefix(48)) : t,
            goal: g,
            workspacePath: workspacePath,
            engineRaw: engine.rawValue
        )
        recipes.insert(recipe, at: 0)
        if recipes.count > maxRecipes {
            recipes = Array(recipes.prefix(maxRecipes))
        }
        persist()
    }

    func recordUse(_ id: UUID) {
        guard let i = recipes.firstIndex(where: { $0.id == id }) else { return }
        recipes[i].useCount += 1
        // Move to top
        let r = recipes.remove(at: i)
        recipes.insert(r, at: 0)
        persist()
    }

    func delete(_ id: UUID) {
        recipes.removeAll { $0.id == id }
        persist()
    }

    func recipes(forWorkspace path: String?) -> [WorkRecipe] {
        guard let path else { return recipes }
        let root = (path as NSString).standardizingPath
        let matched = recipes.filter {
            guard let p = $0.workspacePath else { return true }
            return (p as NSString).standardizingPath == root
        }
        return matched.isEmpty ? recipes : matched
    }

    private func load() {
        if let loaded: [WorkRecipe] = JSONStore.load([WorkRecipe].self, name: storeName) {
            recipes = loaded
        }
    }

    private func persist() {
        JSONStore.save(recipes, name: storeName)
    }
}
