import SwiftUI

/// Thin collapsed rail — click to expand (Cursor / VS Code style).
struct CollapsedSideRail: View {
    enum Edge { case leading, trailing }
    let edge: Edge
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: edge == .leading ? "sidebar.left" : "sidebar.right")
                    .font(.system(size: 13, weight: .semibold))
                // vertical hint
                Text(edge == .leading ? "W" : "I")
                    .font(QS.Font.mono(9))
                    .foregroundStyle(QS.Color.outline)
            }
            .foregroundStyle(QS.Color.onSurfaceVariant)
            .frame(width: 28)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(QS.Color.surfaceSidebar)
        .overlay(alignment: edge == .leading ? .trailing : .leading) {
            Rectangle().fill(QS.Color.border).frame(width: 1)
        }
        .help(help)
    }
}

/// Top-bar icon that toggles a sidebar and shows pressed state.
struct SidebarToggleIcon: View {
    let systemName: String
    let isOpen: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOpen ? QS.Color.primary : QS.Color.onSurfaceVariant)
                .frame(width: 28, height: 28)
                .background(isOpen ? QS.Color.primarySolid.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
