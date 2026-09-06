import Foundation
import IOKit

/// Reads current GPU / CPU clock frequencies via IOReport performance-state
/// residency channels (same private-but-exported IOKit API powermetrics and
/// mactop use, no sudo). Frequencies are residency-weighted averages over
/// each sampling window, using the pmgr/clpc voltage-state tables.
final class FrequencyReader {
    static let shared = FrequencyReader()

    struct Frequencies {
        var gpuMHz: Int?
        var cpuMHz: Int? // fastest cluster's average
    }

    private var subscription: IOReportSubscriptionRef?
    private var channels: CFDictionary?
    private var previousSample: CFDictionary?

    private var gpuTable: [Int] = []   // state index → MHz
    private var eTable: [Int] = []
    private var pTable: [Int] = []
    private var sTable: [Int] = []     // M5+ medium/super cluster

    private init() {
        loadTables()
        setupSubscription()
    }

    // MARK: - Sampling

    /// Returns frequencies for the window since the previous call
    /// (first call after init returns nil — it only establishes a baseline).
    func sample() -> Frequencies {
        var result = Frequencies()
        guard let sub = subscription, let chans = channels,
              let sample = IOReportCreateSamples(sub, chans, nil)?.takeRetainedValue() else { return result }

        defer { previousSample = sample }
        guard let prev = previousSample,
              let delta = IOReportCreateSamplesDelta(prev, sample, nil)?.takeRetainedValue() else { return result }

        guard let arr = (delta as NSDictionary)["IOReportChannels"] as? [Any] else { return result }

        var cpuMax = 0
        for item in arr {
            let channel = item as! CFDictionary
            let subgroup = cfString(IOReportChannelGetSubGroup(channel))
            let name = cfString(IOReportChannelGetChannelName(channel))

            if subgroup == "GPU Performance States", name == "GPUPH" {
                result.gpuMHz = gpuFrequency(channel)
            } else if subgroup == "CPU Complex Performance States" {
                let f = cpuClusterFrequency(channel, name: name)
                if f > cpuMax { cpuMax = f }
            }
        }
        result.cpuMHz = cpuMax > 0 ? cpuMax : nil
        return result
    }

    private func gpuFrequency(_ channel: CFDictionary) -> Int? {
        let stateCount = IOReportStateGetCount(channel)
        var activeTime: Int64 = 0
        var weighted: Double = 0
        var activeIdx = 0
        for s in 0..<stateCount {
            let residency = IOReportStateGetResidency(channel, s)
            let name = cfString(IOReportStateGetNameForIndex(channel, s))
            if name != "OFF" && name != "IDLE" && name != "DOWN" {
                activeTime += residency
                if activeIdx < gpuTable.count {
                    weighted += Double(gpuTable[activeIdx]) * Double(residency)
                }
                activeIdx += 1
            }
        }
        guard activeTime > 0, !gpuTable.isEmpty else { return nil }
        return Int(weighted / Double(activeTime))
    }

    private func cpuClusterFrequency(_ channel: CFDictionary, name: String) -> Int {
        let isM = name.contains("MCPU")
        let isS = name.contains("SCPU")
        let isE = name.contains("ECPU") || (!isM && name == "CPU0")
        let isP = name.contains("PCPU") || (!isM && name == "CPU1")
        guard isE || isP || isS || isM else { return 0 }

        let stateCount = IOReportStateGetCount(channel)
        var activeTime: Int64 = 0
        var weighted: Double = 0
        for s in 0..<stateCount {
            let residency = IOReportStateGetResidency(channel, s)
            let stateName = cfString(IOReportStateGetNameForIndex(channel, s))
            guard stateName != "OFF", stateName != "IDLE" else { continue }
            activeTime += residency
            var freq = 0
            // State names look like "V15P4" — only the leading digits after
            // 'V' are the table index (same as sscanf("V%d")).
            if stateName.hasPrefix("V") {
                let digits = stateName.dropFirst().prefix(while: { $0.isNumber })
                if let idx = Int(digits) {
                    if isE, idx < eTable.count { freq = eTable[idx] }
                    else if isM, idx < sTable.count { freq = sTable[idx] }
                    else if isM, idx < pTable.count { freq = pTable[idx] }
                    else if isP, idx < pTable.count { freq = pTable[idx] }
                    else if isS, idx < sTable.count { freq = sTable[idx] }
                }
            }
            if freq == 0, let num = stateName.first(where: { $0.isNumber }),
               let parsed = Int(stateName.drop(while: { !$0.isNumber })) {
                _ = num
                freq = parsed
            }
            if freq > 0 { weighted += Double(freq) * Double(residency) }
        }
        guard activeTime > 0 else { return 0 }
        return Int(weighted / Double(activeTime))
    }

