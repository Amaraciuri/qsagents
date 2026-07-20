import SwiftUI

enum QS {
    enum Color {
        static let background = SwiftUI.Color(hex: 0x131313)
        static let backgroundDeep = SwiftUI.Color(hex: 0x0D0D0F)
        static let surface = SwiftUI.Color(hex: 0x131313)
        static let surfaceLow = SwiftUI.Color(hex: 0x1B1B1C)
        static let surfaceContainer = SwiftUI.Color(hex: 0x202020)
        static let surfaceHigh = SwiftUI.Color(hex: 0x2A2A2A)
        static let surfaceHighest = SwiftUI.Color(hex: 0x353535)
        static let surfaceSidebar = SwiftUI.Color(hex: 0x19191C).opacity(0.92)
        static let onSurface = SwiftUI.Color(hex: 0xE5E2E1)
        static let onSurfaceVariant = SwiftUI.Color(hex: 0xC0C6D6)
        static let outline = SwiftUI.Color(hex: 0x8B91A0)
        static let outlineVariant = SwiftUI.Color(hex: 0x414754)
        static let border = SwiftUI.Color(hex: 0x2C2C2E)
        static let primary = SwiftUI.Color(hex: 0xAAC7FF)
        static let primaryContainer = SwiftUI.Color(hex: 0x3E90FF)
        static let primarySolid = SwiftUI.Color(hex: 0x0A84FF)
        static let secondary = SwiftUI.Color(hex: 0xE9B3FF)
        static let secondaryContainer = SwiftUI.Color(hex: 0x7D01B1)
        static let tertiary = SwiftUI.Color(hex: 0xFFB691)
        static let error = SwiftUI.Color(hex: 0xFF453A)
        static let agentIdle = SwiftUI.Color(hex: 0x98989D)
        static let agentActive = SwiftUI.Color(hex: 0x32D74B)
        static let agentThinking = SwiftUI.Color(hex: 0xFFD60A)
        static let agentError = SwiftUI.Color(hex: 0xFF453A)
        static let syntaxString = SwiftUI.Color(hex: 0xA7E3B4)
        static let syntaxKeyword = SwiftUI.Color(hex: 0xD0A9F5)
        static let syntaxComment = SwiftUI.Color(hex: 0x6B7280)
        static let syntaxType = SwiftUI.Color(hex: 0xAAC7FF)
        static let diffAdd = SwiftUI.Color(hex: 0x1A3D2B)
        static let diffRemove = SwiftUI.Color(hex: 0x4A1F22)
        static let chipCritical = SwiftUI.Color(hex: 0xFF453A)
        static let chipHigh = SwiftUI.Color(hex: 0x0A84FF)
        static let chipMedium = SwiftUI.Color(hex: 0xFF9F0A)
        static let purpleAccent = SwiftUI.Color(hex: 0x7D01B1)
    }

    enum Spacing {
        static let sidebarWidth: CGFloat = 260
        static let windowPadding: CGFloat = 16
        static let gutter: CGFloat = 12
        static let stack: CGFloat = 8
        static let controlHeight: CGFloat = 28
    }

    enum Radius {
        static let sm: CGFloat = 2
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
        static let xl: CGFloat = 12
    }

    enum Font {
        static func ui(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .default)
        }
        static func mono(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
        static let windowTitle = ui(13, weight: .semibold)
        static let headline = ui(16, weight: .semibold)
        static let body = ui(13)
        static let codeSM = mono(12)
        static let codeMD = mono(14)
        static let labelXS = mono(10, weight: .bold)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

extension View {
    func qsCard(focused: Bool = false) -> some View {
        self
            .background(QS.Color.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: QS.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: QS.Radius.lg, style: .continuous)
                    .stroke(focused ? QS.Color.primarySolid.opacity(0.85) : QS.Color.border, lineWidth: 1)
            )
    }

    func qsPanel() -> some View {
        self
            .background(QS.Color.surfaceLow)
            .overlay(Rectangle().frame(width: 1).foregroundStyle(QS.Color.border), alignment: .trailing)
    }
}
