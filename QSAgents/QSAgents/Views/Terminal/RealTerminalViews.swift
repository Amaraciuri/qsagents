import SwiftUI
import AppKit

// MARK: - Terminal grid layout

/// How many terminal panes per row (user-selectable).
enum TerminalGridLayout: String, CaseIterable, Identifiable {
    case one = "1"
    case two = "2"
    case three = "3"
    case four = "4"
    case six = "6"

    var id: String { rawValue }

    var columns: Int {
        switch self {
        case .one: return 1
        case .two: return 2
        case .three: return 3
        case .four: return 4
        case .six: return 6
        }
    }

    /// Short label for toolbar (e.g. 2+2+2, 4+4, 6+6).
    var menuLabel: String {
        switch self {
        case .one: return "1 colonna"
        case .two: return "2+2+2 (2 col)"
        case .three: return "3+3+3 (3 col)"
        case .four: return "4+4 (4 col)"
        case .six: return "6+6 (6 col)"
        }
    }

    var icon: String {
        switch self {
        case .one: return "rectangle"
        case .two: return "rectangle.split.2x1"
        case .three: return "rectangle.split.3x1"
        case .four: return "square.grid.2x2"
        case .six: return "square.grid.3x2"
        }
    }

    /// Pane min height scales down with more columns.
    var minPaneHeight: CGFloat {
        switch self {
        case .one: return 360
        case .two: return 280
        case .three: return 240
        case .four: return 200
        case .six: return 170
        }
    }

    private static let defaultsKey = "qs.terminals.gridLayout"

    static var stored: TerminalGridLayout {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let layout = TerminalGridLayout(rawValue: raw) {
            return layout
        }
        return .two
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

// MARK: - Terminal grid (Dashboard)

/// Console agent height under Terminali (match Swarm feel).
private enum AgentLogHeight: String, CaseIterable, Identifiable {
    case medium, large, xlarge
    var id: String { rawValue }
    var minH: CGFloat {
        switch self {
        case .medium: return 220
        case .large: return 300
        case .xlarge: return 380
        }
    }
    var idealH: CGFloat {
        switch self {
        case .medium: return 280
        case .large: return 360
        case .xlarge: return 480
        }
    }
    var maxH: CGFloat {
        switch self {
        case .medium: return 340
        case .large: return 480
        case .xlarge: return 640
        }
    }
}

/// Boost PTY pane height (persisted). Useful when Claude scrollback feels cramped.
private enum TerminalPaneSize: String, CaseIterable, Identifiable {
    case medium, large, xlarge, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .medium: return "M"
        case .large: return "L"
        case .xlarge: return "XL"
        case .max: return "MAX"
        }
    }
    /// Multiplier on grid `minPaneHeight`.
    var multiplier: CGFloat {
        switch self {
        case .medium: return 1.0
        case .large: return 1.35
        case .xlarge: return 1.7
        case .max: return 2.2
        }
    }
    private static let defaultsKey = "qs.terminals.paneSize"
    static var stored: TerminalPaneSize {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let v = TerminalPaneSize(rawValue: raw) { return v }
        return .large
    }
    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

struct RealTerminalsView: View {
    @EnvironmentObject private var terminals: TerminalManager
    @EnvironmentObject private var directories: DirectoryStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var agents: AgentSessionStore
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var git: GitService
    @State private var showGitPanel: Bool = false
    @State private var gridLayout: TerminalGridLayout = .stored
    /// Agent tool stream under PTY (same console as Swarm — not shell scrollback).
    @State private var showAgentLog: Bool = true
    @State private var agentLogHeight: AgentLogHeight = .large
    @State private var paneSize: TerminalPaneSize = .stored
    /// Custom agent-console height when user drags the splitter (nil = use preset).
    @State private var agentLogCustomH: CGFloat? = {
        let v = UserDefaults.standard.double(forKey: "qs.terminals.agentLogCustomH")
        return v >= 160 ? v : nil
    }()
    @State private var agentLogDragStart: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            if state.showLeftSidebar {
                DirectorySidebarView(
                    onOpenTerminal: { path in
                        // Opening a project from the rail always anchors the workspace
                        _ = workspaces.open(path: path)
                        terminals.openTerminal(at: path)
                        directories.rememberRecent(path: path)
                        git.setPath(path)
                    }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                CollapsedSideRail(
                    edge: .leading,
                    help: "Mostra sidebar workspace (⌘B)"
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) { state.showLeftSidebar = true }
                }
            }

