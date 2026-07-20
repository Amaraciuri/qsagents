import SwiftUI
import AppKit

/// Claude/Grok-style agent console: full tool/LLM stream (not the macOS PTY).
struct AgentWorkLogPanel: View {
    let session: AgentSession?
    var title: String = "Log agent"
    var emptyHint: String = "Seleziona un agent per vedere tool call, step LLM e risultati — non nel terminale di sistema."
    var onStop: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    /// When true, stick to bottom as new lines arrive.
    var autoScroll: Bool = true
    /// Compact height for embedding under Terminals.
    var compact: Bool = false

    @State private var copyFlash: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(QS.Color.border)
            if let session {
                progressRow(session)
                Divider().overlay(QS.Color.border.opacity(0.6))
                logBody(session)
            } else {
                emptyState
            }
        }
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(QS.Color.border, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(QS.Color.primarySolid)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(QS.Font.ui(12, weight: .semibold))
                    .foregroundStyle(QS.Color.onSurface)
                if let session {
                    Text("\(session.name) · \(session.role.displayName) · \(session.model)")
                        .font(QS.Font.mono(10))
                        .foregroundStyle(QS.Color.outline)
                        .lineLimit(1)
                } else {
                    Text("Console lavoro agent (tool stream)")
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                }
            }
            Spacer()
            if let session {
                StatusLED(status: session.status, size: 8)
                Text(session.status.label)
                    .font(QS.Font.mono(10))
                    .foregroundStyle(session.status.color)

                // Copy full console
                Button {
                    copyAll(session)
                } label: {
                    Label(copyFlash ?? "Copia", systemImage: copyFlash == nil ? "doc.on.doc" : "checkmark")
                        .font(QS.Font.ui(11, weight: .medium))
                        .foregroundStyle(copyFlash == nil ? QS.Color.onSurfaceVariant : QS.Color.agentActive)
                }
                .buttonStyle(.plain)
                .help("Copia tutto il log tool/LLM negli appunti")
                .disabled(session.lines.isEmpty)

                if session.status == .active || session.status == .thinking, let onStop {
                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(QS.Font.ui(11, weight: .semibold))
                            .foregroundStyle(QS.Color.error)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(QS.Color.outline)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 8 : 10)
        .background(QS.Color.surfaceContainer.opacity(0.95))
    }

    private func copyAll(_ session: AgentSession) {
        let header = "# \(session.name) · \(session.role.displayName) · \(session.model)\n# tokens=\(session.tokenUsage) · eventi=\(session.lines.count)\n\n"
        let body = session.lines.map { line in
            let t = timeString(line.timestamp)
            return "[\(t)] \(levelGlyph(line.level)) \(line.text)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(header + body, forType: .string)
        copyFlash = "Copiato"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            copyFlash = nil
        }
    }

    private func progressRow(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(progressCaption(session))
                    .font(QS.Font.ui(11, weight: .medium))
                    .foregroundStyle(QS.Color.onSurfaceVariant)
                Spacer()
                Text("\(session.lines.count) eventi · \(session.tokenUsage) tok")
                    .font(QS.Font.mono(10))
                    .foregroundStyle(QS.Color.outline)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(QS.Color.surfaceHigh)
                    Capsule()
                        .fill(progressColor(session))
                        .frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, session.progress)))))
                }
            }
            .frame(height: 6)
            if !compact {
                Text("Tool stream LLM — non è lo shell PTY di Terminali. Copia con il bottone in alto.")
                    .font(QS.Font.ui(10))
                    .foregroundStyle(QS.Color.outline)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(QS.Color.surfaceLow.opacity(0.9))
    }

    private func progressCaption(_ session: AgentSession) -> String {
        let pct = Int((session.progress * 100).rounded())
        switch session.status {
        case .thinking:
            return "In ragionamento · loop ~\(pct)%"
        case .active:
            return "Tool in esecuzione · loop ~\(pct)%"
        case .idle:
            return session.progress >= 0.99 ? "Completato" : "In pausa / idle · loop \(pct)%"
        case .error:
            return "Errore · loop \(pct)%"
        }
    }

    private func progressColor(_ session: AgentSession) -> Color {
        switch session.status {
        case .error: return QS.Color.error
        case .idle where session.progress >= 0.99: return QS.Color.agentActive
        case .thinking: return QS.Color.agentThinking
        default: return QS.Color.primarySolid
        }
    }

    private func logBody(_ session: AgentSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // VStack (not Lazy): multi-line tool dumps measure correctly — LazyVStack clipped height badly.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.lines.enumerated()), id: \.element.id) { idx, line in
                        logRow(line, index: idx)
                            .id(line.id)
                            .contextMenu {
                                Button("Copia riga") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(line.text, forType: .string)
                                }
                                Button("Copia tutto il log") {
                                    copyAll(session)
                                }
                            }
                    }
                    Color.clear.frame(height: 8).id("log-bottom")
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.lines.count) { _, _ in
                guard autoScroll else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
            .onChange(of: session.id) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
            .onAppear {
                if autoScroll {
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
        }
    }

    private func logRow(_ line: TerminalLine, index: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timeString(line.timestamp))
                .font(QS.Font.mono(9))
                .foregroundStyle(QS.Color.outline.opacity(0.7))
                .frame(width: 54, alignment: .trailing)
            Text(levelGlyph(line.level))
                .font(QS.Font.mono(10))
                .foregroundStyle(line.level.color)
                .frame(width: 14)
            Text(line.text)
                .font(QS.Font.mono(compact ? 11 : 12))
                .foregroundStyle(line.level.color)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, line.text.count > 200 ? 6 : 3)
        .background(index % 2 == 0 ? Color.clear : Color.white.opacity(0.025))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(QS.Color.outline)
            Text(emptyHint)
                .font(QS.Font.ui(12))
                .foregroundStyle(QS.Color.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private func levelGlyph(_ level: LogLevel) -> String {
        switch level {
        case .success: return "✓"
        case .error: return "✗"
        case .warning: return "!"
        case .thinking: return "…"
        case .code: return ">"
        case .muted: return "·"
        case .info: return "›"
        }
    }
}

