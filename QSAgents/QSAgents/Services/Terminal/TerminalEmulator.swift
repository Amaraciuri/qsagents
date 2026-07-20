import Foundation

/// Minimal terminal state for correct display of PTY output (zsh/bash redraw).
/// Handles CR, backspace, and basic CSI erase/move so lines don't "ggrok".
struct TerminalEmulator: Equatable {
    /// Screen as lines of characters (no ANSI). Published to UI without full-string joins.
    private(set) var lines: [String] = [""]
    private var row: Int = 0
    private var col: Int = 0
    private let maxLines = 8_000
    private let maxCols = 500

    /// Plain text for copy / search (join on demand only).
    var plainText: String {
        lines.joined(separator: "\n")
    }

    var lineCount: Int { lines.count }

    mutating func reset() {
        lines = [""]
        row = 0
        col = 0
    }

    mutating func feed(_ raw: String) {
        var i = raw.startIndex
        while i < raw.endIndex {
            let ch = raw[i]

            // ESC sequences
            if ch == "\u{1B}" {
                let next = raw.index(after: i)
                guard next < raw.endIndex else { break }
                let n = raw[next]
                if n == "[" {
                    // CSI
                    var j = raw.index(after: next)
                    var params = ""
                    while j < raw.endIndex {
                        let c = raw[j]
                        if (c >= "0" && c <= "9") || c == ";" || c == "?" {
                            params.append(c)
                            j = raw.index(after: j)
                            continue
                        }
                        // final byte
                        applyCSI(params: params, final: c)
                        j = raw.index(after: j)
                        break
                    }
                    i = j
                    continue
                } else if n == "]" {
                    // OSC … BEL or ST — skip
                    var j = raw.index(after: next)
                    while j < raw.endIndex {
                        if raw[j] == "\u{7}" {
                            j = raw.index(after: j)
                            break
                        }
                        if raw[j] == "\u{1B}" {
                            let k = raw.index(after: j)
                            if k < raw.endIndex && raw[k] == "\\" {
                                j = raw.index(after: k)
                            }
                            break
                        }
                        j = raw.index(after: j)
                    }
                    i = j
                    continue
                } else if n == "(" || n == ")" {
                    // charset designate ESC ( B
                    i = raw.index(i, offsetBy: 3, limitedBy: raw.endIndex) ?? raw.endIndex
                    continue
                } else {
                    // other short ESC
                    i = raw.index(after: next)
                    continue
                }
            }

            switch ch {
            case "\n":
                newLine()
                i = raw.index(after: i)
            case "\r":
                col = 0
                i = raw.index(after: i)
            case "\t":
                let spaces = 8 - (col % 8)
                putRun(String(repeating: " ", count: spaces))
                i = raw.index(after: i)
            case "\u{08}": // BS
                backspace()
                i = raw.index(after: i)
            case "\u{7f}": // DEL often used as BS by terminals
                backspace()
                i = raw.index(after: i)
            case "\u{07}": // BEL
                i = raw.index(after: i)
            default:
                // Batch consecutive printable characters (big win vs put-per-char).
                if ch >= " " {
                    var j = i
                    while j < raw.endIndex {
                        let c = raw[j]
                        if c == "\u{1B}" || c < " " || c == "\u{7f}" { break }
                        j = raw.index(after: j)
                    }
                    putRun(String(raw[i..<j]))
                    i = j
                } else {
                    i = raw.index(after: i)
                }
            }
        }
        trimLines()
    }

    // MARK: - Mutations

    private mutating func ensureRow() {
        while row >= lines.count {
            lines.append("")
        }
    }

    /// Write a run of printable characters efficiently (one Array conversion per run).
    private mutating func putRun(_ s: String) {
        guard !s.isEmpty else { return }
        ensureRow()
        var line = Array(lines[row])
        // pad
        while line.count < col {
            line.append(" ")
        }
        for scalar in s {
            if col < line.count {
                line[col] = scalar
            } else {
                line.append(scalar)
            }
            col += 1
            if col > maxCols {
                // wrap soft
                lines[row] = String(line)
                newLine()
                line = Array(lines[row])
            }
        }
        lines[row] = String(line)
    }

    private mutating func backspace() {
        if col > 0 {
            col -= 1
            ensureRow()
            var line = Array(lines[row])
            if col < line.count {
                line.remove(at: col)
                lines[row] = String(line)
            }
        }
    }

    private mutating func newLine() {
        row += 1
        col = 0
        ensureRow()
    }

    private mutating func applyCSI(params: String, final: Character) {
        let parts = params.split(separator: ";").compactMap { Int($0) }
        let n = parts.first ?? 1
        switch final {
        case "A": // up
            row = max(0, row - n)
        case "B": // down
            row += n
            ensureRow()
        case "C": // forward
            col += n
        case "D": // back
            col = max(0, col - n)
        case "G": // absolute column (1-based)
            col = max(0, (parts.first ?? 1) - 1)
        case "H", "f": // cursor position row;col
            let r = max(1, parts.first ?? 1) - 1
            let c = max(1, (parts.count > 1 ? parts[1] : 1)) - 1
            row = r
            col = c
            ensureRow()
        case "K": // erase in line
            ensureRow()
            var line = Array(lines[row])
            let mode = parts.first ?? 0
            if mode == 0 {
                // erase to end
                if col < line.count {
                    line = Array(line.prefix(col))
                }
            } else if mode == 1 {
                // erase to start
                for i in 0..<min(col, line.count) {
                    line[i] = " "
                }
            } else {
                line = []
                col = 0
            }
            lines[row] = String(line)
        case "J": // erase in display — simplify
            let mode = parts.first ?? 0
            if mode == 2 || mode == 3 {
                lines = [""]
                row = 0
                col = 0
            } else if mode == 0 {
                // clear from cursor down
                ensureRow()
                lines[row] = String(Array(lines[row]).prefix(col))
                if row + 1 < lines.count {
                    lines.removeSubrange((row + 1)...)
                }
            }
        case "P": // delete n chars
            ensureRow()
            var line = Array(lines[row])
            let count = min(n, max(0, line.count - col))
            if count > 0 && col < line.count {
                line.removeSubrange(col..<(col + count))
                lines[row] = String(line)
            }
        case "m", "h", "l", "r", "s", "u", "n", "t":
            // SGR / modes — ignore for monochrome text buffer
            break
        default:
            break
        }
    }

    private mutating func trimLines() {
        if lines.count > maxLines {
            let drop = lines.count - maxLines
            lines.removeFirst(drop)
            row = max(0, row - drop)
        }
    }
}
