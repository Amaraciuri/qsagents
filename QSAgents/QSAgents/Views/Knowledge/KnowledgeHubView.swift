import SwiftUI

/// Additive shell over Knowledge: keeps graph/FTS intact and adds Operativa beside it.
struct KnowledgeHubView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case knowledge
        case operativa

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .knowledge: return "Knowledge"
            case .operativa: return "Operativa"
            }
        }
    }

    @State private var pane: Pane = .knowledge

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases) { p in
                        Text(L(p.titleKey)).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                Spacer(minLength: 0)

                Text(pane == .knowledge
                     ? L("Grafo · FTS · code brain")
                     : L("Piano di realizzazione del workspace"))
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(QS.Color.surfaceLow)
            .overlay(alignment: .bottom) {
                Rectangle().fill(QS.Color.border).frame(height: 1)
            }

            Group {
                switch pane {
                case .knowledge:
                    KnowledgeGraphView()
                case .operativa:
                    OperationalPlanView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QS.Color.backgroundDeep)
    }
}
