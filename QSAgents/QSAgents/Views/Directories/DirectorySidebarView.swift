import SwiftUI

/// Left rail focused on **where you work**: current workspace + recent + open.
/// Less noise (no home/desktop/downloads clutter by default).
struct DirectorySidebarView: View {
    @EnvironmentObject private var directories: DirectoryStore
    @EnvironmentObject private var terminals: TerminalManager
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var git: GitService
    @EnvironmentObject private var state: AppState
    var onOpenTerminal: (String) -> Void

    @State private var showAllProjects = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Active workspace card
            VStack(alignment: .leading, spacing: 8) {
                Text("DOVE LAVORI")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                WorkspaceSwitcher(style: .expanded) {
                    // keep terminals in sync context
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().overlay(QS.Color.border)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(QS.Color.outline)
                TextField("Cerca progetto…", text: $directories.searchQuery)
                    .textFieldStyle(.plain)
                    .font(QS.Font.ui(12))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(QS.Color.surfaceHigh.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            .padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Recent workspaces first (what you actually use)
                    if !workspaces.recent.isEmpty {
                        sectionHeader("Workspace recenti")
                        ForEach(workspaces.recent.prefix(10)) { ws in
                            workspaceRow(ws)
                        }
                    }

                    // Discovered projects (collapsed by default if many)
                    let projects = directories.filteredProjects
                    if !projects.isEmpty {
                        HStack {
                            sectionHeader("Progetti")
                            Spacer()
                            if projects.count > 8 {
                                Button(showAllProjects ? "Meno" : "Tutti (\(projects.count))") {
                                    showAllProjects.toggle()
                                }
                                .buttonStyle(.plain)
                                .font(QS.Font.ui(10, weight: .medium))
                                .foregroundStyle(QS.Color.primary)
                            }
                        }
                        .padding(.horizontal, 14)

                        ForEach(showAllProjects ? projects : Array(projects.prefix(8))) { item in
                            projectRow(item)
                        }
                    }

                    if !directories.bookmarks.isEmpty {
                        sectionHeader("Bookmark")
                        ForEach(directories.bookmarks) { item in
                            projectRow(item, removable: true)
                        }
                    }
                }
                .padding(.bottom, 12)
            }

            Divider().overlay(QS.Color.border)

            VStack(spacing: 8) {
                Button {
                    workspaces.pickAndOpen()
                    if let path = workspaces.current?.path {
                        git.setPath(path)
                        onOpenTerminal(path)
                    }
                } label: {
                    Label("Apri workspace…", systemImage: "folder.badge.plus")
                        .font(QS.Font.ui(12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(QS.Color.primarySolid)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                HStack(spacing: 8) {
                    Button {
                        Task { await directories.scanProjects() }
                    } label: {
                        Label("Scan", systemImage: "arrow.clockwise")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        terminals.pickDirectoryAndOpen()
                        state.navigate(to: .dashboard)
                    } label: {
                        Label("Solo terminale", systemImage: "terminal")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.outline)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(width: 240)
        .background(QS.Color.surfaceSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(QS.Font.labelXS)
            .foregroundStyle(QS.Color.outline)
            .padding(.horizontal, 14)
    }

    private func workspaceRow(_ ws: ProjectWorkspace) -> some View {
        let active = workspaces.current?.path == ws.path
        return Button {
            selectWorkspace(path: ws.path, name: ws.name)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: active ? "folder.fill" : "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(active ? QS.Color.primary : QS.Color.onSurfaceVariant)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ws.name)
                        .font(QS.Font.ui(12, weight: active ? .semibold : .medium))
                        .foregroundStyle(QS.Color.onSurface)
                        .lineLimit(1)
                    Text(ws.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(QS.Font.mono(9))
                        .foregroundStyle(QS.Color.outline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if active {
                    Circle().fill(QS.Color.agentActive).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(active ? QS.Color.primarySolid.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Apri come workspace") { selectWorkspace(path: ws.path, name: ws.name) }
            Button("Terminale qui") {
                selectWorkspace(path: ws.path, name: ws.name, openTerm: true)
            }
            Button("Rimuovi dai recenti") { workspaces.removeRecent(ws.id) }
        }
    }

    private func projectRow(_ entry: DirectoryEntry, removable: Bool = false) -> some View {
        let active = workspaces.current?.path == entry.path
        return Button {
            selectWorkspace(path: entry.path, name: entry.name)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: entry.isGit ? "externaldrive.connected.to.line.below" : "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(entry.isGit ? QS.Color.agentActive : QS.Color.onSurfaceVariant)
                    .frame(width: 14)
                Text(entry.name)
                    .font(QS.Font.ui(12, weight: active ? .semibold : .medium))
                    .foregroundStyle(QS.Color.onSurface)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(active ? QS.Color.primarySolid.opacity(0.10) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.path)
        .contextMenu {
            Button("Apri workspace + terminale") {
                selectWorkspace(path: entry.path, name: entry.name, openTerm: true)
            }
            Button("Solo terminale") { onOpenTerminal(entry.path) }
            Button("Mostra nel Finder") { directories.revealInFinder(entry.path) }
            if removable {
                Divider()
                Button("Rimuovi bookmark", role: .destructive) {
                    directories.removeBookmark(entry.id)
                }
            }
        }
    }

    private func selectWorkspace(path: String, name: String, openTerm: Bool = false) {
        _ = workspaces.open(path: path)
        git.setPath(path)
        directories.rememberRecent(path: path)
        if openTerm {
            onOpenTerminal(path)
            state.navigate(to: .dashboard)
        } else {
            state.navigate(to: .orchestrator)
            state.orchestratorMode = .workspace
        }
    }
}
