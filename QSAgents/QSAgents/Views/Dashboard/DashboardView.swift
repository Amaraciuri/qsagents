import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var state: AppState

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        HStack(spacing: 0) {
            dashboardSidebar
            mainGrid
            if state.showSkillsPanel {
                SkillsPanel()
            }
        }
    }

    // MARK: - Left rail

    private var dashboardSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Workspaces")
                Spacer()
                Text("\(state.workspaces.count) attivi")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                Button {
                    // new workspace
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            VStack(spacing: 4) {
                ForEach(state.workspaces) { ws in
                    HStack(spacing: 10) {
                        Image(systemName: ws.icon)
                            .font(.system(size: 12))
                        Text(ws.name)
                            .font(QS.Font.body)
                        Spacer()
                        if ws.isActive {
                            Circle().fill(QS.Color.agentActive).frame(width: 6, height: 6)
                        }
                    }
                    .foregroundStyle(ws.isActive ? .white : QS.Color.onSurfaceVariant)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: QS.Radius.md, style: .continuous)
                            .fill(ws.isActive ? QS.Color.purpleAccent : .clear)
                    )
                    .padding(.horizontal, 8)
                }
            }

            Spacer()

            VStack(spacing: 2) {
                SidebarNavRow(title: "Terminale", icon: "terminal", selected: true) {
                    state.mainTab = .dashboard
                }
                SidebarNavRow(title: "Impostazioni", icon: "gearshape", selected: false) {
                    state.openIntegrations()
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .frame(width: 200)
        .background(QS.Color.surfaceSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }

    // MARK: - Grid

    private var mainGrid: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(state.agents) { agent in
                        if agent.isPlaceholder {
                            NewAgentCard { state.addNewAgent() }
                        } else {
                            AgentTerminalCard(
                                agent: agent,
                                isSelected: state.selectedAgentID == agent.id,
                                draft: Binding(
                                    get: { state.commandDrafts[agent.id] ?? "" },
                                    set: { state.commandDrafts[agent.id] = $0 }
                                ),
                                onSelect: { state.selectedAgentID = agent.id },
                                onClose: { state.closeAgent(agent.id) },
                                onSubmit: { state.sendCommand(to: agent.id) }
                            )
                        }
                    }
                }
                .padding(12)
                .padding(.bottom, 56)
            }

            // floating metrics
            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    Circle().fill(QS.Color.agentActive).frame(width: 7, height: 7)
                    Text("\(state.activeAgentCount) Agenti Attivi")
                        .font(QS.Font.ui(11, weight: .medium))
                }
                metric("CPU", "\(state.cpuPercent)%")
                metric("MEM", String(format: "%.1fGB", state.memGB))
                metric("TOKEN/S", "\(state.tokensPerSec)")
            }
            .foregroundStyle(QS.Color.onSurface)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(QS.Color.border, lineWidth: 1))
            .padding(.bottom, 14)
        }
        .background(QS.Color.backgroundDeep)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func metric(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).font(QS.Font.labelXS).foregroundStyle(QS.Color.outline)
            Text(v).font(QS.Font.labelXS).foregroundStyle(QS.Color.onSurfaceVariant)
        }
    }
}

// MARK: - Agent card

struct AgentTerminalCard: View {
    let agent: AgentInstance
    let isSelected: Bool
    @Binding var draft: String
    var onSelect: () -> Void
    var onClose: () -> Void
    var onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let cpu = agent.cpuUsage {
                ActivityGauge(progress: cpu, tint: QS.Color.agentActive)
            }

            // header
            HStack(spacing: 8) {
                StatusLED(status: agent.status)
                Text(agent.name)
                    .font(QS.Font.ui(12, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(agent.modelTag)
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(QS.Color.surfaceHighest)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(QS.Color.outline)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(QS.Color.surfaceHigh.opacity(0.35))

            // log stream
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(agent.lines) { line in
                            TerminalLineView(line: line)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: agent.lines.count) { _, _ in
                    if let last = agent.lines.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 160)

            Divider().overlay(QS.Color.border)

            // command input
            HStack(spacing: 8) {
                Text("$")
                    .font(QS.Font.codeSM)
                    .foregroundStyle(QS.Color.primary)
                TextField(agent.promptPlaceholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(QS.Font.codeSM)
                    .foregroundStyle(QS.Color.onSurface)
                    .onSubmit(onSubmit)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(minHeight: 220)
        .qsCard(focused: isSelected)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

struct NewAgentCard: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(QS.Color.outline)
                Text("NUOVO AGENTE")
                    .font(QS.Font.labelXS)
                    .tracking(1)
                    .foregroundStyle(QS.Color.outline)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .qsCard()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Skills panel

struct SkillsPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Terminals + Skills")
                    .font(QS.Font.ui(13, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                Spacer()
                Button {
                    state.showSkillsPanel = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(QS.Color.outline)
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            if let active = state.skills.first(where: { $0.isActive }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SKILL ATTIVA")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.primary)
                    HStack(spacing: 6) {
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundStyle(QS.Color.agentActive)
                        Text(active.name)
                            .font(QS.Font.ui(12, weight: .semibold))
                    }
                    Text("Trascina questa skill su un terminale per attivarla.")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QS.Color.primarySolid.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: QS.Radius.lg)
                        .stroke(QS.Color.primarySolid.opacity(0.35), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: QS.Radius.lg))
                .padding(.horizontal, 12)
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(state.skills) { skill in
                        skillCard(skill)
                    }
                }
                .padding(12)
            }

            Spacer(minLength: 0)

            Button {
                // add skill
            } label: {
                HStack {
                    Image(systemName: "plus")
                    Text("AGGIUNGI SKILL")
                        .font(QS.Font.ui(12, weight: .semibold))
                }
                .foregroundStyle(QS.Color.onPrimaryFixed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(QS.Color.primary)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 280)
        .background(QS.Color.surfaceLow)
        .overlay(alignment: .leading) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }

    private func skillCard(_ skill: AgentSkill) -> some View {
        Button {
            state.applySkill(skill, to: state.selectedAgentID)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: skill.category.icon)
                        .foregroundStyle(skill.category.tint)
                    Spacer()
                    Text(skill.category.rawValue)
                        .font(QS.Font.labelXS)
                        .foregroundStyle(skill.category.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(skill.category.tint.opacity(0.12))
                        .clipShape(Capsule())
                }
                Text(skill.name)
                    .font(QS.Font.ui(13, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                Text(skill.description)
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: QS.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: QS.Radius.lg, style: .continuous)
                    .stroke(QS.Color.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private extension QS.Color {
    static let onPrimaryFixed = SwiftUI.Color(hex: 0x001B3E)
}
