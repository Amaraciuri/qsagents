import Foundation
import Combine

/// In-app notification for the top-bar bell (terminals done, tasks, safety, orchestrator).
struct AppNotice: Identifiable, Equatable {
    let id: UUID
    var title: String
    var body: String
    var kind: Kind
    var timestamp: Date
    var isRead: Bool
    var relatedTerminalID: UUID?
    var relatedTaskID: UUID?

    enum Kind: String, Equatable {
        case terminalDone
        case terminalFailed
        case task
        case orchestrator
        case safety
        case info

        var icon: String {
            switch self {
            case .terminalDone: return "terminal.fill"
            case .terminalFailed: return "exclamationmark.triangle.fill"
            case .task: return "checklist"
            case .orchestrator: return "sparkles"
            case .safety: return "shield.lefthalf.filled"
            case .info: return "bell.fill"
            }
        }

        var tintHex: String {
            switch self {
            case .terminalDone: return "22C55E"
            case .terminalFailed: return "EF4444"
            case .task: return "3B82F6"
            case .orchestrator: return "A78BFA"
            case .safety: return "F59E0B"
            case .info: return "94A3B8"
            }
        }
    }

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        kind: Kind,
        timestamp: Date = .now,
        isRead: Bool = false,
        relatedTerminalID: UUID? = nil,
        relatedTaskID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.timestamp = timestamp
        self.isRead = isRead
        self.relatedTerminalID = relatedTerminalID
        self.relatedTaskID = relatedTaskID
    }
}

@MainActor
final class AppNotificationCenter: ObservableObject {
    @Published private(set) var notices: [AppNotice] = []
    @Published var showPanel: Bool = false

    var unreadCount: Int { notices.filter { !$0.isRead }.count }
    var hasUnread: Bool { unreadCount > 0 }

    func post(
        _ title: String,
        body: String,
        kind: AppNotice.Kind = .info,
        terminalID: UUID? = nil,
        taskID: UUID? = nil
    ) {
        let n = AppNotice(
            title: title,
            body: body,
            kind: kind,
            relatedTerminalID: terminalID,
            relatedTaskID: taskID
        )
        notices.insert(n, at: 0)
        if notices.count > 80 {
            notices = Array(notices.prefix(80))
        }
        AppLogger.info("Notice [\(kind.rawValue)]: \(title)")
    }

    func markRead(_ id: UUID) {
        guard let i = notices.firstIndex(where: { $0.id == id }) else { return }
        notices[i].isRead = true
    }

    func markAllRead() {
        for i in notices.indices {
            notices[i].isRead = true
        }
    }

    func clearAll() {
        notices.removeAll()
    }

    func togglePanel() {
        showPanel.toggle()
        if showPanel {
            // Opening panel does not auto-mark; user can clear
        }
    }
}
