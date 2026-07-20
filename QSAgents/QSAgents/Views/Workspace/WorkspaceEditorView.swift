import SwiftUI

struct WorkspaceEditorView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var terminals: TerminalManager
    @EnvironmentObject private var git: GitService
    @EnvironmentObject private var agents: AgentSessionStore
    @EnvironmentObject private var orchestrator: OrchestratorEngine
    @State private var showDiffSheet = false
    @State private var showPreview = false
    @State private var actionToast: String?
    /// Chat dock off by default — less clutter; open with one click in the toolbar.
    @State private var showWorkspaceChat = false
    @State private var chatDraft = ""
    @State private var pendingCloseTabID: UUID?
    @FocusState private var chatFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if state.showLeftSidebar {
                workspaceSidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                CollapsedSideRail(edge: .leading, help: "Mostra file tree (⌘B)") {
                    withAnimation(.easeInOut(duration: 0.15)) { state.showLeftSidebar = true }
                }
            }
            VStack(spacing: 0) {
                editorCenter
                if showWorkspaceChat {
                    workspaceChatDock
                        .frame(minHeight: 160, idealHeight: 200, maxHeight: 280)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    HStack {
                        Text("Chat orchestratore nascosta")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.outline)
                        Spacer()
                        Button {
                            withAnimation { showWorkspaceChat = true }
                        } label: {
                            Label("Mostra chat", systemImage: "bubble.left.and.bubble.right")
                                .font(QS.Font.ui(11, weight: .semibold))
                                .foregroundStyle(QS.Color.primarySolid)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(QS.Color.surfaceContainer.opacity(0.9))
                }
            }
            if state.showRightSidebar {
                rightInspector
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                CollapsedSideRail(edge: .trailing, help: "Mostra ispettore (⌘⌥B)") {
                    withAnimation(.easeInOut(duration: 0.15)) { state.showRightSidebar = true }
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.showLeftSidebar)
        .animation(.easeInOut(duration: 0.15), value: state.showRightSidebar)
        .onAppear {
            // Do NOT auto-switch to a "recent" workspace — stick to persisted current only.
            workspaces.openDefaultFileIfNeeded()
            bindGitToCurrentWorkspace()
        }
        .alert("Chiudere tab senza salvare?", isPresented: Binding(
            get: { pendingCloseTabID != nil },
            set: { if !$0 { pendingCloseTabID = nil } }
        )) {
            Button("Annulla", role: .cancel) { pendingCloseTabID = nil }
            Button("Chiudi senza salvare", role: .destructive) {
                if let id = pendingCloseTabID {
                    _ = workspaces.closeTab(id, force: true)
                }
                pendingCloseTabID = nil
            }
        } message: {
            Text("Le modifiche non salvate andranno perse.")
        }
        .onChange(of: workspaces.current?.path) { _, path in
            // Recent / Apri cartella aggiornano i file; Git deve seguire lo stesso progetto.
            if let path {
                git.setPath(path)
            } else {
                git.setPath(nil)
            }
        }
        .onChange(of: workspaces.current?.id) { _, _ in
            bindGitToCurrentWorkspace()
        }
        .onChange(of: git.status.changes) { _, changes in
            workspaces.syncGitDirty(root: git.workingPath ?? workspaces.current?.path, changes: changes)
        }
        .onChange(of: git.workingPath) { _, _ in
            workspaces.syncGitDirty(root: git.workingPath ?? workspaces.current?.path, changes: git.status.changes)
        }
        .sheet(isPresented: $showDiffSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Applica unified diff")
                    .font(QS.Font.headline)
                TextEditor(text: $workspaces.pendingDiffText)
                    .font(QS.Font.codeSM)
                    .frame(minHeight: 220)
                HStack {
                    Button("Annulla") { showDiffSheet = false }
                    Spacer()
                    Button("Applica patch") {
                        let msg = workspaces.applyUnifiedDiff(workspaces.pendingDiffText)
                        actionToast = msg
                        showDiffSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 560, height: 360)
        }
    }

    // MARK: Sidebar

    private var workspaceSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Workspace")
                Spacer()
                Button {
                    workspaces.pickAndOpen()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                        .foregroundStyle(QS.Color.primary)
                }
                .buttonStyle(.plain)
                .help("Apri cartella progetto")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if let current = workspaces.current {
                SidebarNavRow(
                    title: current.name,
                    icon: "folder.fill",
                    selected: true
                ) {}
                .padding(.horizontal, 8)
                Text(current.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(QS.Font.codeSM)
                    .foregroundStyle(QS.Color.outline)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            } else {
                Text("Nessun workspace")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)
                    .padding(.horizontal, 14)
                PrimaryButton(title: "Apri cartella…", icon: "folder", compact: true) {
                    workspaces.pickAndOpen()
                }
                .padding(12)
            }

            // Navigation lives in the top bar — keep this sidebar for files only.

            HStack {
                SectionLabel(text: "File")
                Spacer()
                Button {
                    workspaces.collapseAllFolders()
                } label: {
                    Image(systemName: "rectangle.compress.vertical")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(QS.Color.outline)
                }
                .buttonStyle(.plain)
                .help("Chiudi tutte le cartelle")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if workspaces.fileTree.isEmpty {
                        Text(workspaces.current == nil ? "Apri un workspace" : "Cartella vuota o in caricamento…")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.outline)
                            .padding(.horizontal, 12)
                    }
                    ForEach(workspaces.fileTree) { node in
                        RealFileTreeNode(
                            node: node,
                            depth: 0,
                            selectedPath: workspaces.openFilePath,
                            isDirty: workspaces.isPathDirty(node.path),
                            dirtyChild: node.isDirectory && workspaces.isPathDirty(node.path),
                            onToggle: { workspaces.toggleExpand($0) },
                            onOpen: { workspaces.openFile(path: $0) }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            if let err = workspaces.lastError {
                Text(err)
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.agentError)
                    .padding(10)
            }
        }
        .frame(width: 240)
        .background(QS.Color.surfaceSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }

    // MARK: Editor

    private var editorCenter: some View {
        VStack(spacing: 0) {
            // Multi-tab bar
            if !workspaces.tabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(workspaces.tabs) { tab in
                            HStack(spacing: 6) {
                                Button {
                                    workspaces.selectTab(tab.id)
                                } label: {
                                    Text(tab.name + (tab.isDirty ? " •" : ""))
                                        .font(QS.Font.ui(11, weight: workspaces.selectedTabID == tab.id ? .semibold : .regular))
                                        .foregroundStyle(workspaces.selectedTabID == tab.id ? QS.Color.onSurface : QS.Color.outline)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    if !workspaces.closeTab(tab.id) {
                                        pendingCloseTabID = tab.id
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(QS.Color.outline)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(workspaces.selectedTabID == tab.id ? QS.Color.surfaceHigh : QS.Color.surfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .background(QS.Color.surfaceLow)
            }

            HStack(spacing: 8) {
                if !workspaces.openFileName.isEmpty {
                    Text(workspaces.openFileName + (workspaces.isDirty ? " •" : ""))
                        .font(QS.Font.ui(12, weight: .medium))
                        .foregroundStyle(QS.Color.onSurface)
                } else {
                    Text("Nessun file aperto")
                        .font(QS.Font.ui(12))
                        .foregroundStyle(QS.Color.outline)
                }

                Spacer()

                if workspaces.isDirty {
                    PrimaryButton(title: "Salva", icon: "square.and.arrow.down", compact: true) {
                        _ = workspaces.saveOpenFile()
                    }
                }
                GhostButton(
                    title: showWorkspaceChat ? "Chat" : "Chat",
                    icon: "bubble.left.and.bubble.right"
                ) {
                    withAnimation { showWorkspaceChat.toggle() }
                }
                GhostButton(title: "Diff", icon: "arrow.left.arrow.right") {
                    showDiffSheet = true
                }
                GhostButton(title: "Commit", icon: "checkmark.seal") {
                    _ = workspaces.saveOpenFile()
                    if let path = workspaces.current?.path { git.setPath(path) }
                    let msg = "chore: QS Agents save \(workspaces.openFileName)"
                    git.commit(message: msg)
                    actionToast = "Commit in corso…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        actionToast = git.lastError ?? git.lastMessage ?? "Commit inviato"
                    }
                }
                .disabled(git.isBusy)
                PrimaryButton(title: "Terminale", icon: "terminal", compact: true) {
                    guard let path = workspaces.current?.path else {
                        actionToast = "Apri un progetto prima"
                        return
                    }
                    terminals.openTerminal(at: path, title: workspaces.current?.name)
                    state.navigate(to: .dashboard)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(QS.Color.surfaceLow)
            .overlay(alignment: .bottom) {
                Rectangle().fill(QS.Color.border).frame(height: 1)
            }

            if let toast = actionToast {
                Text(toast)
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.agentActive)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { actionToast = nil }
                    }
            }

            // Agent live stream
            if !agents.sessions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("Agents")
                            .font(QS.Font.labelXS)
                            .foregroundStyle(QS.Color.outline)
                        ForEach(agents.sessions.prefix(6)) { s in
                            Text("\(s.name): \(s.lines.last?.text.prefix(40) ?? "…")")
                                .font(QS.Font.codeSM)
                                .foregroundStyle(QS.Color.onSurfaceVariant)
                                .padding(6)
                                .background(QS.Color.surfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
            }

            if workspaces.openFilePath != nil {
                TextEditor(text: Binding(
                    get: { workspaces.fileContent },
                    set: { workspaces.updateContent($0) }
                ))
                .font(QS.Font.codeMD)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(QS.Color.backgroundDeep)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(QS.Color.outline)
                    Text("Seleziona un file nell'explorer")
                        .font(QS.Font.body)
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                    if workspaces.current == nil {
                        PrimaryButton(title: "Apri workspace…", icon: "folder") {
                            workspaces.pickAndOpen()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(QS.Color.backgroundDeep)
            }
        }
    }

    private var rightInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Workspace")
                .font(QS.Font.ui(13, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)
                .padding(.top, 14)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if let ws = workspaces.current {
                VStack(alignment: .leading, spacing: 6) {
                    meta("Nome", ws.name)
                    meta("Path", ws.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    meta("Git", ws.gitRoot != nil ? "sì" : "no")
                    meta("Ruolo default", ws.defaultRole.displayName)
                    meta("qs-safety", workspaces.safetyPolicy != nil ? "caricata" : "assente")
                    if let cmd = workspaces.lastTestCommand {
                        meta("Ultimo test", cmd)
                    }
                }
                .padding(12)
                .background(QS.Color.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)

                PrimaryButton(title: "Apri terminale", icon: "terminal", compact: true) {
                    terminals.openTerminal(at: ws.path, title: ws.name, role: ws.defaultRole)
                    state.navigate(to: .dashboard)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                if workspaces.safetyPolicy == nil {
                    GhostButton(title: "Crea qs-safety.json", icon: "shield") {
                        _ = workspaces.writeSafetyTemplate()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }
            } else {
                Text("Apri una cartella per iniziare.")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)
                    .padding(12)
            }

            Divider().overlay(QS.Color.border)
                .padding(.top, 12)

            // Git changelog + commit/push (Cursor-like) — identity keyed to project so UI rebinds
            GitPanelView(compact: false)
                .id(workspaces.current?.path ?? "no-workspace")
                .frame(maxHeight: .infinity)
        }
        .frame(width: 300)
        .background(QS.Color.surfaceLow)
        .overlay(alignment: .leading) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }

    // MARK: - Chat dock (same OrchestratorEngine as tab Chat)

    private var workspaceChatDock: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(QS.Color.primarySolid)
                Text("Chat · WS \(workspaces.current?.name ?? "—")")
                    .font(QS.Font.ui(12, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                if let path = workspaces.current?.path {
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(QS.Font.mono(9))
                        .foregroundStyle(QS.Color.outline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if orchestrator.isThinking {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    withAnimation { showWorkspaceChat = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(QS.Color.outline)
                }
                .buttonStyle(.plain)
                .help("Nascondi chat")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(QS.Color.surfaceContainer.opacity(0.95))

            Divider().overlay(QS.Color.border)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if orchestrator.messages.isEmpty {
                            Text("Chiedi all’orchestratore (es. crea task, apri terminale). Resta su questo workspace.")
                                .font(QS.Font.ui(11))
                                .foregroundStyle(QS.Color.outline)
                                .padding(.vertical, 8)
                        }
                        ForEach(orchestrator.messages.suffix(40)) { msg in
                            ChatBubble(message: msg)
                                .id(msg.id)
                        }
                        if orchestrator.isThinking {
                            Text("…")
                                .font(QS.Font.mono(11))
                                .foregroundStyle(QS.Color.outline)
                                .id("ws-thinking")
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: orchestrator.messages.count) { _, _ in
                    if let last = orchestrator.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider().overlay(QS.Color.border)

            HStack(spacing: 8) {
                TextField(
                    "Messaggio all’orchestratore…",
                    text: $chatDraft,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(QS.Font.ui(13))
                .padding(8)
                .background(QS.Color.surfaceHigh)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .focused($chatFocused)
                .onSubmit { sendWorkspaceChat() }

                Button {
                    sendWorkspaceChat()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(
                            chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? QS.Color.outline
                                : QS.Color.primarySolid
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || orchestrator.isThinking
                )
            }
            .padding(10)
            .background(QS.Color.surfaceLow)
        }
        .background(Color.black.opacity(0.35))
        .overlay(alignment: .top) {
            Rectangle().fill(QS.Color.border).frame(height: 1)
        }
    }

    private func sendWorkspaceChat() {
        let t = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Pin current workspace in the message context when user forgets
        var msg = t
        if let ws = workspaces.current?.path,
           !t.lowercased().contains("workspace"),
           !t.contains(ws) {
            // Soft pin only for task-creation style prompts
            if t.lowercased().contains("task") || t.lowercased().contains("crea") {
                msg = "Workspace attivo: \(ws)\n\n\(t)"
            }
        }
        orchestrator.draft = msg
        chatDraft = ""
        orchestrator.send()
    }

    private func bindGitToCurrentWorkspace() {
        if let path = workspaces.current?.path {
            git.setPath(path)
            workspaces.syncGitDirty(root: path, changes: git.status.changes)
        } else {
            git.setPath(nil)
            workspaces.syncGitDirty(root: nil, changes: [])
        }
    }

    private func meta(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(QS.Font.labelXS).foregroundStyle(QS.Color.outline).frame(width: 70, alignment: .leading)
            Text(v).font(QS.Font.codeSM).foregroundStyle(QS.Color.onSurface).lineLimit(3)
        }
    }
}

struct RealFileTreeNode: View {
    @EnvironmentObject private var workspaces: WorkspaceStore
    let node: FileNode
    let depth: Int
    let selectedPath: String?
    var isDirty: Bool = false
    var dirtyChild: Bool = false
    var onToggle: (UUID) -> Void
    var onOpen: (String) -> Void

    private var showDot: Bool {
        if node.isDirectory { return dirtyChild || workspaces.isPathDirty(node.path) }
        return isDirty || workspaces.isPathDirty(node.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                if node.isDirectory {
                    onToggle(node.id)
                } else {
                    onOpen(node.path)
                }
            } label: {
                HStack(spacing: 6) {
                    if node.isDirectory {
                        Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(QS.Color.outline)
                            .frame(width: 10)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(QS.Color.primary.opacity(0.85))
                    } else {
                        Color.clear.frame(width: 10)
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                            .foregroundStyle(showDot ? Color.red.opacity(0.9) : QS.Color.onSurfaceVariant)
                    }
                    Text(node.name)
                        .font(QS.Font.ui(12, weight: showDot && !node.isDirectory ? .semibold : .regular))
                        .foregroundStyle(selectedPath == node.path ? QS.Color.onSurface : QS.Color.onSurfaceVariant)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if showDot {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .help(node.isDirectory ? "Contiene file modificati" : "Modificato (git / agent)")
                    }
                }
                .padding(.leading, CGFloat(depth) * 12)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selectedPath == node.path ? QS.Color.surfaceHigh : .clear)
                )
            }
            .buttonStyle(.plain)

            if node.isDirectory && node.isExpanded {
                ForEach(node.children) { child in
                    RealFileTreeNode(
                        node: child,
                        depth: depth + 1,
                        selectedPath: selectedPath,
                        isDirty: workspaces.isPathDirty(child.path),
                        dirtyChild: child.isDirectory && workspaces.isPathDirty(child.path),
                        onToggle: onToggle,
                        onOpen: onOpen
                    )
                }
            }
        }
    }
}
