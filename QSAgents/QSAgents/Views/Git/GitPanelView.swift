import SwiftUI

/// Changelog + Changes (VS Code-style staged/unstaged tree) + commit/push.
struct GitPanelView: View {
    @EnvironmentObject private var git: GitService
    @EnvironmentObject private var workspaces: WorkspaceStore

    var compact: Bool = false
    @State private var commitMessage: String = ""
    @State private var showCommitSheet: Bool = false
    @State private var tab: PanelTab = .changes
    @State private var stagedExpanded = true
    @State private var changesExpanded = true
    @State private var showDiff = true

    enum PanelTab: String, CaseIterable {
        case changes = "Changes"
        case changelog = "Log"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(QS.Color.border)

            if git.isBusy && !git.status.isRepo && git.log.isEmpty {
                loadingState
            } else if !git.status.isRepo {
                emptyNotRepo
            } else {
                tabPicker
                if tab == .changelog {
                    changelogList
                } else {
                    changesList
                }
                commitBar
            }
        }
        .onAppear { syncPath(force: true) }
        .onChange(of: workspaces.current?.path) { _, newPath in
            // Always rebind when the selected project changes (recent / open folder).
            if let newPath {
                git.setPath(newPath)
            } else {
                syncPath(force: true)
            }
        }
        .onChange(of: workspaces.current?.id) { _, _ in
            syncPath(force: true)
        }
        .sheet(isPresented: $showCommitSheet) {
            commitSheet
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Lettura git…")
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.outline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    private func syncPath(force: Bool = false) {
        // Prefer workspace project — never fall back to bare $HOME (false "clean" / old log).
        guard let path = workspaces.current?.path ?? git.workingPath else {
            git.setPath(nil)
            return
        }
        if force || git.workingPath != path {
            git.setPath(path)
        } else {
            git.refresh()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(QS.Color.primary)
                Text("Git")
                    .font(QS.Font.ui(13, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)

                if let branch = git.status.branch {
                    Text(branch)
                        .font(QS.Font.codeSM)
                        .foregroundStyle(QS.Color.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(QS.Color.primarySolid.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()

                if git.hasGitHubToken {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(QS.Color.agentActive)
                        .help("Token GitHub configurato")
                }

                if git.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                }

                Button {
                    git.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(QS.Color.outline)
                }
                .buttonStyle(.plain)
                .disabled(git.isBusy)
                .help("Aggiorna status e log")
            }

            if let path = git.workingPath ?? workspaces.current?.path {
                Text((path as NSString).lastPathComponent)
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                    .lineLimit(1)
                    .help(path)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    Text(t.rawValue)
                        .font(QS.Font.ui(11, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? QS.Color.onSurface : QS.Color.outline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(tab == t ? QS.Color.surfaceHigh : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(git.status.summaryLine)
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(QS.Color.surfaceLow.opacity(0.5))
    }

    private var emptyNotRepo: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(QS.Color.outline)
            Text("Nessun repository git")
                .font(QS.Font.ui(12, weight: .medium))
                .foregroundStyle(QS.Color.onSurface)
            Text("Apri un workspace con `.git` per vedere changelog, status e commit.")
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.outline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: Changelog

    private var changelogList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if git.log.isEmpty {
                    Text(git.status.isEmptyRepo
                          ? "Repo senza commit (normale su progetto nuovo). Fai il primo commit."
                          : "Nessun commit")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.outline)
                        .padding(12)
                }
                ForEach(git.log) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.shortHash)
                                .font(QS.Font.codeSM)
                                .foregroundStyle(QS.Color.primary)
                            Text(entry.subject)
                                .font(QS.Font.ui(12, weight: .medium))
                                .foregroundStyle(QS.Color.onSurface)
                                .lineLimit(2)
                        }
                        HStack(spacing: 6) {
                            Text(entry.author)
                                .font(QS.Font.labelXS)
                                .foregroundStyle(QS.Color.onSurfaceVariant)
                            Text("·")
                                .foregroundStyle(QS.Color.outline)
                            Text(entry.relativeDate)
                                .font(QS.Font.labelXS)
                                .foregroundStyle(QS.Color.outline)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider().overlay(QS.Color.border.opacity(0.6))
                }
            }
        }
        .frame(maxHeight: compact ? 220 : .infinity)
    }

    // MARK: Changes (VS Code-style)

    private var ignoredWorkBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(git.status.ignoredCount) path gitignored (non in git status / Desktop)")
                .font(QS.Font.ui(11, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)
            Text(git.status.ignoredSamples.prefix(5).joined(separator: " · "))
                .font(QS.Font.codeSM)
                .foregroundStyle(QS.Color.outline)
                .lineLimit(2)
            Text("Es. www/ = build Capacitor — non stageable. Non confondere con modifiche tracked. Gli agent editano root/src.")
                .font(QS.Font.ui(10))
                .foregroundStyle(QS.Color.outline)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QS.Color.agentThinking.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(QS.Color.border).frame(height: 1)
        }
    }

    private var changesList: some View {
        VStack(spacing: 0) {
            // Sync strip vs remote (GitHub/origin)
            syncStrip

            if git.status.changes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(QS.Color.agentActive)
                    Text("Working tree clean")
                        .font(QS.Font.ui(12, weight: .medium))
                        .foregroundStyle(QS.Color.onSurface)
                    Text(remoteHint)
                        .font(QS.Font.ui(10))
                        .foregroundStyle(QS.Color.outline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 16)
                // Footnote only — same as Desktop/CLI primary status
                if git.status.ignoredCount > 0 {
                    ignoredWorkBanner
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // STAGED
                        changeSectionHeader(
                            title: "Staged Changes",
                            count: git.stagedChanges.count,
                            expanded: $stagedExpanded,
                            accent: QS.Color.agentActive,
                            trailing: {
                                AnyView(
                                    HStack(spacing: 6) {
                                        if !git.stagedChanges.isEmpty {
                                            Button("Unstage All") { git.unstageAll() }
                                                .font(QS.Font.ui(10, weight: .medium))
                                                .foregroundStyle(QS.Color.outline)
                                                .buttonStyle(.plain)
                                                .disabled(git.isBusy)
                                        }
                                    }
                                )
                            }
                        )
                        if stagedExpanded {
                            if git.stagedChanges.isEmpty {
                                Text("Nessun file in stage")
                                    .font(QS.Font.ui(10))
                                    .foregroundStyle(QS.Color.outline)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(treeRows(from: git.stagedChanges), id: \.id) { row in
                                    changeFileRow(row, staged: true)
                                }
                            }
                        }

                        // CHANGES (unstaged / untracked)
                        changeSectionHeader(
                            title: "Changes",
                            count: git.unstagedChanges.count,
                            expanded: $changesExpanded,
                            accent: QS.Color.agentThinking,
                            trailing: {
                                AnyView(
                                    HStack(spacing: 6) {
                                        if !git.unstagedChanges.isEmpty || git.status.ignoredCount > 0 {
                                            Menu {
                                                Button("Stage All (tracked)") {
                                                    git.stageAll(includeIgnored: false)
                                                }
                                                .disabled(git.unstagedChanges.isEmpty)
                                                Button("Stage All + ignored (force)") {
                                                    git.stageAll(includeIgnored: true)
                                                }
                                                .disabled(git.status.ignoredCount == 0 && git.unstagedChanges.isEmpty)
                                            } label: {
                                                Text("Stage All")
                                                    .font(QS.Font.ui(10, weight: .medium))
                                                    .foregroundStyle(QS.Color.primarySolid)
                                            }
                                            .menuStyle(.borderlessButton)
                                            .disabled(git.isBusy)
                                            .help("Opzione force: include anche file gitignored (es. www/)")
                                        }
                                    }
                                )
                            }
                        )
                        if changesExpanded {
                            if git.unstagedChanges.isEmpty {
                                Text("Nessuna modifica non staged")
                                    .font(QS.Font.ui(10))
                                    .foregroundStyle(QS.Color.outline)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(treeRows(from: git.unstagedChanges), id: \.id) { row in
                                    changeFileRow(row, staged: false)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: compact ? 160 : (showDiff && git.selectedDiffPath != nil ? 180 : .infinity))
            }

            // Inline diff (like Source Control detail)
            if showDiff, let path = git.selectedDiffPath, !compact {
                Divider().overlay(QS.Color.border)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(path)
                            .font(QS.Font.mono(10))
                            .foregroundStyle(QS.Color.onSurface)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(git.selectedDiffStaged ? "STAGED" : "WORKING TREE")
                            .font(QS.Font.labelXS)
                            .foregroundStyle(QS.Color.outline)
                        Button {
                            git.clearDiff()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(QS.Color.outline)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(QS.Color.surfaceLow)

                    ScrollView([.vertical, .horizontal]) {
                        Text(git.selectedDiffText.isEmpty ? "…" : git.selectedDiffText)
                            .font(QS.Font.mono(10))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                    .background(Color.black.opacity(0.35))
                }
            }
        }
    }

    private var syncStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(QS.Color.primarySolid)
            Text(git.status.branch ?? "—")
                .font(QS.Font.mono(10))
                .foregroundStyle(QS.Color.onSurface)
            if let up = git.status.upstream {
                Text("↔ \(up)")
                    .font(QS.Font.mono(9))
                    .foregroundStyle(QS.Color.outline)
                    .lineLimit(1)
            }
            if git.status.ahead > 0 {
                Text("↑\(git.status.ahead)")
                    .font(QS.Font.mono(10))
                    .foregroundStyle(QS.Color.agentThinking)
                    .help("Commit locali non su remote")
            }
            if git.status.behind > 0 {
                Text("↓\(git.status.behind)")
                    .font(QS.Font.mono(10))
                    .foregroundStyle(QS.Color.error)
                    .help("Commit sul remote non ancora in locale — Pull")
            }
            Spacer()
            Text("\(git.status.stagedCount)S · \(git.status.unstagedCount)M · \(git.status.untrackedCount)?")
                .font(QS.Font.mono(9))
                .foregroundStyle(QS.Color.outline)
                .help("Staged · Modified · Untracked")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(QS.Color.surfaceLow.opacity(0.7))
    }

    private var remoteHint: String {
        if git.status.behind > 0 {
            return "Remote avanti di \(git.status.behind) — fai Pull per allinearti a GitHub/origin."
        }
        if git.status.ahead > 0 {
            return "Hai \(git.status.ahead) commit da pushare su origin."
        }
        if let up = git.status.upstream {
            return "Allineato con \(up)."
        }
        return "Nessun upstream configurato (push -u origin HEAD al primo push)."
    }

    private func changeSectionHeader(
        title: String,
        count: Int,
        expanded: Binding<Bool>,
        accent: Color,
        trailing: () -> AnyView
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(QS.Color.outline)
                    Text(title)
                        .font(QS.Font.ui(11, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text("\(count)")
                        .font(QS.Font.mono(10))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(accent.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(QS.Color.surfaceContainer.opacity(0.5))
    }

    /// Flatten changes into folder-indented rows (simple tree like SCM).
    private struct ChangeRow: Identifiable {
        var id: String
        var change: GitFileChange
        var depth: Int
        var fileName: String
        var folderLabel: String?
    }

    private func treeRows(from changes: [GitFileChange]) -> [ChangeRow] {
        let sorted = changes.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        return sorted.map { c in
            let parts = c.path.split(separator: "/").map(String.init)
            let depth = max(0, parts.count - 1)
            let fileName = parts.last ?? c.path
            let folder = parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
            return ChangeRow(
                id: c.path + (c.staged ? "|S" : "|W") + c.status,
                change: c,
                depth: min(depth, 4),
                fileName: fileName,
                folderLabel: folder
            )
        }
    }

    private func changeFileRow(_ row: ChangeRow, staged: Bool) -> some View {
        let selected = git.selectedDiffPath == row.change.path && git.selectedDiffStaged == staged
        return HStack(spacing: 6) {
            // Indent like file tree
            HStack(spacing: 0) {
                ForEach(0..<row.depth, id: \.self) { _ in
                    Rectangle()
                        .fill(QS.Color.border.opacity(0.35))
                        .frame(width: 1)
                        .padding(.leading, 8)
                }
            }
            .frame(width: CGFloat(row.depth) * 10)

            Text(statusLetter(row.change.status))
                .font(QS.Font.mono(10, weight: .bold))
                .foregroundStyle(statusColor(row.change.status))
                .frame(width: 14, alignment: .center)

            VStack(alignment: .leading, spacing: 0) {
                Text(row.fileName)
                    .font(QS.Font.ui(11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(QS.Color.onSurface)
                    .lineLimit(1)
                if let folder = row.folderLabel {
                    Text(folder)
                        .font(QS.Font.mono(9))
                        .foregroundStyle(QS.Color.outline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            // Stage / unstage toggle (VS Code + / −)
            if staged {
                Button {
                    git.unstage(path: row.change.path)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(QS.Color.outline)
                }
                .buttonStyle(.plain)
                .help("Unstage")
                .disabled(git.isBusy)
            } else {
                Button {
                    git.stage(path: row.change.path)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(QS.Color.agentActive)
                }
                .buttonStyle(.plain)
                .help("Stage")
                .disabled(git.isBusy)

                if row.change.status != "??" {
                    Button {
                        git.discard(path: row.change.path)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(QS.Color.error.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Discard working tree changes")
                    .disabled(git.isBusy)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? QS.Color.primarySolid.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            git.loadDiff(path: row.change.path, staged: staged)
            showDiff = true
        }
        .contextMenu {
            if staged {
                Button("Unstage") { git.unstage(path: row.change.path) }
            } else {
                Button("Stage") { git.stage(path: row.change.path) }
                if row.change.status != "??" {
                    Button("Discard changes", role: .destructive) { git.discard(path: row.change.path) }
                }
            }
            Button("Apri diff") { git.loadDiff(path: row.change.path, staged: staged) }
            if let root = git.status.root {
                let full = (root as NSString).appendingPathComponent(row.change.path)
                Button("Apri file") {
                    workspaces.openFile(path: full)
                }
            }
        }
    }

    private func statusLetter(_ s: String) -> String {
        switch s {
        case "??": return "U"
        case "A", "a": return "A"
        case "D", "d": return "D"
        case "R", "r": return "R"
        case "M", "m": return "M"
        default: return String(s.prefix(1)).uppercased()
        }
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "M", "m": return QS.Color.agentThinking
        case "A", "a": return QS.Color.agentActive
        case "D", "d": return QS.Color.error
        case "??": return Color.cyan.opacity(0.9)
        case "R", "r": return QS.Color.secondary
        default: return QS.Color.secondary
        }
    }

    // MARK: Commit bar

    private var commitBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = git.lastError {
                Text(err)
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.error)
                    .lineLimit(3)
            } else if let msg = git.lastMessage {
                Text(msg)
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.agentActive)
            }

            // Inline commit message (VS Code-like)
            TextField("Message (⌘⏎ Commit)", text: $commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(QS.Font.ui(12))
                .padding(8)
                .background(QS.Color.surfaceHigh)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .lineLimit(2...4)

            HStack(spacing: 6) {
                Menu {
                    Button("Stage all (tracked)") {
                        git.stageAll(includeIgnored: false)
                    }
                    Button("Stage all + ignored (force)") {
                        git.stageAll(includeIgnored: true)
                    }
                } label: {
                    Label("Stage all", systemImage: "plus.circle")
                        .font(QS.Font.ui(11))
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .foregroundStyle(QS.Color.onSurfaceVariant)
                .disabled(git.isBusy)
                .help("Force: include anche path gitignored")

                Button {
                    let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    if msg.isEmpty {
                        showCommitSheet = true
                    } else {
                        git.commit(message: msg)
                        commitMessage = ""
                    }
                } label: {
                    Label("Commit", systemImage: "checkmark.circle")
                        .font(QS.Font.ui(11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(QS.Color.primarySolid)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(git.isBusy)
                .help("Commit (staged o stage-all se vuoto)")

                Button {
                    git.push()
                } label: {
                    Label("Push", systemImage: "arrow.up")
                        .font(QS.Font.ui(11, weight: .medium))
                        .foregroundStyle(QS.Color.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(QS.Color.primarySolid.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(git.isBusy)
                .help(git.hasGitHubToken
                      ? "Push verso origin (token GitHub)"
                      : "Push (configura token GitHub in Integrazioni se serve auth)")

                Button {
                    git.pull()
                } label: {
                    Label("Pull", systemImage: "arrow.down")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                }
                .buttonStyle(.plain)
                .disabled(git.isBusy)
                .help("Pull --rebase --autostash (merge/rebase da origin)")

                Button {
                    if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        showCommitSheet = true
                    } else {
                        git.commitAndPush(message: commitMessage)
                        commitMessage = ""
                    }
                } label: {
                    Image(systemName: "arrow.up.to.line.compact")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QS.Color.primarySolid)
                }
                .buttonStyle(.plain)
                .disabled(git.isBusy)
                .help("Commit + Push")
            }
        }
        .padding(10)
        .background(QS.Color.surfaceContainer)
    }

    private var commitSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Commit & Push")
                .font(QS.Font.headline)
            Text(git.status.summaryLine)
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)

            TextField("Messaggio commit…", text: $commitMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            if !git.hasGitHubToken {
                Text("Suggerimento: aggiungi un Personal Access Token GitHub in Integrazioni per push HTTPS senza prompt.")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)
            }

            HStack {
                Button("Annulla") { showCommitSheet = false }
                Spacer()
                Button("Solo commit") {
                    git.commit(message: commitMessage)
                    commitMessage = ""
                    showCommitSheet = false
                }
                .disabled(git.isBusy)
                Button("Commit + Push") {
                    git.commitAndPush(message: commitMessage)
                    commitMessage = ""
                    showCommitSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(git.isBusy)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// Compact strip for terminal toolbar.
struct GitStatusStrip: View {
    @EnvironmentObject private var git: GitService
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var terminals: TerminalManager
    var onOpenPanel: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(QS.Color.primary)
            if git.status.isRepo {
                Text(git.status.branch ?? "git")
                    .font(QS.Font.codeSM)
                    .foregroundStyle(QS.Color.onSurface)
                if git.status.ahead > 0 {
                    Text("↑\(git.status.ahead)")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.agentThinking)
                }
                if !git.status.changes.isEmpty {
                    Text("\(git.status.changes.count) Δ")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                }
            } else {
                Text("no git")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
            }
            Button {
                syncAndRefresh()
                onOpenPanel?()
            } label: {
                Text("Changelog")
                    .font(QS.Font.ui(10, weight: .medium))
                    .foregroundStyle(QS.Color.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(QS.Color.surfaceContainer)
        .clipShape(Capsule())
        .onAppear { syncAndRefresh() }
        .onChange(of: terminals.selectedID) { _, _ in syncAndRefresh() }
        .onChange(of: workspaces.current?.path) { _, _ in syncAndRefresh() }
    }

    private func syncAndRefresh() {
        let path = terminals.selected?.cwd
            ?? workspaces.current?.path
            ?? NSHomeDirectory()
        git.setPath(path)
    }
}
