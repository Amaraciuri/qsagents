import Foundation
import Combine
import Darwin

struct ProcessInfoRow: Identifiable, Equatable {
    let id: Int32
    var pid: Int32 { id }
    var name: String
    var cpu: Double
    var memMB: Double
    var user: String
}

struct SystemSnapshot {
    var hostname: String
    var username: String
    var cpuPercent: Double
    var memoryUsedGB: Double
    var memoryTotalGB: Double
    var loadAvg1: Double
    var loadAvg5: Double
    var loadAvg15: Double
    var uptimeHours: Double
    var topProcesses: [ProcessInfoRow]
    var listeningPorts: [String]
    var shell: String
    var home: String
    var timestamp: Date

    var loadAvg: (Double, Double, Double) { (loadAvg1, loadAvg5, loadAvg15) }

    static let empty = SystemSnapshot(
        hostname: "—",
        username: "—",
        cpuPercent: 0,
        memoryUsedGB: 0,
        memoryTotalGB: 0,
        loadAvg1: 0,
        loadAvg5: 0,
        loadAvg15: 0,
        uptimeHours: 0,
        topProcesses: [],
        listeningPorts: [],
        shell: "/bin/zsh",
        home: NSHomeDirectory(),
        timestamp: .distantPast
    )
}

@MainActor
final class SystemProbe: ObservableObject {
    @Published var snapshot: SystemSnapshot = .empty
    @Published var isRefreshing: Bool = false

    private var timer: AnyCancellable?
    private var tick: UInt64 = 0
    /// How often light metrics (Mach CPU/RAM/load) refresh.
    private let lightInterval: TimeInterval = 3.0
    /// Every N light ticks, also run expensive shell process/port sampling.
    private let heavyEveryNTicks: UInt64 = 5 // ~15s at 3s light interval
    /// Previous CPU tick sample for delta % (host_processor_info).
    nonisolated(unsafe) private static var prevCPU: (idle: UInt64, total: UInt64)?
    /// Cached static identity fields.
    private var cachedHost: String?
    private var cachedUser: String?
    private var cachedShell: String?
    private var cachedHome: String?

