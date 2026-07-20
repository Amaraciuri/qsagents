import SwiftUI

/// Searchable model list scoped to **one** provider + free-text custom ID.
///
/// Uses a **sheet** (not `.popover`). On macOS, SwiftUI popovers + TextField
/// crash via ViewBridge (`containingWindowWillOrderOnScreen`) — seen on
/// macOS 15/26 betas as EXC_BREAKPOINT / SIGTRAP.
struct SearchableModelPicker: View {
    let provider: LLMProviderKind
    @Binding var selection: String
    var width: CGFloat? = 220

    @ObservedObject private var catalog = ModelCatalog.shared
    @State private var query: String = ""
    @State private var showSheet = false

    private var filtered: [String] {
        catalog.filter(query, provider: provider, selected: selection)
    }

    /// Safe display list — hard-capped for List performance.
    private var displayModels: [String] {
        Array(filtered.prefix(100))
    }

    var body: some View {
        Button {
            query = ""
            showSheet = true
        } label: {
            HStack(spacing: 6) {
                Text(selection.isEmpty ? "Scegli modello…" : selection)
                    .font(QS.Font.mono(11))
                    .foregroundStyle(QS.Color.onSurface)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(QS.Color.outline)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: width.map { $0 - 20 }, maxWidth: width, alignment: .leading)
            .background(QS.Color.surfaceHigh)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(QS.Color.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Modelli \(provider.displayName)")
        .sheet(isPresented: $showSheet) {
            ModelPickerSheet(
                provider: provider,
                selection: $selection,
                query: $query,
                isPresented: $showSheet
            )
        }
    }
}

// MARK: - Sheet content (isolated so hosting is a real window, not NSPopover child)

private struct ModelPickerSheet: View {
    let provider: LLMProviderKind
    @Binding var selection: String
    @Binding var query: String
    @Binding var isPresented: Bool

    @ObservedObject private var catalog = ModelCatalog.shared

    private var filtered: [String] {
        catalog.filter(query, provider: provider, selected: selection)
    }

    private var displayModels: [String] {
        Array(filtered.prefix(100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Modello · \(provider.displayName)")
                        .font(QS.Font.ui(14, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text("Solo modelli di questo provider · max 100 in lista")
                        .font(QS.Font.ui(10))
                        .foregroundStyle(QS.Color.outline)
                }
                Spacer()
                if provider == .openRouter {
                    Button {
                        catalog.refreshOpenRouterIfNeeded(force: true)
                    } label: {
                        if catalog.isLoadingOpenRouter {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Altri (max 80)", systemImage: "arrow.clockwise")
                                .font(QS.Font.ui(11))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Opzionale: scarica un sottoinsieme OpenRouter (non l’intero catalogo)")

                    if catalog.includeRemoteOpenRouter {
                        Button {
                            catalog.useCuratedOpenRouterOnly()
                        } label: {
                            Text("Solo curati")
                                .font(QS.Font.ui(11))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Chiudi") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .font(QS.Font.ui(12, weight: .medium))
                .foregroundStyle(QS.Color.outline)
            }
            .padding(16)

            Divider()

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(QS.Color.outline)
                TextField("Cerca o incolla id custom…", text: $query)
                    .textFieldStyle(.plain)
                    .font(QS.Font.mono(12))
                    .onSubmit { applyCustomIfNeeded() }
                if !query.isEmpty {
                    Button {
                        applyCustomIfNeeded()
                    } label: {
                        Text("Usa “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                            .font(QS.Font.ui(11, weight: .semibold))
                            .foregroundStyle(QS.Color.primarySolid)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(QS.Color.surfaceHigh)

            if let err = catalog.lastFetchError, provider == .openRouter {
                Text(err)
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.error)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            Text("\(filtered.count) modelli")
                .font(QS.Font.labelXS)
                .foregroundStyle(QS.Color.outline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            // Plain List in a real sheet window — no NSPopover / ViewBridge crash
            List {
                ForEach(displayModels, id: \.self) { m in
                    Button {
                        selection = m
                        isPresented = false
                    } label: {
                        HStack {
                            Text(m)
                                .font(QS.Font.mono(12))
                                .foregroundStyle(m == selection ? QS.Color.primarySolid : QS.Color.onSurface)
                                .lineLimit(1)
                            Spacer()
                            if m == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(QS.Color.primarySolid)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 420, idealHeight: 520)
        .background(QS.Color.backgroundDeep)
    }

    private func applyCustomIfNeeded() {
        let t = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let exact = filtered.first(where: { $0 == t }) {
            selection = exact
        } else if filtered.count == 1 {
            selection = filtered[0]
        } else {
            selection = t
        }
        isPresented = false
    }
}
