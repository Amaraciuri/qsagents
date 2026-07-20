import SwiftUI

struct KnowledgeGraphView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var knowledge: KnowledgeStore
    @EnvironmentObject private var workspaces: WorkspaceStore
    @ObservedObject private var codeBrain = ProjectCodeBrain.shared
    @State private var selectedNodeID: UUID?
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var showImportsOnly = false
    @State private var showSymbols = true

    var body: some View {
        HStack(spacing: 0) {
            if state.showLeftSidebar {
                knowledgeSidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                CollapsedSideRail(edge: .leading, help: "Mostra knowledge list (⌘B)") {
                    withAnimation(.easeInOut(duration: 0.15)) { state.showLeftSidebar = true }
                }
            }
            graphStage
            if state.showRightSidebar {
                inspector
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
            if let path = workspaces.current?.path {
                if knowledge.cacheHas(path) {
                    knowledge.selectProject(path)
                } else if knowledge.chunks.isEmpty {
                    knowledge.index(workspace: path)
                }
                codeBrain.ensureIndexed(workspace: path)
            }
        }
        .onChange(of: workspaces.current?.path) { _, path in
            guard let path else { return }
            if knowledge.cacheHas(path) {
                knowledge.selectProject(path)
            }
            codeBrain.ensureIndexed(workspace: path)
        }
    }

    // MARK: - Sidebar (unchanged structure)

    private var knowledgeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("QS KNOWLEDGE")
                        .font(QS.Font.ui(12, weight: .bold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text(knowledge.isIndexing
                          ? "Indicizzazione…"
                          : "\(knowledge.fileCount) file · \(knowledge.nodes.count) nodi · \(knowledge.edges.count) link")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                }
                Spacer()
            }
            .padding(14)

            // Local code brain (structured capsule for agents)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(QS.Color.primary)
                    Text("Code brain")
                        .font(QS.Font.ui(12, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Spacer()
                    if codeBrain.isIndexing {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(codeBrain.isIndexing
                      ? "Indexing grafo + FTS…"
                      : (codeBrain.lastStats.isEmpty ? "Non indicizzato (apri workspace o Indice)" : codeBrain.lastStats))
                    .font(QS.Font.labelXS)
                    .foregroundStyle(codeBrain.isReadyForAgents ? QS.Color.agentActive : QS.Color.outline)
                Text(codeBrain.isReadyForAgents
                     ? "Pronto per gli agent · repo_capsule / locate leggono questo indice SQLite"
                     : "Gli agent useranno l'indice dopo il salvataggio su disco")
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.outline)
                if let err = codeBrain.lastError {
                    Text(err)
                        .font(QS.Font.labelXS)
                        .foregroundStyle(.red)
                }
                HStack(spacing: 8) {
                    Button(codeBrain.isReadyForAgents ? "Aggiorna indice" : "Indice code brain") {
                        if let path = workspaces.current?.path {
                            codeBrain.index(workspace: path, force: !codeBrain.isReadyForAgents)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(workspaces.current == nil || codeBrain.isIndexing)
                    Text("tool: repo_capsule")
                        .font(QS.Font.codeSM)
                        .foregroundStyle(QS.Color.outline)
                }
            }
            .padding(10)
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 6) {
                Text("Progetto attivo")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                Text(knowledge.activeProjectName)
                    .font(QS.Font.ui(13, weight: .semibold))
                    .foregroundStyle(QS.Color.primary)
                    .lineLimit(1)
                if let p = knowledge.activeProjectPath {
                    Text(p.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(QS.Font.codeSM)
                        .foregroundStyle(QS.Color.outline)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            SectionLabel(text: "Progetti indicizzati")
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

            if knowledge.projects.isEmpty {
                Text("Nessuno ancora. Scegli un workspace e premi Indice.")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(knowledge.projects, id: \.path) { proj in
                            Button {
                                knowledge.selectProject(proj.path)
                                selectedNodeID = nil
                            } label: {
                                HStack {
                                    Image(systemName: knowledge.activeProjectPath == proj.path
                                          ? "folder.fill" : "folder")
                                        .foregroundStyle(QS.Color.primary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(proj.name)
                                            .font(QS.Font.ui(12, weight: .medium))
                                            .foregroundStyle(QS.Color.onSurface)
                                        Text("\(proj.fileCount) file · \(proj.nodes.count) nodi · \(proj.edges.count) archi")
                                            .font(QS.Font.labelXS)
                                            .foregroundStyle(QS.Color.outline)
                                    }
                                    Spacer()
                                    if knowledge.activeProjectPath == proj.path {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(QS.Color.agentActive)
                                            .font(.system(size: 12))
                                    }
                                }
                                .padding(8)
                                .background(
                                    knowledge.activeProjectPath == proj.path
                                    ? QS.Color.primarySolid.opacity(0.12)
                                    : QS.Color.surfaceContainer
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Seleziona") { knowledge.selectProject(proj.path) }
                                Button("Re-indicizza") { knowledge.index(workspace: proj.path) }
                                Button("Rimuovi dalla cache", role: .destructive) {
                                    knowledge.removeProject(proj.path)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(maxHeight: 140)
            }

            if !workspaces.recent.isEmpty {
                SectionLabel(text: "Altri workspace")
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(workspaces.recent.prefix(8)) { ws in
                            let indexed = knowledge.cacheHas(ws.path)
                            Button {
                                if indexed {
                                    knowledge.selectProject(ws.path)
                                } else {
                                    _ = workspaces.open(path: ws.path)
                                    knowledge.index(workspace: ws.path)
                                }
                            } label: {
                                Text(indexed ? ws.name : "＋ \(ws.name)")
                                    .font(QS.Font.ui(11))
                                    .foregroundStyle(QS.Color.onSurface)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(QS.Color.surfaceHigh)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.bottom, 8)
            }

            HStack(spacing: 8) {
                PrimaryButton(
                    title: knowledge.isIndexing ? "Indexing…" : "Indice questo",
                    icon: "magnifyingglass",
                    compact: true
                ) {
                    if let path = workspaces.current?.path ?? knowledge.activeProjectPath {
                        knowledge.index(workspace: path)
                    } else {
                        workspaces.pickAndOpen()
                    }
                }
                .disabled(knowledge.isIndexing)

                GhostButton(title: "Apri…", icon: "folder") {
                    workspaces.pickAndOpen()
                    if let path = workspaces.current?.path {
                        knowledge.index(workspace: path)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            QSSearchField(placeholder: "Cerca in \(knowledge.activeProjectName)…", text: $knowledge.searchQuery)
                .padding(.horizontal, 12)
                .onChange(of: knowledge.searchQuery) { _, q in
                    knowledge.search(q)
                }

            SectionLabel(text: "Risultati")
                .padding(.horizontal, 14)
                .padding(.top, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if knowledge.hits.isEmpty {
                        Text(knowledge.chunks.isEmpty
                              ? "Seleziona o indicizza un progetto"
                              : "Nessun hit — prova altre parole")
                            .font(QS.Font.ui(11))
                            .foregroundStyle(QS.Color.outline)
                            .padding(.horizontal, 14)
                    }
                    ForEach(knowledge.hits) { hit in
                        Button {
                            workspaces.openFile(path: hit.path)
                            state.navigate(to: .orchestrator)
                            state.orchestratorMode = .workspace
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.relativePath)
                                    .font(QS.Font.ui(11, weight: .semibold))
                                    .foregroundStyle(QS.Color.onSurface)
                                    .lineLimit(1)
                                Text("L\(hit.startLine) · score \(hit.score)")
                                    .font(QS.Font.labelXS)
                                    .foregroundStyle(QS.Color.outline)
                                Text(hit.snippet)
                                    .font(QS.Font.codeSM)
                                    .foregroundStyle(QS.Color.onSurfaceVariant)
                                    .lineLimit(3)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(QS.Color.surfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: QS.Spacing.sidebarWidth)
        .background(QS.Color.surfaceSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }

    // MARK: - Graph stage with edges

    private var visibleNodes: [KnowledgeGraphNode] {
        knowledge.nodes.filter { n in
            if !showSymbols && n.kind == "symbol" { return false }
            return true
        }
    }

    private var visibleNodeIDs: Set<UUID> {
        Set(visibleNodes.map(\.id))
    }

    private var visibleEdges: [KnowledgeGraphEdge] {
        knowledge.edges.filter { e in
            guard visibleNodeIDs.contains(e.from), visibleNodeIDs.contains(e.to) else { return false }
            if showImportsOnly {
                return e.kind == "imports" || e.kind == "contains"
            }
            return true
        }
    }

    private var graphStage: some View {
        VStack(spacing: 0) {
            graphToolbar
            GeometryReader { geo in
                ZStack {
                    QS.Color.backgroundDeep
                    DotGridBackground()

                    if knowledge.nodes.isEmpty {
                        emptyState
                    } else {
                        // Zoomable / pannable canvas
                        ZStack {
                            // Edges under nodes
                            Canvas { context, size in
                                let byID = Dictionary(uniqueKeysWithValues: visibleNodes.map { ($0.id, $0) })
                                for edge in visibleEdges {
                                    guard let a = byID[edge.from], let b = byID[edge.to] else { continue }
                                    let p1 = CGPoint(x: a.x * size.width, y: a.y * size.height)
                                    let p2 = CGPoint(x: b.x * size.width, y: b.y * size.height)
                                    var path = Path()
                                    path.move(to: p1)
                                    // Soft curve for depth readability
                                    let mid = CGPoint(
                                        x: (p1.x + p2.x) / 2,
                                        y: (p1.y + p2.y) / 2 - (edge.kind == "contains" ? 0 : 12)
                                    )
                                    path.addQuadCurve(to: p2, control: mid)
                                    context.stroke(
                                        path,
                                        with: .color(edgeColor(edge.kind).opacity(edgeOpacity(edge.kind))),
                                        style: StrokeStyle(
                                            lineWidth: edgeWidth(edge.kind),
                                            lineCap: .round,
                                            dash: edge.kind == "imports" ? [5, 4] : []
                                        )
                                    )
                                }
                            }
                            .allowsHitTesting(false)

                            ForEach(visibleNodes) { node in
                                graphNodeCard(node)
                                    .position(
                                        x: node.x * geo.size.width,
                                        y: node.y * geo.size.height
                                    )
                                    .onTapGesture {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            selectedNodeID = node.id
                                        }
                                    }
                            }
                        }
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            SimultaneousGesture(
                                MagnificationGesture().onChanged { v in
                                    scale = min(2.2, max(0.45, v))
                                },
                                DragGesture().onChanged { v in
                                    offset = v.translation
                                }
                            )
                        )
                    }
                }
            }
        }
    }

    private var graphToolbar: some View {
        HStack(spacing: 12) {
            Text("Mappa progetto")
                .font(QS.Font.ui(13, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)
            Text("profondità top→bottom · linee = contains / imports")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)

            Spacer()

            Toggle(isOn: $showSymbols) {
                Text("Simboli")
                    .font(QS.Font.ui(11))
            }
            .toggleStyle(.checkbox)
            .foregroundStyle(QS.Color.onSurfaceVariant)

            Toggle(isOn: $showImportsOnly) {
                Text("Focus tree+import")
                    .font(QS.Font.ui(11))
            }
            .toggleStyle(.checkbox)
            .foregroundStyle(QS.Color.onSurfaceVariant)

            Button {
                withAnimation {
                    scale = 1
                    offset = .zero
                }
            } label: {
                Label("Reset vista", systemImage: "arrow.counterclockwise")
                    .font(QS.Font.ui(11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(QS.Color.primarySolid)

            // Legend chips
            legendChip("cartella", QS.Color.agentThinking)
            legendChip("file", QS.Color.primarySolid)
            legendChip("page", QS.Color.agentActive)
            legendChip("import --", QS.Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(QS.Color.surfaceContainer.opacity(0.9))
        .overlay(alignment: .bottom) {
            Rectangle().fill(QS.Color.border).frame(height: 1)
        }
    }

    private func legendChip(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(QS.Font.mono(9))
                .foregroundStyle(QS.Color.outline)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(QS.Color.outline)
            Text(knowledge.isIndexing ? "Indicizzazione in corso…" : "Grafo vuoto")
                .font(QS.Font.headline)
            Text("Indicizza un workspace per vedere cartelle → file → import con linee di collegamento.")
                .font(QS.Font.body)
                .foregroundStyle(QS.Color.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func graphNodeCard(_ node: KnowledgeGraphNode) -> some View {
        let selected = selectedNodeID == node.id
        let accent = nodeAccent(node)
        let w = nodeCardWidth(node)

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: nodeIcon(node.kind))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
                Text(node.kind.uppercased())
                    .font(QS.Font.mono(8))
                    .foregroundStyle(QS.Color.outline)
                if node.depth > 0 {
                    Text("d\(node.depth)")
                        .font(QS.Font.mono(8))
                        .foregroundStyle(QS.Color.outline.opacity(0.8))
                }
            }
            Text(node.title)
                .font(QS.Font.ui(node.kind == "concept" ? 12 : 11, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)
                .lineLimit(1)
            if node.kind == "folder", node.childCount > 0 {
                Text("\(node.childCount) items")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
            }
            if node.kind == "file" || node.kind == "page", let lang = node.language {
                Text(lang)
                    .font(QS.Font.mono(8))
                    .foregroundStyle(accent.opacity(0.9))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: w, alignment: .leading)
        .background(QS.Color.surfaceContainer.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: node.kind == "folder" ? 10 : 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: node.kind == "folder" ? 10 : 8, style: .continuous)
                .stroke(selected ? QS.Color.primarySolid : accent.opacity(0.55), lineWidth: selected ? 2 : 1)
        )
        .shadow(color: .black.opacity(selected ? 0.35 : 0.18), radius: selected ? 10 : 4, y: 2)
        .scaleEffect(selected ? 1.05 : 1.0)
    }

    private func nodeCardWidth(_ node: KnowledgeGraphNode) -> CGFloat {
        switch node.kind {
        case "concept": return 130
        case "folder": return 112
        case "symbol": return 96
        default: return 108
        }
    }

    private func nodeIcon(_ kind: String) -> String {
        switch kind {
        case "concept": return "shippingbox.fill"
        case "folder": return "folder.fill"
        case "page": return "doc.richtext"
        case "symbol": return "function"
        default: return "doc.text"
        }
    }

    private func nodeAccent(_ node: KnowledgeGraphNode) -> Color {
        switch node.kind {
        case "concept": return QS.Color.primarySolid
        case "folder": return QS.Color.agentThinking
        case "page": return QS.Color.agentActive
        case "symbol": return QS.Color.secondary
        default:
            switch node.language {
            case "swift": return Color.orange
            case "ts", "tsx": return Color.blue
            case "js", "jsx": return Color.yellow.opacity(0.9)
            case "py": return Color.green
            case "rs": return Color.orange.opacity(0.8)
            case "go": return Color.cyan
            default: return QS.Color.primarySolid
            }
        }
    }

    private func edgeColor(_ kind: String) -> Color {
        switch kind {
        case "contains": return QS.Color.outline
        case "imports": return QS.Color.agentActive
        case "defines": return QS.Color.primarySolid
        default: return QS.Color.outline.opacity(0.5)
        }
    }

    private func edgeOpacity(_ kind: String) -> Double {
        switch kind {
        case "contains": return 0.55
        case "imports": return 0.75
        case "defines": return 0.45
        default: return 0.35
        }
    }

    private func edgeWidth(_ kind: String) -> CGFloat {
        switch kind {
        case "contains": return 1.4
        case "imports": return 1.6
        case "defines": return 1.0
        default: return 1.0
        }
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inspector")
                .font(QS.Font.ui(13, weight: .semibold))
                .padding(.top, 14)
            Text("Progetto: \(knowledge.activeProjectName)")
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.primary)
            Text("Nodi \(knowledge.nodes.count) · Archi \(knowledge.edges.count) · File \(knowledge.fileCount)")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)

            // Depth stats
            if !knowledge.nodes.isEmpty {
                let maxD = knowledge.nodes.map(\.depth).max() ?? 0
                Text("Profondità max: \(maxD)")
                    .font(QS.Font.ui(11, weight: .medium))
                    .foregroundStyle(QS.Color.onSurface)
                let folders = knowledge.nodes.filter { $0.kind == "folder" }.count
                let files = knowledge.nodes.filter { $0.kind == "file" || $0.kind == "page" }.count
                let imports = knowledge.edges.filter { $0.kind == "imports" }.count
                Text("\(folders) cartelle · \(files) file/page · \(imports) import")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
            }

            Divider().overlay(QS.Color.border)

            if let node = knowledge.nodes.first(where: { $0.id == selectedNodeID }) {
                HStack(spacing: 6) {
                    Image(systemName: nodeIcon(node.kind))
                        .foregroundStyle(nodeAccent(node))
                    Text(node.title)
                        .font(QS.Font.ui(14, weight: .semibold))
                }
                Text("\(node.kind) · depth \(node.depth)")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.primary)
                if let rel = node.relativePath, !rel.isEmpty {
                    Text(rel)
                        .font(QS.Font.mono(10))
                        .foregroundStyle(QS.Color.outline)
                        .textSelection(.enabled)
                }
                Text(node.detail)
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                    .textSelection(.enabled)

                // Connected edges
                let connected = knowledge.edges.filter { $0.from == node.id || $0.to == node.id }
                if !connected.isEmpty {
                    Text("Collegamenti (\(connected.count))")
                        .font(QS.Font.ui(11, weight: .semibold))
                        .padding(.top, 4)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(connected.prefix(20)) { e in
                                let otherID = e.from == node.id ? e.to : e.from
                                let other = knowledge.nodes.first { $0.id == otherID }
                                let dir = e.from == node.id ? "→" : "←"
                                Text("\(dir) [\(e.kind)] \(other?.title ?? "?")")
                                    .font(QS.Font.mono(10))
                                    .foregroundStyle(edgeColor(e.kind))
                                    .onTapGesture { selectedNodeID = otherID }
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }

                if let path = node.path, node.kind == "file" || node.kind == "page" || node.kind == "symbol" {
                    PrimaryButton(title: "Apri file", icon: "doc", compact: true) {
                        workspaces.openFile(path: path)
                        state.navigate(to: .orchestrator)
                        state.orchestratorMode = .workspace
                    }
                }
            } else {
                Text("Clicca un nodo per vedere path, profondità e collegamenti.\n\n• Linee grigie = contains (albero cartelle)\n• Linee tratteggiate verdi = imports tra file\n• Pinch/drag per zoom e pan")
                    .font(QS.Font.ui(11))
                    .foregroundStyle(QS.Color.outline)
            }
            if let err = knowledge.lastError {
                Text(err).font(QS.Font.ui(10)).foregroundStyle(QS.Color.error)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(width: 260)
        .background(QS.Color.surfaceLow)
        .overlay(alignment: .leading) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
    }
}