// MARK: - Multi-agent terminal dock (Swarm)

/// Tabbed “terminals” — one log stream per agent (tool/LLM, not macOS PTY).
struct AgentTerminalDock: View {
    let sessions: [AgentSession]
    @Binding var selectedID: UUID?
    var pulse: Bool = false
    var onStop: (UUID) -> Void
    var onClose: (() -> Void)?

    private var selected: AgentSession? {
        if let id = selectedID {
            return sessions.first { $0.id == id } ?? sessions.first
        }
        return sessions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar like Terminal.app
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(sessions) { s in
                            Button {
                                selectedID = s.id
                            } label: {
                                HStack(spacing: 6) {
                                    StatusLED(status: s.status, size: 6)
                                    Text(s.name)
                                        .font(QS.Font.ui(11, weight: selectedID == s.id ? .semibold : .medium))
                                        .lineLimit(1)
                                    Text("\(s.lines.count)")
                                        .font(QS.Font.mono(9))
                                        .foregroundStyle(QS.Color.outline)
                                }
                                .foregroundStyle(
                                    selectedID == s.id ? QS.Color.onSurface : QS.Color.onSurfaceVariant
                                )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    selectedID == s.id
                                        ? Color.black.opacity(0.45)
                                        : QS.Color.surfaceHigh.opacity(0.6)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(
                                            selectedID == s.id ? QS.Color.primarySolid.opacity(0.5) : Color.clear,
                                            lineWidth: 1
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .help("\(s.role.displayName) · \(s.lines.count) eventi · \(s.tokenUsage) tok")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }

                Spacer(minLength: 8)

                Text("Terminal agent")
                    .font(QS.Font.labelXS)
                    .foregroundStyle(QS.Color.outline)
                    .padding(.trailing, 4)

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(QS.Color.outline)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(QS.Color.surfaceSidebar.opacity(0.95))

            // Mini previews of other agents (so you see everyone at once)
            if sessions.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(sessions.prefix(6)) { s in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    StatusLED(status: s.status, size: 5)
                                    Text(s.name)
                                        .font(QS.Font.mono(9))
                                        .foregroundStyle(QS.Color.primarySolid)
                                        .lineLimit(1)
                                }
                                Text(s.lines.last?.text ?? "— idle —")
                                    .font(QS.Font.mono(9))
                                    .foregroundStyle(QS.Color.outline)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(8)
                            .frame(width: 160, height: 72, alignment: .topLeading)
                            .background(Color.black.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        selectedID == s.id ? QS.Color.primarySolid.opacity(0.6) : QS.Color.border,
                                        lineWidth: 1
                                    )
                            )
                            .onTapGesture { selectedID = s.id }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .background(Color.black.opacity(0.2))
            }

            AgentWorkLogPanel(
                session: selected,
                title: selected.map { "\($0.name) · tool stream" } ?? "Terminal agent",
                emptyHint: "Nessun agent — lancia una missione. Ogni tab = log di un agent (non shell PTY).",
                onStop: selected.map { s in { onStop(s.id) } },
                onClose: nil,
                compact: true
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(pulse ? QS.Color.primarySolid : Color.clear, lineWidth: 2)
            )
        }
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(QS.Color.border, lineWidth: 1)
        )
        .onAppear {
            if selectedID == nil {
                selectedID = sessions.first?.id
            }
        }
        .onChange(of: sessions.map(\.id)) { _, ids in
            if let id = selectedID, !ids.contains(id) {
                selectedID = sessions.first?.id
            }
            if selectedID == nil {
                selectedID = sessions.first?.id
            }
        }
    }
}

// MARK: - Compact progress label for cards

struct AgentLoopProgressBar: View {
    let progress: Double
    let status: AgentStatus
    var showCaption: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showCaption {
                Text(caption)
                    .font(QS.Font.mono(9))
                    .foregroundStyle(QS.Color.outline)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(QS.Color.surfaceHigh)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, progress)))))
                }
            }
            .frame(height: 5)
        }
    }

    private var caption: String {
        let pct = Int((progress * 100).rounded())
        switch status {
        case .thinking: return "LLM step ~\(pct)%"
        case .active: return "tool ~\(pct)%"
        case .idle: return progress >= 0.99 ? "done" : "idle \(pct)%"
        case .error: return "error"
        }
    }

    private var tint: Color {
        switch status {
        case .error: return QS.Color.error
        case .thinking: return QS.Color.agentThinking
        case .active: return QS.Color.primarySolid
        case .idle: return progress >= 0.99 ? QS.Color.agentActive : QS.Color.outline
        }
    }
}
