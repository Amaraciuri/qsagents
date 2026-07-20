import SwiftUI

struct OperationalPlanView: View {
    @EnvironmentObject private var workspaces: WorkspaceStore
    @ObservedObject private var store = OperationalPlanStore.shared

    @State private var renamePhaseID: UUID?
    @State private var renamePhaseText = ""
    @State private var renameItem: (phaseID: UUID, itemID: UUID)?
    @State private var renameItemText = ""
    @State private var showAddPhaseAlert = false
    @State private var addPhaseText = ""
    @State private var addItemPhaseID: UUID?
    @State private var addItemText = ""

    var body: some View {
        Group {
            if workspaces.current?.path == nil {
                emptyWorkspace
            } else if let plan = store.activePlan {
                planBoard(plan)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QS.Color.backgroundDeep)
        .onAppear { store.bind(workspacePath: workspaces.current?.path) }
        .onChange(of: workspaces.current?.path) { _, path in
            store.bind(workspacePath: path)
        }
        .alert(L("Nuova fase"), isPresented: $showAddPhaseAlert) {
            TextField(L("Nome fase"), text: $addPhaseText)
            Button(L("Annulla"), role: .cancel) { addPhaseText = "" }
            Button(L("Aggiungi")) {
                store.addPhase(title: addPhaseText)
                addPhaseText = ""
            }
        }
        .alert(L("Rinomina fase"), isPresented: Binding(
            get: { renamePhaseID != nil },
            set: { if !$0 { renamePhaseID = nil } }
        )) {
            TextField(L("Nome fase"), text: $renamePhaseText)
            Button(L("Annulla"), role: .cancel) { renamePhaseID = nil }
            Button(L("Salva")) {
                if let id = renamePhaseID {
                    store.renamePhase(id, title: renamePhaseText)
                }
                renamePhaseID = nil
            }
        }
        .alert(L("Nuovo item"), isPresented: Binding(
            get: { addItemPhaseID != nil },
            set: { if !$0 { addItemPhaseID = nil } }
        )) {
            TextField(L("Titolo"), text: $addItemText)
            Button(L("Annulla"), role: .cancel) {
                addItemPhaseID = nil
                addItemText = ""
            }
            Button(L("Aggiungi")) {
                if let id = addItemPhaseID {
                    store.addItem(phaseID: id, title: addItemText)
                }
                addItemPhaseID = nil
                addItemText = ""
            }
        }
        .alert(L("Rinomina item"), isPresented: Binding(
            get: { renameItem != nil },
            set: { if !$0 { renameItem = nil } }
        )) {
            TextField(L("Titolo"), text: $renameItemText)
            Button(L("Annulla"), role: .cancel) { renameItem = nil }
            Button(L("Salva")) {
                if let pair = renameItem {
                    store.renameItem(phaseID: pair.phaseID, itemID: pair.itemID, title: renameItemText)
                }
                renameItem = nil
            }
        }
    }

    // MARK: - Empty

    private var emptyWorkspace: some View {
        VStack(spacing: 10) {
            Image(systemName: "tablecells")
                .font(.system(size: 28))
                .foregroundStyle(QS.Color.outline)
            Text(L("TABELLA OPERATIVA"))
                .font(QS.Font.ui(15, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)
            Text(L("Apri un workspace per la tabella operativa."))
                .font(QS.Font.ui(12))
                .foregroundStyle(QS.Color.outline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Board

    private func planBoard(_ plan: OperationalPlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(plan)
            flussoStrip(plan)
            HStack(alignment: .top, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(plan.sortedPhases.enumerated()), id: \.element.id) { index, phase in
                            phaseColumn(phase, index: index + 1)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                progressCard(plan)
                    .padding(.trailing, 14)
                    .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func header(_ plan: OperationalPlan) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("TABELLA OPERATIVA"))
                    .font(QS.Font.ui(13, weight: .bold))
                    .foregroundStyle(QS.Color.onSurface)
                Text(workspaces.current?.name ?? plan.workspacePath)
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                addPhaseText = ""
                showAddPhaseAlert = true
            } label: {
                Label(L("Aggiungi fase"), systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Menu {
                Button(L("Ripristina piano seed")) {
                    store.resetToSeed()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(QS.Color.surfaceLow)
        .overlay(alignment: .bottom) {
            Rectangle().fill(QS.Color.border).frame(height: 1)
        }
    }

    private func flussoStrip(_ plan: OperationalPlan) -> some View {
        let phases = plan.sortedPhases
        return VStack(alignment: .leading, spacing: 4) {
            Text(L("FLUSSO"))
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)
                .padding(.horizontal, 14)
                .padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(phases.enumerated()), id: \.element.id) { index, phase in
                        HStack(spacing: 8) {
                            Text(String(format: "%02d", index + 1))
                                .font(QS.Font.mono(10, weight: .bold))
                                .foregroundStyle(QS.Color.primary)
                            Text(phase.title)
                                .font(QS.Font.ui(11, weight: .semibold))
                                .foregroundStyle(QS.Color.onSurface)
                                .lineLimit(1)
                            if index < phases.count - 1 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(QS.Color.outlineVariant)
                                    .padding(.leading, 4)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            phase.highlightLabel.isEmpty
                                ? QS.Color.surfaceContainer
                                : QS.Color.primarySolid.opacity(0.18)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        if index < phases.count - 1 {
                            Rectangle()
                                .fill(QS.Color.outlineVariant.opacity(0.5))
                                .frame(width: 16, height: 1)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
        .background(QS.Color.backgroundDeep)
        .overlay(alignment: .bottom) {
            Rectangle().fill(QS.Color.border).frame(height: 1)
        }
    }

    // MARK: - Phase column

    private func phaseColumn(_ phase: OperationalPhase, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%02d", index))
                    .font(QS.Font.mono(11, weight: .bold))
                    .foregroundStyle(QS.Color.primary)
                Text(phase.title)
                    .font(QS.Font.ui(12, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Menu {
                    Button(L("Aggiungi item")) {
                        addItemText = ""
                        addItemPhaseID = phase.id
                    }
                    Button(L("Rinomina fase")) {
                        renamePhaseText = phase.title
                        renamePhaseID = phase.id
                    }
                    if phase.highlightLabel.isEmpty {
                        Button(L("Segna come ADESSO")) {
                            store.setPhaseHighlight(phase.id, label: L("ADESSO"))
                        }
                    } else {
                        Button(L("Rimuovi evidenziazione")) {
                            store.setPhaseHighlight(phase.id, label: "")
                        }
                    }
                    Divider()
                    Button(L("Elimina fase"), role: .destructive) {
                        store.deletePhase(phase.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QS.Color.outline)
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
            }

            if !phase.highlightLabel.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(phase.highlightLabel.uppercased())
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.primary)
                    if let first = phase.items.first {
                        Text(first.title)
                            .font(QS.Font.ui(11, weight: .medium))
                            .foregroundStyle(QS.Color.onSurface)
                            .lineLimit(3)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QS.Color.surfaceHighest.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(QS.Color.primarySolid.opacity(0.35), lineWidth: 1)
                )
            }

            VStack(spacing: 6) {
                ForEach(phase.items) { item in
                    itemCard(phaseID: phase.id, item: item)
                }
            }

            Button {
                addItemText = ""
                addItemPhaseID = phase.id
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text(L("Aggiungi item"))
                }
                .font(QS.Font.ui(10, weight: .medium))
                .foregroundStyle(QS.Color.outline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(QS.Color.surfaceContainer.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(QS.Color.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 210, alignment: .topLeading)
        .background(QS.Color.surfaceLow)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    phase.highlightLabel.isEmpty ? QS.Color.border : QS.Color.primarySolid.opacity(0.45),
                    lineWidth: 1
                )
        )
    }

    private func itemCard(phaseID: UUID, item: OperationalItem) -> some View {
        HStack(spacing: 8) {
            Text(item.ownerInitials.isEmpty ? "·" : String(item.ownerInitials.prefix(2)).uppercased())
                .font(QS.Font.mono(9, weight: .bold))
                .foregroundStyle(QS.Color.onSurface)
                .frame(width: 22, height: 22)
                .background(QS.Color.surfaceHighest)
                .clipShape(Circle())

            Text(item.title)
                .font(QS.Font.ui(11))
                .foregroundStyle(item.status == .done ? QS.Color.outline : QS.Color.onSurface)
                .strikethrough(item.status == .done, color: QS.Color.outline)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Circle()
                .fill(statusColor(item.status))
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            store.toggleItemStatus(phaseID: phaseID, itemID: item.id)
        }
        .contextMenu {
            Button(L("Cicla stato")) {
                store.toggleItemStatus(phaseID: phaseID, itemID: item.id)
            }
            ForEach(OperationalItemStatus.allCases) { status in
                Button("\(L(status.labelKey))") {
                    store.setItemStatus(phaseID: phaseID, itemID: item.id, status: status)
                }
            }
            Divider()
            Button(L("Rinomina")) {
                renameItemText = item.title
                renameItem = (phaseID, item.id)
            }
            Button(L("Elimina"), role: .destructive) {
                store.deleteItem(phaseID: phaseID, itemID: item.id)
            }
        }
    }

    // MARK: - Progress

    private func progressCard(_ plan: OperationalPlan) -> some View {
        let c = plan.counts
        return VStack(alignment: .leading, spacing: 12) {
            Text(L("Progresso"))
                .font(QS.Font.ui(11, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)

            HStack(spacing: 12) {
                ProgressDonut(
                    done: c.done,
                    todo: c.todo,
                    blocked: c.blocked,
                    total: c.total
                )
                .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 6) {
                    legendRow(color: QS.Color.agentActive, label: L("fatto"), count: c.done)
                    legendRow(color: QS.Color.agentThinking, label: L("da fare"), count: c.todo)
                    legendRow(color: QS.Color.agentError, label: L("bloccato"), count: c.blocked)
                }
            }
        }
        .padding(12)
        .frame(width: 200, alignment: .leading)
        .background(QS.Color.surfaceLow)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(QS.Color.border, lineWidth: 1)
        )
    }

    private func legendRow(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.onSurfaceVariant)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(QS.Font.mono(11, weight: .bold))
                .foregroundStyle(QS.Color.onSurface)
        }
    }

    private func statusColor(_ status: OperationalItemStatus) -> Color {
        switch status {
        case .done: return QS.Color.agentActive
        case .todo: return QS.Color.agentThinking
        case .blocked: return QS.Color.agentError
        }
    }
}

// MARK: - Donut

private struct ProgressDonut: View {
    let done: Int
    let todo: Int
    let blocked: Int
    let total: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(QS.Color.surfaceHighest, lineWidth: 10)
            if total > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(done) / CGFloat(total))
                    .stroke(QS.Color.agentActive, style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(
                        from: CGFloat(done) / CGFloat(total),
                        to: CGFloat(done + todo) / CGFloat(total)
                    )
                    .stroke(QS.Color.agentThinking, style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(
                        from: CGFloat(done + todo) / CGFloat(total),
                        to: 1
                    )
                    .stroke(QS.Color.agentError, style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            Text("\(done)/\(max(total, 0))")
                .font(QS.Font.mono(12, weight: .bold))
                .foregroundStyle(QS.Color.onSurface)
        }
    }
}