            VStack(spacing: 0) {
                terminalToolbar
                if !agents.sessions.isEmpty {
                    agentStrip
                }
                if terminals.sessions.isEmpty {
                    emptyState
                } else {
                    terminalSplit
                }
                // Agent tool/LLM console — same AgentTerminalDock as QS Swarm (tabs + full multi-line log)
                if !agents.sessions.isEmpty {
                    if showAgentLog {
                        VStack(spacing: 0) {
                            // Drag handle — pull up to grow PTY / shrink console, pull down to grow console
                            terminalAgentSplitter

                            HStack(spacing: 10) {
                                Text("Console agent (come Swarm)")
                                    .font(QS.Font.ui(11, weight: .semibold))
                                    .foregroundStyle(QS.Color.onSurfaceVariant)
                                Text("tool stream · non è lo shell PTY sopra")
                                    .font(QS.Font.labelXS)
                                    .foregroundStyle(QS.Color.outline)
                                Spacer()
                                Picker("Altezza", selection: $agentLogHeight) {
                                    Text("M").tag(AgentLogHeight.medium)
                                    Text("L").tag(AgentLogHeight.large)
                                    Text("XL").tag(AgentLogHeight.xlarge)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 120)
                                .help("Preset altezza console agent (resetta drag)")
                                .onChange(of: agentLogHeight) { _, _ in
                                    agentLogCustomH = nil
                                    UserDefaults.standard.removeObject(forKey: "qs.terminals.agentLogCustomH")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)

                            AgentTerminalDock(
                                sessions: agents.sessions,
                                selectedID: $agents.selectedID,
                                pulse: false,
                                onStop: { id in agents.stop(id) },
                                onClose: { withAnimation { showAgentLog = false } }
                            )
                            .frame(
                                minHeight: resolvedAgentLogH,
                                idealHeight: resolvedAgentLogH,
                                maxHeight: max(resolvedAgentLogH, agentLogHeight.maxH)
                            )
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    } else {
                        HStack {
                            Text("Log agent nascosto — i Terminali mostrano solo lo shell PTY. Apri la console come su Swarm.")
                                .font(QS.Font.ui(11))
                                .foregroundStyle(QS.Color.outline)
                            Spacer()
                            Button {
                                withAnimation { showAgentLog = true }
                                if agents.selectedID == nil {
                                    agents.selectedID = agents.sessions.first?.id
                                }
                            } label: {
                                Label("Mostra log agent", systemImage: "text.alignleft")
                                    .font(QS.Font.ui(11, weight: .semibold))
                                    .foregroundStyle(QS.Color.primarySolid)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(QS.Color.surfaceContainer.opacity(0.85))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showGitPanel {
                GitPanelView(compact: true)
                    .frame(width: 300)
                    .background(QS.Color.surfaceLow)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(QS.Color.border).frame(width: 1)
                    }
            } else if state.showRightSidebar {
                SystemContextPanel()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                CollapsedSideRail(
                    edge: .trailing,
                    help: "Mostra pannello contesto (⌘⌥B)"
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) { state.showRightSidebar = true }
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.showLeftSidebar)
        .animation(.easeInOut(duration: 0.15), value: state.showRightSidebar)
        .onChange(of: terminals.selectedID) { _, _ in
            // Keep Git pinned to the open workspace — terminal cwd often drifts to $HOME
            // or another folder and made Changes/Log look "stuck" on the wrong repo.
            if let path = workspaces.current?.path {
                git.setPath(path)
            }
        }
    }

    private var agentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("AGENT · clic = log tool")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                ForEach(agents.sessions) { session in
                    Button {
                        agents.selectedID = session.id
                        withAnimation { showAgentLog = true }
                    } label: {
                        HStack(spacing: 6) {
                            StatusLED(status: session.status, size: 6)
                            Text(session.name)
                                .font(QS.Font.ui(11, weight: .medium))
                                .foregroundStyle(QS.Color.onSurface)
                            Text(session.role.rawValue)
                                .font(QS.Font.labelXS)
                                .foregroundStyle(QS.Color.outline)
                            Text("\(session.lines.count) log")
                                .font(QS.Font.mono(9))
                                .foregroundStyle(QS.Color.primarySolid)
                            if session.tokenUsage > 0 {
                                Text("\(session.tokenUsage)t")
                                    .font(QS.Font.labelXS)
                                    .foregroundStyle(QS.Color.outline)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            agents.selectedID == session.id
                                ? QS.Color.primarySolid.opacity(0.16)
                                : QS.Color.surfaceContainer
                        )
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(
                            agents.selectedID == session.id
                                ? QS.Color.primarySolid
                                : (session.status == .thinking ? QS.Color.agentThinking.opacity(0.7) : QS.Color.border),
                            lineWidth: 1
                        ))
                    }
                    .buttonStyle(.plain)
                    .help("Apri log tool/LLM di \(session.name) (non è lo shell sotto)")
                    .contextMenu {
                        Button("Apri log") {
                            agents.selectedID = session.id
                            showAgentLog = true
                        }
                        Button("Stop") { agents.stop(session.id) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(QS.Color.surfaceLow.opacity(0.8))
    }

    private var terminalToolbar: some View {
        VStack(spacing: 0) {
            // Active workspace banner — always clear where you are working
            if let ws = workspaces.current {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QS.Color.primary)
                    Text("Workspace")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                    Text(ws.name)
                        .font(QS.Font.ui(12, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text(ws.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(QS.Font.codeSM)
                        .foregroundStyle(QS.Color.outline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let sel = terminals.selected {
                        HStack(spacing: 4) {
                            Circle().fill(sel.isAlive ? QS.Color.agentActive : QS.Color.agentIdle).frame(width: 6, height: 6)
                            Text("Attivo: \(sel.title)")
                                .font(QS.Font.ui(11, weight: .medium))
                                .foregroundStyle(QS.Color.primary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(QS.Color.primarySolid.opacity(0.12))
                        .clipShape(Capsule())
                        .help("Terminale selezionato — ⌘K parla/scrive su questo")
                    }
                    Button {
                        terminals.openTerminal(at: ws.path, title: ws.name)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.rectangle.on.folder")
                            Text("Apri qui")
                        }
                        .font(QS.Font.ui(11, weight: .medium))
                        .foregroundStyle(QS.Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help("Apri un terminale nel workspace \(ws.name)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(QS.Color.primarySolid.opacity(0.08))
            }

            HStack(spacing: 10) {
            Text("Terminali")
                .font(QS.Font.ui(13, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)

            Text("\(terminals.activeCount) live")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.agentActive)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(QS.Color.agentActive.opacity(0.12))
                .clipShape(Capsule())

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(terminals.sessions) { session in
                        TerminalTab(
                            session: session,
                            selected: terminals.selectedID == session.id,
                            onSelect: { terminals.select(session.id) },
                            onClose: { terminals.close(session.id) },
                            onRename: { terminals.rename(session.id, to: $0) }
                        )
                    }
                }
            }

            Spacer()

            // Grid layout picker (2+2+2 / 4+4 / 6+6 …)
            Menu {
                ForEach(TerminalGridLayout.allCases) { layout in
                    Button {
                        gridLayout = layout
                        layout.persist()
                    } label: {
                        HStack {
                            Image(systemName: layout.icon)
                            Text(layout.menuLabel)
                            if gridLayout == layout {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: gridLayout.icon)
                        .font(.system(size: 11, weight: .medium))
                    Text(gridLayout.rawValue + " col")
                        .font(QS.Font.ui(11, weight: .medium))
                }
                .foregroundStyle(QS.Color.onSurface)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(QS.Color.surfaceHigh)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .help("Layout griglia: 2+2+2, 4+4, 6+6…")

            // Quick layout chips
            HStack(spacing: 3) {
                ForEach(TerminalGridLayout.allCases) { layout in
                    Button {
                        gridLayout = layout
                        layout.persist()
                    } label: {
                        Text(layout.rawValue)
                            .font(QS.Font.labelXS)
                            .foregroundStyle(gridLayout == layout ? .white : QS.Color.outline)
                            .frame(width: 22, height: 22)
                            .background(gridLayout == layout ? QS.Color.primarySolid : QS.Color.surfaceHigh)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help(layout.menuLabel)
                }
            }

            // PTY height — make Claude / shell panes taller
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(QS.Color.outline)
                ForEach(TerminalPaneSize.allCases) { size in
                    Button {
                        paneSize = size
                        size.persist()
                        if size == .max || size == .xlarge {
                            // Free vertical room for PTY
                            agentLogHeight = .medium
                            agentLogCustomH = nil
                            UserDefaults.standard.removeObject(forKey: "qs.terminals.agentLogCustomH")
                        }
                    } label: {
                        Text(size.label)
                            .font(QS.Font.labelXS)
                            .foregroundStyle(paneSize == size ? .white : QS.Color.outline)
                            .padding(.horizontal, 6)
                            .frame(height: 22)
                            .background(paneSize == size ? QS.Color.primarySolid : QS.Color.surfaceHigh)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Altezza pannelli terminal (PTY): \(size.label)")
                }
            }
            .help("Altezza terminali — MAX = più spazio per Claude")

            GitStatusStrip(onOpenPanel: {
                showGitPanel.toggle()
                if showGitPanel {
                    let path = workspaces.current?.path ?? terminals.selected?.cwd
                    if let path { git.setPath(path) }
                }
            })

            GhostButton(title: showGitPanel ? "Chiudi Git" : "Git", icon: "arrow.triangle.branch") {
                showGitPanel.toggle()
                if showGitPanel {
                    let path = workspaces.current?.path ?? terminals.selected?.cwd
                    if let path { git.setPath(path) }
                }
            }

            GhostButton(title: "Cartella…", icon: "folder") {
                terminals.pickDirectoryAndOpen()
            }
            PrimaryButton(title: "Nuovo Terminale", icon: "plus", compact: true) {
                let path = workspaces.current?.path ?? terminals.selected?.cwd ?? NSHomeDirectory()
                let title = workspaces.current?.name
                terminals.openTerminal(at: path, title: title)
            }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(QS.Color.surfaceLow)
        .overlay(alignment: .bottom) {
            Rectangle().fill(QS.Color.border).frame(height: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(QS.Color.outline)
            Text("Nessun terminale aperto")
                .font(QS.Font.headline)
                .foregroundStyle(QS.Color.onSurface)
            Text("Apri un terminale reale del Mac (PTY + \(ProcessInfo.processInfo.environment["SHELL"] ?? "zsh")).\nOppure chiedi all'Orchestratore: “apri terminale in ~/qsagents”.")
                .font(QS.Font.body)
                .foregroundStyle(QS.Color.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 10) {
                PrimaryButton(title: "Apri in Home", icon: "house") {
                    terminals.openTerminal(at: NSHomeDirectory())
                }
                GhostButton(title: "Scegli cartella", icon: "folder.badge.plus") {
                    terminals.pickDirectoryAndOpen()
                }
                if let ws = workspaces.current {
                    GhostButton(title: "Terminale · \(ws.name)", icon: "folder") {
                        terminals.openTerminal(at: ws.path, title: ws.name)
                    }
                }
                GhostButton(title: "Parla con Orchestratore", icon: "bubble.left.and.bubble.right") {
                    state.openOrchestratorModal()
                }
            }

            if let err = terminals.lastError {
                Text(err)
                    .font(QS.Font.codeSM)
                    .foregroundStyle(QS.Color.error)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QS.Color.backgroundDeep)
    }

    private var resolvedAgentLogH: CGFloat {
        if let custom = agentLogCustomH {
            return min(720, max(140, custom))
        }
        return agentLogHeight.idealH
    }

    private var terminalAgentSplitter: some View {
        HStack {
            Spacer()
            RoundedRectangle(cornerRadius: 2)
                .fill(QS.Color.outline.opacity(0.55))
                .frame(width: 36, height: 4)
            Spacer()
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    // Drag down → taller agent console (shorter PTY); up → taller PTY
                    if agentLogDragStart == nil {
                        agentLogDragStart = agentLogCustomH ?? agentLogHeight.idealH
                    }
                    let next = min(720, max(140, (agentLogDragStart ?? 280) + value.translation.height))
                    agentLogCustomH = next
                }
                .onEnded { _ in
                    agentLogDragStart = nil
                    if let h = agentLogCustomH {
                        UserDefaults.standard.set(Double(h), forKey: "qs.terminals.agentLogCustomH")
                    }
                }
        )
        .help("Trascina: su = terminali più alti · giù = console agent più alta")
    }

    private var terminalSplit: some View {
        GeometryReader { geo in
            let count = max(terminals.sessions.count, 1)
            let cols = gridLayout.columns
            // For few sessions, don't force empty slots — use min(cols, count) when count < cols
            let effectiveCols = min(cols, max(count, 1))
            let rows = max(1, Int(ceil(Double(count) / Double(effectiveCols))))
            // Fit panes in viewport when possible (no scroll if they fit)
            let spacing: CGFloat = 8
            let availableH = max(200, geo.size.height - spacing * CGFloat(rows + 1))
            let targetMin = gridLayout.minPaneHeight * paneSize.multiplier
            let paneH = max(
                targetMin * 0.75,
                min(targetMin + 80, availableH / CGFloat(rows) - spacing)
            )

            let gridItems = Array(
                repeating: GridItem(.flexible(), spacing: spacing),
                count: effectiveCols
            )

            ScrollView {
                LazyVGrid(columns: gridItems, spacing: spacing) {
                    ForEach(terminals.sessions) { session in
                        let isSelected = terminals.selectedID == session.id
                        TerminalPaneView(session: session)
                            .frame(minHeight: paneH, idealHeight: paneH)
                            .frame(maxHeight: .infinity)
                            .onTapGesture { terminals.select(session.id) }
                            .qsCard(focused: isSelected)
                            .shadow(
                                color: isSelected ? QS.Color.primarySolid.opacity(0.35) : .clear,
                                radius: isSelected ? 10 : 0
                            )
                    }
                }
                .padding(spacing)
            }
            .background(QS.Color.backgroundDeep)
        }
    }
}

struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onRename: (String) -> Void

    @State private var isRenaming = false
    @State private var draftTitle = ""

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.isAlive ? QS.Color.agentActive : QS.Color.agentIdle)
                .frame(width: 6, height: 6)
                .fixedSize()
            if isRenaming {
                TextField("Nome", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(QS.Font.ui(11, weight: .semibold))
                    .frame(minWidth: 48, maxWidth: 100)
                    .onSubmit {
                        onRename(draftTitle)
                        isRenaming = false
                    }
                    .onExitCommand {
                        isRenaming = false
                    }
            } else {
                Button(action: onSelect) {
                    Text(session.title)
                        .font(QS.Font.ui(11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? QS.Color.onSurface : QS.Color.onSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 110, alignment: .leading)
                }
                .buttonStyle(.plain)
                .onTapGesture(count: 2) {
                    draftTitle = session.title
                    isRenaming = true
                }
                .help("Doppio click per rinominare")
            }
            // Close stays outside title — never covered by selection chrome
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(QS.Color.outline)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Chiudi terminale")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(selected ? QS.Color.primarySolid.opacity(0.18) : QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? QS.Color.primarySolid.opacity(0.75) : QS.Color.border, lineWidth: selected ? 1.5 : 1)
        )
        .fixedSize(horizontal: true, vertical: false)
        .contextMenu {
            Button("Rinomina…") {
                draftTitle = session.title
                isRenaming = true
            }
            Button("Chiudi", role: .destructive, action: onClose)
        }
    }
}

// MARK: - Terminal chrome colors

private enum TermChrome {
    static let bg = Color(red: 0.06, green: 0.07, blue: 0.09)
    static let headerBg = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let footerBg = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let text = Color(red: 0.78, green: 0.92, blue: 0.78)
    static let dim = Color(red: 0.45, green: 0.52, blue: 0.48)
    static let prompt = Color(red: 0.45, green: 0.85, blue: 0.55)
    static let selectionRing = QS.Color.primarySolid
    static let gutter = Color(red: 0.22, green: 0.26, blue: 0.24)
}

// MARK: - Virtualized output

/// Line-based terminal body — LazyVStack avoids re-layout of multi-MB strings.
struct TerminalOutputView: View {
    let lines: [String]
    let revision: UInt64
    let fontSize: CGFloat
    @Binding var stickToBottom: Bool

    private let bottomID = "term-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if lines.isEmpty || (lines.count == 1 && lines[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        Text("Shell pronto. Digita un comando sotto, oppure avvia un agent: i tool appaiono qui (e nel log sotto).")
                            .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                            .foregroundStyle(TermChrome.text.opacity(0.55))
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                            .foregroundStyle(TermChrome.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(TermChrome.bg)
            .onChange(of: revision) { _, _ in
                guard stickToBottom else { return }
                // Defer to next runloop so LazyVStack has laid out new rows.
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.05)) {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        // User is scrolling manually — unlock stick.
                        if stickToBottom { stickToBottom = false }
                    }
            )
        }
    }
}

// MARK: - Single pane

struct TerminalPaneView: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var terminals: TerminalManager
    @State private var commandLine: String = ""
    /// Default OFF: line input is reliable. Raw = type into PTY directly (no double-echo).
    @State private var useRawKeys: Bool = false
    @State private var findQuery: String = ""
    @State private var findHit: String?
    @State private var showFind = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var stickToBottom = true
    @State private var fontSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "qs.term.fontSize")
        return stored >= 10 && stored <= 22 ? stored : 12
    }()
    @FocusState private var lineFieldFocused: Bool

    private var isSelected: Bool { terminals.selectedID == session.id }

    private var shortCwd: String {
        session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if showFind || findHit != nil {
                findBar
            }
            outputArea
            commandBar
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? TermChrome.selectionRing.opacity(0.85) : QS.Color.border.opacity(0.6),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .onAppear {
            session.resize(cols: 120, rows: 32)
            if isSelected { lineFieldFocused = true }
        }
        .onChange(of: terminals.selectedID) { _, id in
            if id == session.id { lineFieldFocused = true }
        }
        .onChange(of: fontSize) { _, size in
            UserDefaults.standard.set(Double(size), forKey: "qs.term.fontSize")
        }
    }

    // MARK: Header
    // Two zones: left (title/path) shrinks; right (actions) never collapses under badges.

    private var headerBar: some View {
        HStack(spacing: 0) {
            // ── Left: identity (may truncate) ───────────────────────────
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(session.isAlive ? QS.Color.agentActive.opacity(0.25) : QS.Color.agentIdle.opacity(0.2))
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(session.isAlive ? QS.Color.agentActive : QS.Color.agentIdle)
                        .frame(width: 7, height: 7)
                }
                .fixedSize()

                if isRenaming {
                    TextField("Nome terminale", text: $draftTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(QS.Font.ui(12, weight: .semibold))
                        .frame(minWidth: 60, maxWidth: 140)
                        .onSubmit {
                            terminals.rename(session.id, to: draftTitle)
                            isRenaming = false
                        }
                } else {
                    Text(session.title)
                        .font(QS.Font.ui(12, weight: .semibold))
                        .foregroundStyle(isSelected ? QS.Color.primary : QS.Color.onSurface)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .onTapGesture(count: 2) {
                            draftTitle = session.title
                            isRenaming = true
                        }
                        .help("Doppio click per rinominare")
                }

                // Selection badge stays with the title (not near close button)
                if isSelected {
                    Text("⌘K")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(QS.Color.primarySolid)
                        .clipShape(Capsule())
                        .fixedSize()
                        .layoutPriority(2)
                        .help("Terminale selezionato — orchestratore e voce usano questo pane")
                }

                if let code = session.exitCode {
                    Text("exit \(code)")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(code == 0 ? QS.Color.agentActive : QS.Color.error)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background((code == 0 ? QS.Color.agentActive : QS.Color.error).opacity(0.15))
                        .clipShape(Capsule())
                        .fixedSize()
                        .layoutPriority(2)
                }

                Text(shortCwd)
                    .font(QS.Font.mono(10))
                    .foregroundStyle(QS.Color.outline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(0)
                    .help(session.cwd)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)

            // ── Right: actions (never compressed under left content) ───
            HStack(spacing: 3) {
                Text("\(session.displayLines.count) ln")
                    .font(QS.Font.mono(9))
                    .foregroundStyle(TermChrome.dim)
                    .help("Righe nel buffer (max 8000)")

                if !stickToBottom {
                    Button {
                        stickToBottom = true
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(QS.Color.primary)
                            .frame(width: 22, height: 22)
                            .background(QS.Color.primarySolid.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Torna in fondo e segui l'output live")
                }

                Picker("", selection: Binding(
                    get: { session.agentRole },
                    set: { session.agentRole = $0 }
                )) {
                    ForEach(AgentRole.allCases) { role in
                        Text(role.rawValue).tag(role)
                    }
                }
                .labelsHidden()
                .frame(width: 88)
                .controlSize(.mini)
                .help("Ruolo safety per i comandi di questo terminale")

                fontControls

                headerIconButton("magnifyingglass", help: "Cerca nel buffer") {
                    withAnimation(.easeInOut(duration: 0.15)) { showFind.toggle() }
                    if !showFind { findHit = nil }
                }
                headerIconButton("doc.on.doc", help: "Copia tutto l'output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.displayText, forType: .string)
                }
                headerIconButton("eraser", help: "Pulisci schermo (non chiude il PTY)") {
                    session.clear()
                    stickToBottom = true
                }
                headerIconButton("arrow.clockwise", help: "Riavvia shell") {
                    terminals.restart(session.id)
                    stickToBottom = true
                }
                headerIconButton("pencil", help: "Rinomina") {
                    draftTitle = session.title
                    isRenaming = true
                }

                // Close always last, isolated from selection badge
                headerIconButton("trash", help: "Chiudi terminale", tint: QS.Color.agentError.opacity(0.9)) {
                    terminals.close(session.id)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(10)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            ZStack {
                TermChrome.headerBg
                if isSelected {
                    QS.Color.primarySolid.opacity(0.10)
                }
            }
        )
    }

    private var fontControls: some View {
        HStack(spacing: 2) {
            Button {
                fontSize = max(10, fontSize - 1)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(QS.Color.outline)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Riduci font")

            Button {
                fontSize = min(20, fontSize + 1)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(QS.Color.outline)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Ingrandisci font")
        }
    }

    private func headerIconButton(
        _ systemName: String,
        help: String,
        tint: Color = QS.Color.outline,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Find

    private var findBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(QS.Color.outline)
                TextField("Cerca nel buffer…", text: $findQuery)
                    .textFieldStyle(.plain)
                    .font(QS.Font.mono(11))
                    .foregroundStyle(QS.Color.onSurface)
                    .onSubmit { findHit = session.findInBuffer(findQuery) }
                Button("Trova") {
                    findHit = session.findInBuffer(findQuery)
                }
                .buttonStyle(.plain)
                .font(QS.Font.ui(11, weight: .medium))
                .foregroundStyle(QS.Color.primary)
                Button {
                    showFind = false
                    findHit = nil
                    findQuery = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(QS.Color.outline)
                }
                .buttonStyle(.plain)
            }
            if let findHit {
                Text(findHit)
                    .font(QS.Font.mono(10))
                    .foregroundStyle(QS.Color.agentThinking)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !findQuery.isEmpty {
                Text("Nessun risultato")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(QS.Color.surfaceHigh.opacity(0.6))
    }

    // MARK: Output

    private var outputArea: some View {
        ZStack(alignment: .bottomTrailing) {
            TerminalOutputView(
                lines: session.displayLines,
                revision: session.displayRevision,
                fontSize: fontSize,
                stickToBottom: $stickToBottom
            )

            // Raw keys only when enabled AND line field not focused
            if useRawKeys && session.isAlive && !lineFieldFocused {
                TerminalKeyCatcher { event in
                    handleKey(event)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !session.isAlive {
                Text("Shell terminata")
                    .font(QS.Font.ui(11, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture {
            if useRawKeys {
                lineFieldFocused = false
            } else {
                lineFieldFocused = true
            }
        }
    }

    // MARK: Command bar

    private var commandBar: some View {
        HStack(spacing: 8) {
            Text(useRawKeys ? "▸" : "$")
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundStyle(TermChrome.prompt)
                .frame(width: 14)

            TextField(
                session.isAlive
                    ? (useRawKeys ? "Raw mode — digita nel riquadro nero" : "comando…  ⏎ invia")
                    : "Sessione terminata — riavvia con ↻",
                text: $commandLine
            )
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, design: .monospaced))
            .foregroundStyle(QS.Color.onSurface)
            .disabled(!session.isAlive || useRawKeys)
            .focused($lineFieldFocused)
            .onSubmit { submitLine() }

            if !commandLine.isEmpty && session.isAlive && !useRawKeys {
                Button {
                    submitLine()
                } label: {
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QS.Color.primary)
                }
                .buttonStyle(.plain)
                .help("Invia comando")
            }

            Toggle(isOn: $useRawKeys) {
                Text("Raw")
                    .font(QS.Font.ui(10, weight: .medium))
                    .foregroundStyle(QS.Color.outline)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Raw: tasti diretti al PTY. Off: riga di comando (consigliato).")
            .onChange(of: useRawKeys) { _, raw in
                lineFieldFocused = !raw
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(TermChrome.footerBg)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(QS.Color.border.opacity(0.5))
                .frame(height: 1)
        }
    }

    private func submitLine() {
        guard session.isAlive else { return }
        stickToBottom = true
        if commandLine.isEmpty {
            session.send("\r")
            return
        }
        let decision = terminals.sendCommandLine(
            commandLine,
            to: session.id,
            source: "terminal-ui"
        )
        if case .block = decision { commandLine = ""; return }
        if case .requireConfirm = decision { return }
        if case .requireDualConfirm = decision { return }
        commandLine = ""
    }

    private func handleKey(_ event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
        // Ignore key-repeat doubles from stuck handlers: only process keyDown once
        if event.isARepeat { /* still send for hold-delete etc */ }

        switch event.keyCode {
        case 36: // return
            session.send("\r")
            return
        case 51: // delete
            session.send("\u{7f}")
            return
        case 123: session.send("\u{1b}[D"); return
        case 124: session.send("\u{1b}[C"); return
        case 125: session.send("\u{1b}[B"); return
        case 126: session.send("\u{1b}[A"); return
        case 48: session.send("\t"); return
        default: break
        }

        if event.modifierFlags.contains(.control),
           let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let scalar = ch.asciiValue, scalar >= 97 {
            let ctrl = UnicodeScalar(UInt8(scalar - 96))
            session.send(String(Character(ctrl)))
            return
        }

        // Prefer charactersIgnoringModifiers for plain letters; avoid empty/meta
        if let chars = event.characters, !chars.isEmpty {
            // Skip private-use / unprintable except space
            if chars.unicodeScalars.allSatisfy({ $0.value >= 32 || $0 == "\t" }) {
                session.send(chars)
            }
        }
    }
}

// MARK: - Key catcher (NSView)

struct TerminalKeyCatcher: NSViewRepresentable {
    var onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onKey = onKey
        return v
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onKey = onKey
    }

    final class KeyView: NSView {
        var onKey: ((NSEvent) -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Only take focus on click — not automatically (avoids fighting TextField)
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            // Do not call super — prevents AppKit from also inserting into a field
            onKey?(event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // Let ⌘ shortcuts bubble to the app
            if event.modifierFlags.contains(.command) {
                return super.performKeyEquivalent(with: event)
            }
            return false
        }

        override func draw(_ dirtyRect: NSRect) {
            // transparent hit target
        }
    }
}

// MARK: - System context side panel

struct SystemContextPanel: View {
    @EnvironmentObject private var probe: SystemProbe
    @EnvironmentObject private var terminals: TerminalManager
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sistema + Contesto")
                    .font(QS.Font.ui(13, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        state.showRightSidebar = false
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(QS.Color.outline)
                }
                .buttonStyle(.plain)
                .help("Nascondi pannello (⌘⌥B)")
            }
            .padding(14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    metricCard

                    SectionLabel(text: "Terminali aperti")
                    if terminals.sessions.isEmpty {
                        Text("Nessuno")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.outline)
                    } else {
                        ForEach(terminals.sessions) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Circle().fill(s.isAlive ? QS.Color.agentActive : QS.Color.agentIdle).frame(width: 6, height: 6)
                                    Text(s.title).font(QS.Font.ui(12, weight: .medium)).foregroundStyle(QS.Color.onSurface)
                                }
                                Text(s.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(QS.Font.codeSM)
                                    .foregroundStyle(QS.Color.outline)
                                    .lineLimit(2)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(QS.Color.surfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    SectionLabel(text: "Top processi")
                    ForEach(probe.snapshot.topProcesses.prefix(6)) { p in
                        HStack {
                            Text(p.name)
                                .font(QS.Font.codeSM)
                                .foregroundStyle(QS.Color.onSurfaceVariant)
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", p.cpu))
                                .font(QS.Font.labelXS)
                                .foregroundStyle(QS.Color.agentThinking)
                        }
                    }

                    if !probe.snapshot.listeningPorts.isEmpty {
                        SectionLabel(text: "Porte")
                        Text(probe.snapshot.listeningPorts.prefix(10).joined(separator: " · "))
                            .font(QS.Font.codeSM)
                            .foregroundStyle(QS.Color.primary)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 260)
        .background(QS.Color.surfaceLow)
        .overlay(alignment: .leading) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }

    private var metricCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(QS.Color.agentActive).frame(width: 7, height: 7)
                Text("LIVE")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.agentActive)
                Spacer()
                Text(probe.snapshot.hostname)
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
            }
            HStack {
                metric("CPU", String(format: "%.0f%%", probe.snapshot.cpuPercent))
                metric("RAM", String(format: "%.1fG", probe.snapshot.memoryUsedGB))
                metric("LOAD", String(format: "%.2f", probe.snapshot.loadAvg.0))
            }
            ActivityGauge(progress: min(1, probe.snapshot.cpuPercent / 100), tint: QS.Color.agentActive)
        }
        .padding(12)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: QS.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: QS.Radius.lg)
                .stroke(QS.Color.border, lineWidth: 1)
        )
    }

    private func metric(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(QS.Font.labelXS).foregroundStyle(QS.Color.outline)
            Text(v).font(QS.Font.ui(12, weight: .semibold)).foregroundStyle(QS.Color.onSurface)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
