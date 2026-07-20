import Foundation
import Darwin

enum TerminalError: LocalizedError {
    case ptyFailed
    case launchFailed(String)
    case invalidDirectory(String)

    var errorDescription: String? {
        switch self {
        case .ptyFailed: return "Impossibile creare PTY"
        case .launchFailed(let m): return "Avvio shell fallito: \(m)"
        case .invalidDirectory(let p): return "Directory non valida: \(p)"
        }
    }
}

/// Real macOS pseudo-terminal process (like VS Code integrated terminal).
/// Output is coalesced on a background queue (~60 fps max) to avoid flooding MainActor.
final class PTYProcess {
    private(set) var masterFD: Int32 = -1
    private var process: Process?
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.qsagents.pty", qos: .userInteractive)

    /// Accumulated bytes waiting for a coalesced flush to MainActor.
    private var pendingOutput = Data()
    private var flushScheduled = false
    /// ~16 ms → at most ~60 UI updates/s even under heavy output.
    private let coalesceInterval: DispatchTimeInterval = .milliseconds(16)
    /// Flush immediately if a single burst exceeds this (keeps large dumps moving).
    private let flushByteThreshold = 48_000

    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { process?.isRunning == true }

    func start(
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        cwd: String,
        cols: UInt16 = 140,
        rows: UInt16 = 36,
        environmentMode: AgentProcessEnvironment.Mode = .inherit
    ) throws {
        terminate()

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            throw TerminalError.invalidDirectory(cwd)
        }

        var master: Int32 = 0
        var slave: Int32 = 0
        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&master, &slave, nil, nil, &win) != -1 else {
            throw TerminalError.ptyFailed
        }

        // Make master non-blocking for clean reads
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        masterFD = master

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // Interactive login-like shell
        if shell.hasSuffix("zsh") {
            proc.arguments = ["-i"]
        } else if shell.hasSuffix("bash") {
            proc.arguments = ["-i"]
        } else {
            proc.arguments = ["-i"]
        }
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let inHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let outHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let errHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        proc.standardInput = inHandle
        proc.standardOutput = outHandle
        proc.standardError = errHandle

        var env = AgentProcessEnvironment.prepare(mode: environmentMode)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["LC_ALL"] = env["LC_ALL"] ?? env["LANG"]
        // Help shells know they're interactive
        env["QS_AGENTS_TERM"] = "1"
        proc.environment = env

        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            // Flush any remaining coalesced output before exit callback.
            self?.queue.async {
                self?.flushPending(force: true)
                DispatchQueue.main.async {
                    self?.onExit?(code)
                }
            }
        }

        do {
            try proc.run()
        } catch {
            close(master)
            close(slave)
            masterFD = -1
            throw TerminalError.launchFailed(error.localizedDescription)
        }

        process = proc
        // Parent no longer needs slave
        close(slave)

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let n = read(self.masterFD, &buffer, buffer.count)
                if n > 0 {
                    self.pendingOutput.append(contentsOf: buffer[0..<n])
                    if self.pendingOutput.count >= self.flushByteThreshold {
                        self.flushPending(force: true)
                    } else {
                        self.scheduleFlush()
                    }
                } else if n == 0 {
                    self.flushPending(force: true)
                    source.cancel()
                    break
                } else {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                        break
                    }
                    self.flushPending(force: true)
                    source.cancel()
                    break
                }
            }
        }
        source.setCancelHandler { }
        source.resume()
        readSource = source
    }

    /// Coalesce: one MainActor hop per interval instead of per read().
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + coalesceInterval) { [weak self] in
            self?.flushPending(force: false)
        }
    }

    private func flushPending(force: Bool) {
        flushScheduled = false
        guard !pendingOutput.isEmpty else { return }
        let batch = pendingOutput
        pendingOutput = Data()
        let callback = onOutput
        DispatchQueue.main.async {
            callback?(batch)
        }
        // If more arrived while we were scheduling, force ensures we don't drop schedule state incorrectly.
        _ = force
    }

    func write(_ data: Data) {
        guard masterFD >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            let total = data.count
            while written < total {
                let n = Darwin.write(masterFD, base.advanced(by: written), total - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                written += n
            }
        }
    }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        write(data)
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        var win = winsize(ws_row: max(1, rows), ws_col: max(1, cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &win)
        // Notify shell
        if let pid = process?.processIdentifier, pid > 0 {
            kill(pid, SIGWINCH)
        }
    }

    func terminate() {
        readSource?.cancel()
        readSource = nil
        queue.sync {
            pendingOutput = Data()
            flushScheduled = false
        }
        if let proc = process, proc.isRunning {
            proc.terminate()
            // Give it a moment then force
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                if proc.isRunning { proc.interrupt() }
            }
        }
        process = nil
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    deinit {
        readSource?.cancel()
        if let proc = process, proc.isRunning { proc.terminate() }
        if masterFD >= 0 { close(masterFD) }
    }
}
