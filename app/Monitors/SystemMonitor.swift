import Foundation
import IOKit

/// Samples CPU / memory / GPU utilization.
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    /// A top-N process row shown inside a gauge tile.
    struct ProcessUsage: Identifiable {
        var id: Int { pid }
        let pid: Int
        let name: String
        let value: String // preformatted, e.g. "87.3%" / "4.2 GB"
    }

    struct Snapshot {
        var cpuUsage: Double = 0      // 0...1
        var gpuUsage: Double? = nil   // 0...1, nil if unavailable
        var memoryUsedGB: Double = 0
        var memoryTotalGB: Double = 0
        var memoryUsedFraction: Double = 0
        var cpuTop: [ProcessUsage] = []
        var memoryTop: [ProcessUsage] = []
        var gpuTop: [ProcessUsage] = []
        // SMC sensors (Apple Silicon)
        var fanRPM: Double? = nil     // fan 0, nil when fanless
        var fan2RPM: Double? = nil    // fan 1 if present
        var cpuTempC: Double? = nil
        var gpuTempC: Double? = nil
        // Clock frequencies (IOReport performance states)
        var cpuFreqMHz: Int? = nil
        var gpuFreqMHz: Int? = nil
    }

    @Published private(set) var snapshot = Snapshot()

    private var timer: Timer?
    private var previousCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var previousGPUTimes: [Int32: UInt64]?
    private var previousGPUTimesAt: Date?

    private init() {}

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        var s = Snapshot()
        s.cpuUsage = sampleCPU()
        s.gpuUsage = sampleGPU()
        let (used, total) = sampleMemory()
        s.memoryUsedGB = used
        s.memoryTotalGB = total
        s.memoryUsedFraction = total > 0 ? used / total : 0
        s.cpuTop = topCPUProcesses()
        s.memoryTop = topMemoryProcesses()
        s.gpuTop = topGPUProcesses(systemGpuFraction: s.gpuUsage)
        sampleSensors(&s)
        let freqs = FrequencyReader.shared.sample()
        s.cpuFreqMHz = freqs.cpuMHz
        s.gpuFreqMHz = freqs.gpuMHz
        snapshot = s
    }

    // MARK: - SMC sensors (fan RPM + temperatures)

    /// Resolved once: SMC key names vary by chip, so we probe once and cache.
    private var sensorKeys: (fanCount: Int, cpuTempKey: String, gpuTempKey: String)?

    private func sampleSensors(_ s: inout Snapshot) {
        let smc = SMC.shared
        guard smc.isAvailable else { return }

        if sensorKeys == nil {
            let fanCount = Int(smc.readNumber("FNum") ?? 0)
            // CPU die sensor; fall back to the hottest p/e-cluster sensor.
            var cpuKey = "TCMb"
            if smc.readNumber(cpuKey) == nil {
                cpuKey = hottestTempKey(secondChars: ["p", "e"]) ?? ""
            }
            let gpuKey = hottestTempKey(secondChars: ["g"]) ?? ""
            sensorKeys = (fanCount, cpuKey, gpuKey)
        }
        let keys = sensorKeys!

        if keys.fanCount > 0 {
            s.fanRPM = smc.readNumber("F0Ac")
            if keys.fanCount > 1 { s.fan2RPM = smc.readNumber("F1Ac") }
        }
        if !keys.cpuTempKey.isEmpty { s.cpuTempC = smc.readNumber(keys.cpuTempKey) }
        if !keys.gpuTempKey.isEmpty { s.gpuTempC = smc.readNumber(keys.gpuTempKey) }
    }

    /// Hottest plausible temperature key whose second character is in the set
    /// (SMC convention: Tp* = CPU P-core, Te* = E-core, Tg* = GPU).
    private func hottestTempKey(secondChars: Set<Character>) -> String? {
        var best: (key: String, value: Double)?
        for key in SMC.shared.allKeys() where key.hasPrefix("T") && key.count > 1 {
            let second = key[key.index(key.startIndex, offsetBy: 1)]
            guard secondChars.contains(second),
                  let v = SMC.shared.readNumber(key), v > 10, v < 130 else { continue }
            if best == nil || v > best!.value { best = (key, v) }
        }
        return best?.key
    }

    // MARK: - Top processes (via ps, sorted by ps itself)

    /// `ps -Aco pid=,<metric>=,comm= <sortFlag>`; -r sorts by CPU, -m by memory.
    private func topCPUProcesses() -> [ProcessUsage] {
        parsePS(arguments: ["-Aco", "pid=,pcpu=,comm=", "-r"]) { pid, metric, name in
            ProcessUsage(pid: pid, name: friendlyName(name),
                         value: String(format: "%.1f%%", Double(metric) ?? 0))
        }
    }

    /// Activity Monitor's "Memory" column is phys_footprint. `top -l 1 -o mem`
    /// reports exactly that in its MEM column for *every* process (including
    /// root-owned ones we can't proc_pid_rusage), so its ordering matches
    /// Activity Monitor. We parse MEM (e.g. "461M", "1080M", "1.2G") directly
    /// rather than mixing footprint + RSS, which used to over-rank RSS-only
    /// processes like wdavdaemon.
    private func topMemoryProcesses() -> [ProcessUsage] {
        let rows = topMemRows()
        return rows.prefix(3).map { pid, name, bytes in
            let gb = Double(bytes) / 1e9
            let text = gb >= 1 ? String(format: "%.1f GB", gb)
                               : String(format: "%.0f MB", gb * 1000)
            return ProcessUsage(pid: pid, name: friendlyName(name), value: text)
        }
    }

    /// Run `top` once, mem-sorted, and parse (pid, command, footprintBytes).
    /// `top`'s tabular output puts COMMAND and MEM in fixed positions; we key
    /// off the column headers so we don't depend on their absolute index.
    private func topMemRows() -> [(pid: Int, name: String, bytes: UInt64)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "1", "-o", "mem", "-n", "12",
                             "-stats", "pid,command,mem"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var rows: [(pid: Int, name: String, bytes: UInt64)] = []
        var inTable = false
        for line in output.split(separator: "\n") {
            // The data table begins after the "PID  COMMAND  MEM" header.
            if !inTable {
                if line.hasPrefix("PID") { inTable = true }
                continue
            }
            // Columns: PID COMMAND MEM. COMMAND may contain spaces, so split
            // the PID off the front and the MEM off the back.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = trimmed.firstIndex(of: " "),
                  let pid = Int(trimmed[..<firstSpace]) else { continue }
            let rest = trimmed[trimmed.index(after: firstSpace)...]
                .trimmingCharacters(in: .whitespaces)
            guard let lastSpace = rest.lastIndex(of: " ") else { continue }
            let name = String(rest[..<lastSpace]).trimmingCharacters(in: .whitespaces)
            let memToken = String(rest[rest.index(after: lastSpace)...])
            guard let bytes = parseTopMem(memToken) else { continue }
            rows.append((pid, name, bytes))
        }
        return rows
    }

    /// Parse top's MEM token: "461M", "1080M", "1.2G", "512K", "8192B".
    private func parseTopMem(_ token: String) -> UInt64? {
        guard let unit = token.last else { return nil }
        let numberPart = token.dropLast()
        guard let value = Double(numberPart) else { return nil }
        let multiplier: Double
        switch unit {
        case "B": multiplier = 1
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        case "T": multiplier = 1024 * 1024 * 1024 * 1024
        default:  return nil
        }
        return UInt64(value * multiplier)
    }

    /// Map raw executable names (comm) to the friendlier labels Activity
    /// Monitor shows. Covers the common XPC/helper processes whose comm is a
    /// reverse-DNS identifier; falls back to the raw name otherwise.
    func friendlyName(_ comm: String) -> String {
        // Exact matches first.
        if let mapped = Self.nameMap[comm] { return mapped }
        // `top` truncates the command column, so also match by prefix for the
        // known long identifiers.
        for (prefix, label) in Self.namePrefixMap where comm.hasPrefix(prefix) {
            return label
        }
        // WebKit XPC services. `ps` gives the full "com.apple.WebKit.GPU";
        // `top` truncates the command to "com.apple.WebKit", so match both.
        if comm.hasPrefix("com.apple.WebKit") {
            let suffix = comm
                .replacingOccurrences(of: "com.apple.WebKit.", with: "")
                .replacingOccurrences(of: "com.apple.WebKit", with: "")
            return suffix.isEmpty ? "WebKit" : "WebKit \(suffix)"
        }
        return comm
    }

    private static let nameMap: [String: String] = [
        "WindowServer": "WindowServer",
        "mysqld":       "mysqld",
    ]

    /// Prefix matches — handle `top`'s truncated command names (e.g.
    /// "wdavdaemon_unpri" for "wdavdaemon_unprivileged").
    private static let namePrefixMap: [(String, String)] = [
        ("wdavdaemon", "Microsoft Defender"),
    ]

    // MARK: - Top GPU processes (IORegistry AGXDeviceUserClient)

    /// Per-process GPU usage: each process using the GPU has an
    /// AGXDeviceUserClient node under AGXAccelerator with an accumulated GPU
    /// time (nanoseconds). Diff between samples, then normalize so the shares
    /// sum to the system-wide GPU utilization (same approach as mactop).
    private func topGPUProcesses(systemGpuFraction: Double?) -> [ProcessUsage] {
        guard let sys = systemGpuFraction, sys > 0 else {
            // Keep the baseline fresh even when idle so the next busy sample
            // has a reference point.
            previousGPUTimes = gpuProcessTimes()
            previousGPUTimesAt = Date()
            return []
        }
        let now = Date()
        let current = gpuProcessTimes()
        defer {
            previousGPUTimes = current
            previousGPUTimesAt = now
        }
        guard let prev = previousGPUTimes, let prevAt = previousGPUTimesAt else { return [] }
        let elapsed = now.timeIntervalSince(prevAt)
        guard elapsed > 0 else { return [] }

        var perPid: [(pid: Int32, msPerSec: Double)] = []
        var totalMs = 0.0
        for (pid, cur) in current {
            guard let old = prev[pid], cur >= old else { continue }
            let ms = Double(cur - old) / elapsed / 1_000_000
            if ms > 0.1 { perPid.append((pid, ms)); totalMs += ms }
        }
        guard totalMs > 0 else { return [] }

        let top = perPid.sorted { $0.msPerSec > $1.msPerSec }.prefix(3)
        let names = processNames(pids: top.map { $0.pid })
        let sysPercent = sys * 100
        return top.map { pid, ms in
            ProcessUsage(pid: Int(pid),
                         name: friendlyName(names[pid] ?? "pid \(pid)"),
                         value: String(format: "%.1f%%", ms / totalMs * sysPercent))
        }
    }

    /// pid → accumulated GPU time (ns), summed across all of the process's
    /// AGXDeviceUserClient nodes.
    private func gpuProcessTimes() -> [Int32: UInt64] {
        var result: [Int32: UInt64] = [:]
        let accelerator = IOServiceGetMatchingService(kIOMainPortDefault,
                                                      IOServiceMatching("AGXAccelerator"))
        guard accelerator != 0 else { return result }
        defer { IOObjectRelease(accelerator) }

        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(childIter) }

        while true {
            let child = IOIteratorNext(childIter)
            if child == 0 { break }
            defer { IOObjectRelease(child) }

            // io_name_t is a 128-CChar tuple whose literal init trips a
            // swiftc diagnostic bug — use a raw char buffer instead.
            let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
            nameBuf.initialize(repeating: 0, count: 128)
            let namePtr = UnsafeMutableRawPointer(nameBuf).assumingMemoryBound(to: io_name_t.self)
            let gotClass = IOObjectGetClass(child, namePtr) == KERN_SUCCESS
            let cls = gotClass ? String(cString: nameBuf) : ""
            nameBuf.deallocate()
            guard cls == "AGXDeviceUserClient" else { continue }

            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(child, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any],
                  let creator = props["IOUserClientCreator"] as? String,
                  let pid = parseCreatorPid(creator) else { continue }

            var total: UInt64 = 0
            if let appUsage = props["AppUsage"] as? [[String: Any]] {
                for entry in appUsage {
                    if let t = entry["accumulatedGPUTime"] as? NSNumber, t.int64Value > 0 {
                        total &+= t.uint64Value
                    }
                }
            }
            if total > 0 { result[pid, default: 0] &+= total }
        }
        return result
    }

    /// "pid 682, WindowServer" → 682
    private func parseCreatorPid(_ creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let rest = creator.dropFirst(4)
        guard let comma = rest.firstIndex(of: ",") else { return nil }
        return Int32(rest[..<comma])
    }

    /// Resolve names for a small pid list with a single ps call.
    private func processNames(pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-co", "pid=,comm=", "-p", list]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard let _ = try? process.run() else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var names: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            names[pid] = String(parts[1])
        }
        return names
    }

    private func parsePS(arguments: [String],
                         make: (Int, String, String) -> ProcessUsage) -> [ProcessUsage] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard let _ = try? process.run() else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var result: [ProcessUsage] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]) else { continue }
            result.append(make(pid, String(parts[1]), String(parts[2])))
            if result.count == 3 { break }
        }
        return result
    }

    // MARK: - CPU (delta of PROCESSOR_CPU_LOAD_INFO ticks)

    private func sampleCPU() -> Double {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &numCPUs, &cpuInfo, &numCPUInfo)
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return 0 }
        defer {
            let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        let count = Int(numCPUs)
        for i in 0..<count {
            let base = Int(CPU_STATE_MAX) * i
            user += UInt64(info[base + Int(CPU_STATE_USER)])
            system += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            idle += UInt64(info[base + Int(CPU_STATE_IDLE)])
            nice += UInt64(info[base + Int(CPU_STATE_NICE)])
        }

        let current = (user, system, idle, nice)
        defer { previousCPUTicks = current }
        guard let prev = previousCPUTicks else { return 0 }

        let dUser = user &- prev.user, dSystem = system &- prev.system
        let dIdle = idle &- prev.idle, dNice = nice &- prev.nice
        let total = dUser &+ dSystem &+ dIdle &+ dNice
        guard total > 0 else { return 0 }
        return Double(dUser &+ dSystem &+ dNice) / Double(total)
    }

    // MARK: - Memory (HOST_VM_INFO64)

    private func sampleMemory() -> (usedGB: Double, totalGB: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        let pageSize = UInt64(vm_kernel_page_size)
        let usedPages = UInt64(stats.active_count) + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        return (Double(usedPages * pageSize) / 1e9, Double(totalBytes) / 1e9)
    }

    // MARK: - GPU (IOAccelerator performance statistics, no sudo needed)

    private func sampleGPU() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard let props = IORegistryEntryCreateCFProperty(
                entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            if let v = props["Device Utilization %"] as? NSNumber {
                return min(max(v.doubleValue / 100.0, 0), 1)
            }
        }
        return nil
    }
}