    // MARK: - Setup

    private func cfString(_ ref: Unmanaged<CFString>?) -> String {
        (ref?.takeUnretainedValue() as String?) ?? ""
    }

    /// voltage-state tables from the pmgr/clpc IORegistry nodes (8-byte
    /// entries, frequency in the first 4 bytes).
    private func loadTables() {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleARMIODevice"),
                                           &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        while true {
            let entry = IOIteratorNext(iter)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
            nameBuf.initialize(repeating: 0, count: 128)
            IORegistryEntryGetName(entry, nameBuf)
            let name = String(cString: nameBuf)
            nameBuf.deallocate()

            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any] else { continue }

            if name == "pmgr" {
                if eTable.isEmpty {
                    eTable = parseTable(props["voltage-states1-sram"] as? Data)
                    if eTable.isEmpty { eTable = parseTable(props["voltage-states9-sram"] as? Data) }
                }
                if pTable.isEmpty {
                    pTable = parseTable(props["voltage-states5-sram"] as? Data)
                }
                if sTable.isEmpty {
                    sTable = parseTable(props["voltage-states22-sram"] as? Data)
                    if sTable.isEmpty { sTable = parseTable(props["voltage-states23-sram"] as? Data) }
                }
            }
            if name == "pmgr" || name == "clpc", gpuTable.isEmpty {
                // Prefer vs9 keys; otherwise the voltage-states* table with the
                // lowest max frequency (GPU clocks are the lowest on-package).
                if let exact = props["voltage-states9-sram"] as? Data ?? props["voltage-states9"] as? Data {
                    gpuTable = parseTable(exact)
                } else {
                    var bestMax = Int.max
                    var best: [Int] = []
                    for (k, v) in props where k.hasPrefix("voltage-states") {
                        guard let data = v as? Data else { continue }
                        let t = parseTable(data)
                        guard let mx = t.max(), !t.isEmpty, mx < bestMax else { continue }
                        bestMax = mx
                        best = t
                    }
                    gpuTable = best
                }
            }
        }
    }

    private func parseTable(_ data: Data?) -> [Int] {
        guard let data else { return [] }
        var result: [Int] = []
        data.withUnsafeBytes { raw in
            let count = raw.count / 8
            for i in 0..<count {
                let v = raw.load(fromByteOffset: i * 8, as: UInt32.self)
                // Heuristic from mactop: raw value may be Hz or kHz.
                let mhz: Int
                if v >= 100_000_000 { mhz = Int(v / 1_000_000) }
                else if v >= 100_000 { mhz = Int(v / 1_000) }
                else { mhz = 0 }
                if mhz > 0 { result.append(mhz) }
            }
        }
        return result
    }

    private func setupSubscription() {
        guard let gpu = IOReportCopyChannelsInGroup("GPU Stats" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let cpu = IOReportCopyChannelsInGroup("CPU Stats" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return }
        IOReportMergeChannels(gpu, cpu, nil)
        guard let merged = CFDictionaryCreateMutableCopy(nil, 0, gpu) else { return }
        channels = merged
        var subsystem: Unmanaged<CFMutableDictionary>?
        subscription = withUnsafeMutablePointer(to: &subsystem) { ptr in
            IOReportCreateSubscription(nil, merged, ptr, 0, nil)
        }
        // Establish the baseline so the first visible sample has a delta.
        _ = sample()
    }
}
