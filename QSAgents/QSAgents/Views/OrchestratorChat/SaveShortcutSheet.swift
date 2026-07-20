import SwiftUI

/// Explains and saves a one-click goal shortcut (formerly “ricetta”).
struct SaveShortcutSheet: View {
    @EnvironmentObject private var orchestrator: OrchestratorEngine
    @EnvironmentObject private var workspaces: WorkspaceStore
    @Binding var isPresented: Bool
    @State private var title: String = ""
    @State private var goal: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Salva scorciatoia goal")
                .font(QS.Font.ui(16, weight: .semibold))
            Text("Non è un menu di cucina: è un preferito.")
                .font(QS.Font.ui(12, weight: .medium))
                .foregroundStyle(QS.Color.primary)
            Text("Salva il testo del goal + il Coding engine (Claude CLI / QS API / …) + il workspace. Dopo, dal menu Rilancia lo riesegui in un click — come «rifai: fix CSS home».")
                .font(QS.Font.ui(12))
                .foregroundStyle(QS.Color.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Titolo corto (es. Fix motion home)", text: $title)
                .textFieldStyle(.roundedBorder)
            Text("Goal")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)
            TextEditor(text: $goal)
                .font(QS.Font.mono(11))
                .frame(minHeight: 90, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(QS.Color.backgroundDeep)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Text("Engine: \(orchestrator.codingEngine.shortLabel)")
                    .font(QS.Font.mono(10))
                    .foregroundStyle(QS.Color.primary)
                if let ws = workspaces.current {
                    Text("· \(ws.name)")
                        .font(QS.Font.mono(10))
                        .foregroundStyle(QS.Color.outline)
                }
                Spacer()
            }

            HStack {
                Button("Annulla") { isPresented = false }
                Spacer()
                Button("Salva scorciatoia") {
                    let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !g.isEmpty else { return }
                    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let display = t.isEmpty ? String(g.prefix(48)) : t
                    WorkRecipeStore.shared.add(
                        title: display,
                        goal: g,
                        workspacePath: workspaces.current?.path,
                        engine: orchestrator.codingEngine
                    )
                    orchestrator.messages.append(ChatMessage(
                        role: .assistant,
                        text: """
                        **Scorciatoia salvata** «\(display)».

                        Per riusarla: menu **Rilancia** (chip sopra la chat) → click. \
                        Riaprirà questo goal con lo stesso engine.
                        """,
                        engine: .localRules
                    ))
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            let draft = orchestrator.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            let last = orchestrator.messages.last(where: { $0.role == .user })?.text ?? ""
            goal = draft.isEmpty ? last : draft
            if title.isEmpty, !goal.isEmpty {
                title = String(goal.prefix(48))
            }
        }
    }
}
