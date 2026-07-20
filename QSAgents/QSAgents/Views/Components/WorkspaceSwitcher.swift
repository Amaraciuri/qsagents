import SwiftUI

/// Compact control to see **where you are working** and switch workspace in one click.
struct WorkspaceSwitcher: View {
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var terminals: TerminalManager
    @EnvironmentObject private var git: GitService
    @EnvironmentObject private var knowledge: KnowledgeStore
    @EnvironmentObject private var state: AppState

    /// compact = top bar pill; expanded = sidebar card
    var style: Style = .compact
    var onSwitched: (() -> Void)? = nil

    enum Style {
        case compact
        case expanded
    }

    var body: some View {
        Menu {
            if let current = workspaces.current {
                Section("Ora stai lavorando qui") {
                    Button {
                        // already current — jump to workspace view
                        goToWorkspaceUI()
                    } label: {
                        Label(current.name, systemImage: "checkmark.circle.fill")
                    }
                    .disabled(true)
                    Text(shortPath(current.path))
                        .font(.caption)
                }
            } else {
                Section {
                    Text("Nessun workspace attivo")
                }
            }

            // No long "Recenti" list — easy to switch away from zackgame by mistake.
            // Explicit open only (or jump to current workspace UI).
            Divider()
            Button {
                workspaces.pickAndOpen()
                if let path = workspaces.current?.path {
                    afterOpen(path: path)
                }
            } label: {
                Label("Apri / cambia cartella…", systemImage: "folder.badge.plus")
            }
            if let path = workspaces.current?.path {
                Button {
                    _ = terminals.openTerminal(at: path, title: workspaces.current?.name)
                    state.navigate(to: .dashboard)
                } label: {
                    Label("Terminale qui", systemImage: "terminal")
                }
                Button {
                    knowledge.index(workspace: path)
                    state.navigate(to: .monitor)
                } label: {
                    Label("Indice Knowledge", systemImage: "circle.hexagongrid")
                }
            }
        } label: {
            labelContent
        }
        .menuStyle(.borderlessButton)
        .help(workspaces.current.map { "Workspace: \($0.path)" } ?? "Seleziona workspace")
    }

    @ViewBuilder
    private var labelContent: some View {
        switch style {
        case .compact:
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(workspaces.current?.name ?? "Scegli workspace")
                        .font(QS.Font.ui(11, weight: .semibold))
                        .lineLimit(1)
                    if workspaces.current != nil {
                        Text("cambia ▾")
                            .font(QS.Font.mono(8))
                            .foregroundStyle(QS.Color.outline)
                    }
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(QS.Color.outline)
            }
            .foregroundStyle(workspaces.current != nil ? QS.Color.primary : QS.Color.onSurfaceVariant)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                workspaces.current != nil
                    ? QS.Color.primarySolid.opacity(0.16)
                    : QS.Color.surfaceHigh
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        workspaces.current != nil
                            ? QS.Color.primarySolid.opacity(0.45)
                            : QS.Color.border,
                        lineWidth: 1
                    )
            )
            .frame(maxWidth: 200, alignment: .leading)

        case .expanded:
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(QS.Color.primarySolid.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(QS.Color.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("WORKSPACE")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                    Text(workspaces.current?.name ?? "Nessuno selezionato")
                        .font(QS.Font.ui(13, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                        .lineLimit(1)
                    Text(workspaces.current.map { shortPath($0.path) } ?? "Clicca per aprire / cambiare")
                        .font(QS.Font.mono(10))
                        .foregroundStyle(QS.Color.outline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(QS.Color.outline)
            }
            .padding(10)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(QS.Color.primarySolid.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private func switchTo(_ ws: ProjectWorkspace) {
        guard workspaces.open(path: ws.path) != nil else { return }
        afterOpen(path: ws.path)
        onSwitched?()
    }

    private func afterOpen(path: String) {
        git.setPath(path)
        // Light index in background if missing
        if !knowledge.cacheHas(path) {
            knowledge.index(workspace: path)
        }
        // Reload code-brain from disk (stats + FTS) so agents don't need a manual re-click
        ProjectCodeBrain.shared.ensureIndexed(workspace: path)
        goToWorkspaceUI()
    }

    private func goToWorkspaceUI() {
        state.showIntegrations = false
        state.showSafety = false
        state.navigate(to: .orchestrator)
        state.orchestratorMode = .workspace
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
