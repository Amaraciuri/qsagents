import SwiftUI

/// Browse / restore archived chat transcripts for the current workspace.
struct ChatHistorySheet: View {
    @EnvironmentObject private var orchestrator: OrchestratorEngine
    @EnvironmentObject private var workspaces: WorkspaceStore
    @ObservedObject private var history = ChatHistoryStore.shared
    @Binding var isPresented: Bool
    @State private var confirmDelete: UUID?

    private var items: [ChatTranscript] {
        history.transcripts(for: workspaces.current?.path, includeArchived: true)
            .filter { !$0.messages.isEmpty || $0.archived }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History chat")
                        .font(QS.Font.ui(16, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text(workspaces.current.map { "Workspace: \($0.name)" } ?? "Nessun workspace")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.outline)
                }
                Spacer()
                Button("Chiudi") { isPresented = false }
                    .buttonStyle(.bordered)
            }
            .padding(16)

            Divider().overlay(QS.Color.border)

            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(QS.Color.outline)
                    Text("Nessuna history ancora")
                        .font(QS.Font.ui(13, weight: .medium))
                    Text("I messaggi si salvano per workspace. «Pulisci chat» archivia invece di cancellare.")
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.outline)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(items) { t in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(t.title)
                                        .font(QS.Font.ui(12, weight: .semibold))
                                        .foregroundStyle(QS.Color.onSurface)
                                        .lineLimit(1)
                                    if t.archived {
                                        Text("ARCHIVIO")
                                            .font(QS.Font.labelXS)
                                            .foregroundStyle(QS.Color.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(QS.Color.surfaceHigh)
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    } else {
                                        Text("LIVE")
                                            .font(QS.Font.labelXS)
                                            .foregroundStyle(QS.Color.agentActive)
                                    }
                                }
                                Text(t.preview)
                                    .font(QS.Font.ui(11))
                                    .foregroundStyle(QS.Color.onSurfaceVariant)
                                    .lineLimit(2)
                                Text("\(t.messages.count) msg · \(t.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(QS.Font.mono(9))
                                    .foregroundStyle(QS.Color.outline)
                            }
                            Spacer()
                            Button("Apri") {
                                orchestrator.restoreChatHistory(t.id)
                                isPresented = false
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!t.archived && history.activeTranscript(for: workspaces.current?.path)?.id == t.id)

                            Button(role: .destructive) {
                                confirmDelete = t.id
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 560, height: 420)
        .background(QS.Color.surfaceContainer)
        .confirmationDialog("Eliminare questa history?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("Elimina", role: .destructive) {
                if let id = confirmDelete {
                    history.delete(id)
                }
                confirmDelete = nil
            }
            Button("Annulla", role: .cancel) { confirmDelete = nil }
        }
    }
}
