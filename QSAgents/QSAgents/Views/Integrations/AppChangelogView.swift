import SwiftUI

/// Beautiful in-app product changelog (Impostazioni → Novità).
struct AppChangelogView: View {
    @State private var filter: Filter = .all
    @State private var expandedId: String? = AppChangelog.latest.id

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "Tutto"
        case major = "Major"
        case feature = "Feature"
        case fix = "Fix"
        case polish = "Polish"
        var id: String { rawValue }
    }

    private var filtered: [AppChangelog.Entry] {
        switch filter {
        case .all: return AppChangelog.releases
        case .major: return AppChangelog.releases.filter { $0.kind == .major }
        case .feature: return AppChangelog.releases.filter { $0.kind == .feature }
        case .fix: return AppChangelog.releases.filter { $0.kind == .fix }
        case .polish: return AppChangelog.releases.filter { $0.kind == .polish }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                filterBar
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(filtered) { entry in
                        releaseCard(entry)
                    }
                }
                footerNote
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(QS.Color.backgroundDeep)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "newspaper.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(QS.Color.primarySolid)
                        Text("Novità")
                            .font(QS.Font.ui(22, weight: .bold))
                            .foregroundStyle(QS.Color.onSurface)
                    }
                    Text("Cosa è cambiato in QS Agents — senza aprire git.")
                        .font(QS.Font.ui(13))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("v\(AppChangelog.latest.version)")
                        .font(QS.Font.mono(14))
                        .foregroundStyle(QS.Color.primarySolid)
                    Text(AppChangelog.latest.date)
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(QS.Color.primarySolid.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // Latest spotlight
            let latest = AppChangelog.latest
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [latest.kind.color, latest.kind.color.opacity(0.4)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        kindChip(latest.kind)
                        Text("Ultima release")
                            .font(QS.Font.labelXS)
                            .foregroundStyle(QS.Color.outline)
                    }
                    Text(latest.title)
                        .font(QS.Font.ui(16, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text(latest.tagline)
                        .font(QS.Font.ui(12))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(
                LinearGradient(
                    colors: [
                        QS.Color.surfaceContainer,
                        QS.Color.primarySolid.opacity(0.08),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(QS.Color.primarySolid.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases) { f in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { filter = f }
                } label: {
                    Text(f.rawValue)
                        .font(QS.Font.ui(11, weight: filter == f ? .semibold : .medium))
                        .foregroundStyle(filter == f ? .white : QS.Color.onSurfaceVariant)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(filter == f ? QS.Color.primarySolid : QS.Color.surfaceHigh)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Cards

    private func releaseCard(_ entry: AppChangelog.Entry) -> some View {
        let open = expandedId == entry.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedId = open ? nil : entry.id
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    // Timeline dot
                    ZStack {
                        Circle()
                            .fill(entry.kind.color.opacity(0.2))
                            .frame(width: 36, height: 36)
                        Image(systemName: entry.kind.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(entry.kind.color)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("v\(entry.version)")
                                .font(QS.Font.mono(12))
                                .foregroundStyle(QS.Color.primarySolid)
                            kindChip(entry.kind)
                            Text(entry.date)
                                .font(QS.Font.labelXS)
                                .foregroundStyle(QS.Color.outline)
                        }
                        Text(entry.title)
                            .font(QS.Font.ui(14, weight: .semibold))
                            .foregroundStyle(QS.Color.onSurface)
                            .multilineTextAlignment(.leading)
                        if !open {
                            Text(entry.tagline)
                                .font(QS.Font.ui(11))
                                .foregroundStyle(QS.Color.onSurfaceVariant)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QS.Color.outline)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 10) {
                    Text(entry.tagline)
                        .font(QS.Font.ui(12))
                        .foregroundStyle(QS.Color.onSurfaceVariant)
                        .padding(.horizontal, 14)

                    ForEach(entry.highlights) { h in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: h.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(entry.kind.color)
                                .frame(width: 22, height: 22)
                                .background(entry.kind.color.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.title)
                                    .font(QS.Font.ui(12, weight: .semibold))
                                    .foregroundStyle(QS.Color.onSurface)
                                Text(h.detail)
                                    .font(QS.Font.ui(11))
                                    .foregroundStyle(QS.Color.onSurfaceVariant)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .padding(.bottom, 14)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(QS.Color.surfaceContainer.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    open ? entry.kind.color.opacity(0.35) : QS.Color.border,
                    lineWidth: 1
                )
        )
    }

    private func kindChip(_ kind: AppChangelog.Entry.Kind) -> some View {
        Text(kind.label)
            .font(QS.Font.labelXS)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(kind.color)
            .clipShape(Capsule())
    }

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nota")
                .font(QS.Font.ui(11, weight: .semibold))
                .foregroundStyle(QS.Color.outline)
            Text("Questo è il changelog **prodotto** dell’app. Il log git del workspace si apre da Git → Log o chiedendo `changelog` all’orchestratore.")
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.onSurfaceVariant)
        }
        .padding(.top, 8)
        .padding(.bottom, 24)
    }
}
