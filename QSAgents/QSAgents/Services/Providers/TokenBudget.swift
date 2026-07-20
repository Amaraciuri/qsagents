import Foundation

/// Central knobs for LLM token economy (orchestrator + swarm agents).
/// Goal: builders must **work**, not burn budget on list_dir / full-file dumps / mirror dupes.
enum TokenBudget {
    // MARK: - Agent loop (sub-agents)

    /// Soft stop per agent session (usage.totalTokens from API).
    /// Leave headroom: check fires *before* next call when remaining < reserve.
    static let agentSessionBudget = 26_000
    /// Don't start another LLM call if already this close to budget.
    static let agentBudgetReserve = 3_000
    /// Max completion tokens per agent LLM call — must fit propose_patch JSON (CSS/JS).
    static let agentMaxCompletion = 3_200
    /// OpenRouter reserves/bills against `max_tokens`; keep lower so low-balance accounts don't 402 on step 1.
    static let openRouterAgentMaxCompletion = 2_048
    /// Floor when retrying after HTTP 402 "can only afford N".
    static let openRouterMinCompletion = 768
    /// Max messages kept in agent history (system + goal + turns).
    /// Higher than early token-economy defaults so id/class/CSS context survives like Cursor.
    static let agentHistoryMessages = 14
    /// Cap each tool result embedded into the next prompt.
    static let agentToolResultChars = 900
    /// Capsule is the structure-first payload — keep most of it in history (deduped).
    static let agentToolResultCapsuleChars = 2_400
    /// Compact locator from code-brain (paths only) — cheap alternate to full capsule.
    static let agentToolResultLocateChars = 1_400
    /// Cap combined tool results for one step.
    static let agentToolResultsTotalChars = 5_200
    /// Cap tool-call JSON echoed into history.
    static let agentToolCallRawChars = 400
    /// After this many *wasteful* explore steps, soft-nudge toward useful progress (not forced patch).
    static let builderMaxExploreSteps = 6
    /// Token budget for ProjectCodeBrain.capsule (chars ≈ tokens×4).
    static let repoCapsuleTokens = 1_800

    /// Default max loop steps by role.
    static func agentMaxSteps(for role: AgentRole) -> Int {
        switch role {
        case .scout: return 6
        case .coordinator: return 10
        case .builder: return 12
        case .reviewer: return 6
        case .general, .deployer: return 10
        }
    }

    // MARK: - Goal Mode (orchestrator drives to completion; higher spend OK)

    /// Soft stop when GOAL MODE mission is active — allow deeper work per mini-task.
    static let goalAgentSessionBudget = 48_000
    static let goalAgentBudgetReserve = 4_000
    static let goalAgentMaxCompletion = 4_000
    static let openRouterGoalAgentMaxCompletion = 2_560
    /// Max auto-splits when a builder stalls (token/max steps/error).
    /// Keep low: each split can spawn 3 agents × ~48k → runaway cost without UI progress.
    static let goalModeMaxSplits = 2

    /// Provider-aware completion cap (OpenRouter 402s when max_tokens > affordable balance).
    static func agentMaxCompletion(provider: LLMProviderKind, goalMode: Bool) -> Int {
        if provider == .openRouter {
            return goalMode ? openRouterGoalAgentMaxCompletion : openRouterAgentMaxCompletion
        }
        return goalMode ? goalAgentMaxCompletion : agentMaxCompletion
    }

    static func goalAgentMaxSteps(for role: AgentRole) -> Int {
        switch role {
        case .scout: return 8
        case .coordinator: return 12
        case .builder: return 18
        case .reviewer: return 8
        case .general, .deployer: return 14
        }
    }

    // MARK: - Orchestrator chat

    static let orchestratorMaxCompletion = 900
    static let orchestratorMemoryTurns = 4
    static let orchestratorMemoryLineChars = 160
    static let orchestratorContextProjects = 6

    // MARK: - Tool I/O returned to LLM

    static let toolListEntries = 40
    /// Default max chars for unscoped read_file (prefer start_line / around).
    static let toolReadChars = 5_500
    /// Default window when reading with around/start_line.
    static let toolReadWindowLines = 90
    /// Hard cap for propose_patch / write content (bytes).
    static let toolPatchChars = 96_000
    static let toolCommandOutChars = 3_500
    static let knowledgeHitLimit = 6

    /// Per-tool history budget (repo_capsule gets more so agents stop re-grepping).
    static func historyClipLimit(for name: AgentToolName) -> Int {
        switch name {
        case .repo_capsule: return agentToolResultCapsuleChars
        case .search_knowledge: return agentToolResultLocateChars
        default: return agentToolResultChars
        }
    }

    /// Console UI (Swarm / Terminali) — not sent fully to the next LLM turn.
    static func uiLogLimit(for name: AgentToolName) -> Int {
        switch name {
        case .repo_capsule: return 10_000
        case .propose_patch, .apply_patch, .read_file: return 8_000
        case .search_knowledge, .list_dir: return 4_000
        case .run_command, .git_log, .git_status: return 5_000
        default: return 4_000
        }
    }
}