    func start(interval: TimeInterval = 3.0) {
        // Keep parameter for API compat; prefer dual-cadence defaults.
        _ = interval
        refresh(includeHeavy: true)
        timer = Timer.publish(every: lightInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.tick &+= 1
                let heavy = self.tick % self.heavyEveryNTicks == 0
                self.refresh(includeHeavy: heavy)
            }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func refresh(includeHeavy: Bool = true) {
        guard !isRefreshing else { return }
        isRefreshing = true

        let prevProcs = snapshot.topProcesses
        let prevPorts = snapshot.listeningPorts
        let host = cachedHost ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let user = cachedUser ?? NSUserName()
        let home = cachedHome ?? NSHomeDirectory()
        let shell = cachedShell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        cachedHost = host
        cachedUser = user
        cachedHome = home
        cachedShell = shell

        Task.detached(priority: .utility) {
            let snap = Self.collect(
                includeHeavy: includeHeavy,
                host: host,
                user: user,
                home: home,
                shell: shell,
                previousProcesses: prevProcs,
                previousPorts: prevPorts
            )
            await MainActor.run {
                self.snapshot = snap
                self.isRefreshing = false
            }
        }
    }

    /// Compact context for the orchestrator LLM / rules engine.
    func contextBlock(terminals: String, directories: String) -> String {
        let s = snapshot
        let procs = s.topProcesses.prefix(8).map {
            "  pid=\($0.pid) \($0.name) cpu=\(String(format: "%.1f", $0.cpu))% mem=\(String(format: "%.0f", $0.memMB))MB"
        }.joined(separator: "\n")
        let ports = s.listeningPorts.prefix(12).joined(separator: ", ")
        return """
        === SISTEMA macOS (live) ===
        Host: \(s.hostname) · User: \(s.username)
        CPU: \(String(format: "%.0f", s.cpuPercent))% · RAM: \(String(format: "%.1f", s.memoryUsedGB))/\(String(format: "%.1f", s.memoryTotalGB)) GB
        Load: \(String(format: "%.2f %.2f %.2f", s.loadAvg1, s.loadAvg5, s.loadAvg15))
        Uptime: \(String(format: "%.1f", s.uptimeHours))h · Shell: \(s.shell)
        Home: \(s.home)
        Porte in ascolto: \(ports.isEmpty ? "n/d" : ports)

        === TERMINALI APERTI ===
        \(terminals)

        === DIRECTORY / PROGETTI ===
        \(directories)

        === TOP PROCESSI ===
        \(procs.isEmpty ? "n/d" : procs)
        """
    }

    // MARK: - Collection (background)

    nonisolated private static func collect(
        includeHeavy: Bool,
        host: String,
        user: String,
        home: String,
        shell: String,
        previousProcesses: [ProcessInfoRow],
        previousPorts: [String]
    ) -> SystemSnapshot {
        let mem = memoryStats()
        let load = loadAverage()
        let uptime = ProcessInfo.processInfo.systemUptime / 3600.0

        // Prefer host CPU ticks; never require shell for light path.
        var cpu = hostCPUPercent()
        let procs: [ProcessInfoRow]
        let ports: [String]
        if includeHeavy {
            procs = topProcesses()
            ports = listeningPorts()
            if cpu <= 0.1 {
                let fromProcs = estimateCPU(from: procs)
                if fromProcs > 0.5 {
                    cpu = fromProcs
                } else {
                    let ncpu = Double(ProcessInfo.processInfo.processorCount)
                    cpu = min(100, max(0, (load.0 / max(ncpu, 1)) * 100))
                }
            }
        } else {
            procs = previousProcesses
            ports = previousPorts
            if cpu <= 0.1 {
                let ncpu = Double(ProcessInfo.processInfo.processorCount)
                cpu = min(100, max(0, (load.0 / max(ncpu, 1)) * 100))
            }
        }

        return SystemSnapshot(
            hostname: host,
            username: user,
            cpuPercent: cpu,
            memoryUsedGB: mem.used,
            memoryTotalGB: mem.total,
            loadAvg1: load.0,
            loadAvg5: load.1,
            loadAvg15: load.2,
            uptimeHours: uptime,
            topProcesses: procs,
            listeningPorts: ports,
            shell: shell,
            home: home,
            timestamp: Date()
        )
    }

    /// Real system CPU % from mach host_processor_info (delta between samples).
    nonisolated private static func hostCPUPercent() -> Double {
        var numCPU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPU,
            &cpuInfo,
            &numCpuInfo
        )
        guard result == KERN_SUCCESS, let info = cpuInfo else { return 0 }

        defer {
            let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var idle: UInt64 = 0
        var total: UInt64 = 0
        let loadInfo = UnsafeRawPointer(info).bindMemory(to: processor_cpu_load_info.self, capacity: Int(numCPU))
        for i in 0..<Int(numCPU) {
            let cpu = loadInfo[i]
            // user, system, idle, nice
            let u = UInt64(cpu.cpu_ticks.0)
            let s = UInt64(cpu.cpu_ticks.1)
            let id = UInt64(cpu.cpu_ticks.2)
            let n = UInt64(cpu.cpu_ticks.3)
            idle += id
            total += u + s + id + n
        }

        defer { prevCPU = (idle, total) }

        guard let prev = prevCPU, total > prev.total else {
            return 0 // first sample — need a second tick
        }
        let dTotal = total - prev.total
        let dIdle = idle - prev.idle
        guard dTotal > 0 else { return 0 }
        let used = 1.0 - (Double(dIdle) / Double(dTotal))
        return min(100, max(0, used * 100))
    }

    nonisolated private static func memoryStats() -> (used: Double, total: Double) {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmstat = vm_statistics64()
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &vmstat) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &size)
            }
        }
        let pageSize = Double(vm_kernel_page_size)
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        guard kerr == KERN_SUCCESS else {
            return (0, total)
        }
        let active = Double(vmstat.active_count) * pageSize
        let wired = Double(vmstat.wire_count) * pageSize
        let compressed = Double(vmstat.compressor_page_count) * pageSize
        let used = (active + wired + compressed) / 1_073_741_824
        return (used, total)
    }

    nonisolated private static func loadAverage() -> (Double, Double, Double) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return (0, 0, 0) }
        return (loads[0], loads[1], loads[2])
    }

    nonisolated private static func estimateCPU(from procs: [ProcessInfoRow]) -> Double {
        min(100, procs.prefix(15).reduce(0) { $0 + $1.cpu })
    }

    nonisolated private static func topProcesses() -> [ProcessInfoRow] {
        // Locale-independent numeric fields; try a few ps formats
        let out = shell("/bin/ps -A -o %cpu= -o rss= -o user= -o pid= -o comm= -r 2>/dev/null | /usr/bin/head -n 15")
        var rows: [ProcessInfoRow] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 5,
                  let cpu = Double(parts[0].replacingOccurrences(of: ",", with: ".")),
                  let rss = Double(parts[1]),
                  let pid = Int32(parts[parts.count - 2]) ?? Int32(parts[3]) else { continue }
            // user may contain spaces rarely; take last-2 as pid if needed
            let name = parts.last ?? "?"
            let user = parts.count > 5 ? parts[2] : parts[2]
            rows.append(ProcessInfoRow(id: pid, name: name, cpu: cpu, memMB: rss / 1024.0, user: user))
        }
        return rows
    }

    nonisolated private static func listeningPorts() -> [String] {
        // Lightweight: lsof may be slow/restricted — use netstat
        let out = shell("netstat -anv -p tcp 2>/dev/null | grep LISTEN | head -n 20")
        var ports: [String] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 4 else { continue }
            let local = parts[3]
            if let port = local.split(separator: ".").last ?? local.split(separator: ":").last {
                let p = String(port)
                if !ports.contains(p) { ports.append(p) }
            }
        }
        return ports
    }

    nonisolated private static func shell(_ command: String) -> String {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
