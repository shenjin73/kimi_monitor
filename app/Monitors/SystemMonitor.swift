import Foundation
import IOKit

/// Samples CPU / memory / GPU utilization.
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    struct Snapshot {
        var cpuUsage: Double = 0      // 0...1
        var gpuUsage: Double? = nil   // 0...1, nil if unavailable
        var memoryUsedGB: Double = 0
        var memoryTotalGB: Double = 0
        var memoryUsedFraction: Double = 0
    }

    @Published private(set) var snapshot = Snapshot()

    private var timer: Timer?
    private var previousCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

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
        snapshot = s
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
