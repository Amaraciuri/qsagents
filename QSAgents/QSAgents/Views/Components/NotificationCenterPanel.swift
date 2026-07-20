import SwiftUI

/// Dropdown panel for the top-bar bell — in-app activity feed.
struct NotificationCenterPanel: View {
    @EnvironmentObject private var notices: AppNotificationCenter
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var terminals: TerminalManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(QS.Color.border)

            if notices.notices.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(notices.notices) { notice in
                            noticeRow(notice)
                            Divider().overlay(QS.Color.border.opacity(0.5))
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Divider().overlay(QS.Color.border)
            footer
        }
        .frame(width: 340)
        .background(QS.Color.surfaceLow)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(QS.Color.primary)
            Text("Centro notifiche")
                .font(QS.Font.ui(13, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)
            if notices.unreadCount > 0 {
                Text("\(notices.unreadCount)")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(QS.Color.agentError)
                    .clipShape(Capsule())
            }
            Spacer()
            if notices.hasUnread {
                Button("Segna lette") {
                    notices.markAllRead()
                }
                .buttonStyle(.plain)
                .font(QS.Font.ui(11, weight: .medium))
                .foregroundStyle(QS.Color.primary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(QS.Color.outline)
            Text("Nessuna notifica")
                .font(QS.Font.ui(13, weight: .medium))
                .foregroundStyle(QS.Color.onSurface)
            Text("Qui compaiono terminali terminati,\ntask completate, safety e orchestratore.")
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
    }

    private func noticeRow(_ notice: AppNotice) -> some View {
        Button {
            notices.markRead(notice.id)
            route(notice)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    let tint = notice.kind.tintHex.hexUInt32 ?? 0x94A3B8
                    Circle()
                        .fill(Color(hex: tint, opacity: 0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: notice.kind.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: tint))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(notice.title)
                            .font(QS.Font.ui(12, weight: notice.isRead ? .medium : .semibold))
                            .foregroundStyle(QS.Color.onSurface)
                            .lineLimit(1)
                        if !notice.isRead {
                            Circle()
                                .fill(QS.Color.primarySolid)
                                .frame(width: 6, height: 6)
                        }
                        Spacer(minLength: 4)
                        Text(relativeTime(notice.timestamp))
                            .font(QS.Font.mono(9))
                            .foregroundStyle(QS.Color.outline)
                    }
                    Text(notice.body)
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(notice.isRead ? Color.clear : QS.Color.primarySolid.opacity(0.06))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Segna come letta") { notices.markRead(notice.id) }
            Button("Apri") {
                notices.markRead(notice.id)
                route(notice)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Svuota") {
                notices.clearAll()
            }
            .buttonStyle(.plain)
            .font(QS.Font.ui(11, weight: .medium))
            .foregroundStyle(QS.Color.outline)
            .disabled(notices.notices.isEmpty)

            Spacer()

            Button("Chiudi") {
                notices.showPanel = false
            }
            .buttonStyle(.plain)
            .font(QS.Font.ui(11, weight: .semibold))
            .foregroundStyle(QS.Color.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func route(_ notice: AppNotice) {
        notices.showPanel = false
        switch notice.kind {
        case .terminalDone, .terminalFailed:
            state.navigate(to: .dashboard)
            if let id = notice.relatedTerminalID {
                terminals.select(id)
            }
        case .task:
            state.navigate(to: .orchestrator)
            state.orchestratorMode = .tasks
        case .orchestrator:
            state.openOrchestratorModal()
        case .safety:
            state.openSafety()
        case .info:
            break
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "ora" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))g"
    }
}

// MARK: - Hex helper for notice tints (string "22C55E")

private extension String {
    var hexUInt32: UInt32? {
        var s = trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return v
    }
}
