import SwiftUI

// MARK: - Status LED

struct StatusLED: View {
    let status: AgentStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .shadow(color: status.color.opacity(0.65), radius: status == .idle ? 0 : 4)
    }
}

// MARK: - Section label

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(L(text).uppercased())
            .font(QS.Font.labelXS)
            .tracking(0.8)
            .foregroundStyle(QS.Color.outline)
    }
}

// MARK: - Ghost button

struct GhostButton: View {
    let title: String
    var icon: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(L(title))
                    .font(QS.Font.body)
            }
            .foregroundStyle(QS.Color.onSurface)
            .padding(.horizontal, 10)
            .frame(height: QS.Spacing.controlHeight)
            .background(QS.Color.surfaceHigh.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: QS.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: QS.Radius.md, style: .continuous)
                    .stroke(QS.Color.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Primary button

struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    var compact: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                }
                Text(L(title))
                    .font(compact ? QS.Font.ui(12, weight: .semibold) : QS.Font.ui(13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 14)
            .frame(height: compact ? 28 : 34)
            .background(QS.Color.primarySolid)
            .clipShape(RoundedRectangle(cornerRadius: QS.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Priority chip

struct PriorityChip: View {
    let priority: TaskPriority
    var body: some View {
        Text(priority.rawValue)
            .font(QS.Font.labelXS)
            .tracking(0.6)
            .foregroundStyle(priority.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(priority.color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Status chip

struct StatusChip: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(QS.Font.labelXS)
                .tracking(0.5)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Search field

struct QSSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(QS.Color.outline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(QS.Font.body)
                .foregroundStyle(QS.Color.onSurface)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: 240)
        .background(QS.Color.surfaceHigh.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: QS.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QS.Radius.md, style: .continuous)
                .stroke(QS.Color.border, lineWidth: 1)
        )
    }
}

// MARK: - Top toolbar icon

struct ToolbarIconButton: View {
    let systemName: String
    var badge: Bool = false
    /// Numeric badge (unread count). When > 0 overrides plain red dot.
    var badgeCount: Int = 0
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                    .frame(width: 28, height: 28)
                if badgeCount > 0 {
                    Text(badgeCount > 9 ? "9+" : "\(badgeCount)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, badgeCount > 9 ? 3 : 4)
                        .padding(.vertical, 1)
                        .background(QS.Color.agentError)
                        .clipShape(Capsule())
                        .offset(x: 2, y: 0)
                } else if badge {
                    Circle()
                        .fill(QS.Color.agentError)
                        .frame(width: 6, height: 6)
                        .offset(x: -4, y: 4)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Activity gauge

struct ActivityGauge: View {
    var progress: Double
    var tint: Color = QS.Color.primarySolid

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(QS.Color.surfaceHighest)
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, geo.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: 2)
    }
}

// MARK: - Dot grid background

struct DotGridBackground: View {
    var spacing: CGFloat = 22
    var body: some View {
        Canvas { context, size in
            let color = QS.Color.outlineVariant.opacity(0.35)
            var x: CGFloat = 0
            while x < size.width {
                var y: CGFloat = 0
                while y < size.height {
                    let rect = CGRect(x: x, y: y, width: 1.2, height: 1.2)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                    y += spacing
                }
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Terminal line view

struct TerminalLineView: View {
    let line: TerminalLine
    var body: some View {
        Text(line.text)
            .font(QS.Font.codeSM)
            .foregroundStyle(line.level.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

// MARK: - Sidebar nav row

struct SidebarNavRow: View {
    let title: String
    let icon: String
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(L(title))
                    .font(QS.Font.body)
                Spacer()
            }
            .foregroundStyle(selected ? QS.Color.onSurface : QS.Color.onSurfaceVariant)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: QS.Radius.md, style: .continuous)
                    .fill(selected ? QS.Color.surfaceHigh : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}
