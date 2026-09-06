import Foundation
import IOKit

/// Minimal Apple SMC reader (SMCKit-style struct layout). Reads fan RPM and
/// temperature sensors on Apple Silicon without sudo.
final class SMC {
    static let shared = SMC()

    private var connection: io_connect_t = 0

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
    }

    var isAvailable: Bool { connection != 0 }

    // MARK: - SMC protocol structs

    // Must match the C SMCKeyData_t layout exactly (Swift does not tail-pad,
    // so the 3 padding bytes are explicit): keyInfo 28..40, result 40,
    // data8 42, data32 44, bytes 48..80, stride 80.
    private struct KeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var _pad: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }

    private struct KeyData {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0)
        var pLimitData: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var keyInfo = KeyInfoData()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Selector: UInt8 {
        case readBytes = 5
        case readKeyFromIndex = 8
        case readKeyInfo = 9
    }

    private let kernelIndexSMC: Int32 = 2

    private func fourChar(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        let inputSize = MemoryLayout<KeyData>.stride
        var outputSize = MemoryLayout<KeyData>.stride
        let kr = IOConnectCallStructMethod(connection, UInt32(kernelIndexSMC),
                                           &input, inputSize, &output, &outputSize)
        guard kr == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    // MARK: - Public API

    struct KeyInfo {
        let size: Int
        let type: String
    }

    func keyInfo(_ key: String) -> KeyInfo? {
        var input = KeyData()
        input.key = fourChar(key)
        input.data8 = Selector.readKeyInfo.rawValue
        guard let out = call(&input) else { return nil }
        let t = out.keyInfo.dataType
        let type = String(bytes: [UInt8(truncatingIfNeeded: t >> 24),
                                  UInt8(truncatingIfNeeded: t >> 16),
                                  UInt8(truncatingIfNeeded: t >> 8),
                                  UInt8(truncatingIfNeeded: t)], encoding: .utf8) ?? ""
        return KeyInfo(size: Int(out.keyInfo.dataSize), type: type)
    }

    /// Reads a key and returns its raw bytes (up to 32).
    func readBytes(_ key: String) -> (bytes: [UInt8], info: KeyInfo)? {
        guard let info = keyInfo(key) else { return nil }
        var input = KeyData()
        input.key = fourChar(key)
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = Selector.readBytes.rawValue
        guard let out = call(&input) else { return nil }
        let tuple = out.bytes
        let all: [UInt8] = withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: UInt8.self)) }
        return (Array(all.prefix(info.size)), info)
    }

    /// Numeric value of a key. Supports flt (float32), fpe2/sp78 fixed point,
    /// ui8/ui16/ui32.
    func readNumber(_ key: String) -> Double? {
        guard let (bytes, info) = readBytes(key) else { return nil }
        switch info.type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256.0
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default:
            return nil
        }
    }

    /// All SMC key codes (via the #KEY count + indexed enumeration).
    func allKeys() -> [String] {
        guard let count = readNumber("#KEY") else { return [] }
        var keys: [String] = []
        for i in 0..<UInt32(count) {
            var input = KeyData()
            input.data8 = Selector.readKeyFromIndex.rawValue
            input.data32 = i
            if let out = call(&input) {
                let k = out.key
                keys.append(String(bytes: [UInt8(truncatingIfNeeded: k >> 24),
                                           UInt8(truncatingIfNeeded: k >> 16),
                                           UInt8(truncatingIfNeeded: k >> 8),
                                           UInt8(truncatingIfNeeded: k)], encoding: .utf8) ?? "")
            }
        }
        return keys
    }
}
