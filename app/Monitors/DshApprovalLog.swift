import Foundation

/// Answers "is this dsh session sitting on an approval prompt right now?".
///
/// dsh emits neither a hook event nor a projection row for approvals, so the
/// only trace is the session log's own audit pair: `approval/asked{id,…}`
/// followed by `approval/decided{id}`. While the prompt is on screen nothing
/// else is appended, so an unanswered `asked` is always among the last records.
///
/// Reading that stays cheap because dsh writes the log as many small zstd
/// frames — one flush per append, each independently decodable — so only the
/// tail is read and decoding starts at a frame boundary (the 4-byte zstd magic;
/// in these files it never occurs inside a frame). The verdict is cached
/// against the file's size and mtime, so an unchanged log — which is exactly
/// the state while a prompt waits — is never decompressed twice.
final class DshApprovalLog {
    static let shared = DshApprovalLog()

    /// Covers the last records even when a single flush carried a large tool
    /// result; the frames are ~2 KB each in practice.
    private let tailBytes = 64 * 1024

    private struct Verdict {
        let size: Int
        let modified: TimeInterval
        let pending: Bool
    }
    private var cache: [String: Verdict] = [:]

    private init() {}

    /// True when the log's last `approval/asked` has no matching
    /// `approval/decided`. False whenever the log cannot be read — a missing
    /// `zstd` must never invent a red light.
    func hasPendingApproval(logPath: String) -> Bool {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: logPath),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return false }

        if let cached = cache[logPath], cached.size == size, cached.modified == modified {
            return cached.pending
        }
        let pending = scan(logPath: logPath, size: size)
        cache[logPath] = Verdict(size: size, modified: modified, pending: pending)
        return pending
    }

    // MARK: - Reading

    private func scan(logPath: String, size: Int) -> Bool {
        guard let zstd = ZstdBinary.path, size > 0,
              let handle = FileHandle(forReadingAtPath: logPath) else { return false }
        defer { try? handle.close() }

        let length = min(size, tailBytes)
        guard (try? handle.seek(toOffset: UInt64(size - length))) != nil,
              let tail = try? handle.read(upToCount: length), !tail.isEmpty,
              let text = decompress(tail, using: zstd) else { return false }
        return answerIsPending(in: text)
    }

    /// A frame boundary is a valid start for a decoder, so decoding from the
    /// first magic in the tail skips only the leading partial frame.
    private func decompress(_ slice: Data, using zstd: String) -> String? {
        guard let start = firstFrameMagic(in: slice) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-dc", "--quiet"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        input.fileHandleForWriting.write(slice.subdata(in: start..<slice.count))
        try? input.fileHandleForWriting.close()
        let decoded = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: decoded, encoding: .utf8)
    }

    private func firstFrameMagic(in data: Data) -> Int? {
        let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        let bytes = [UInt8](data)
        guard bytes.count >= magic.count else { return nil }
        for index in 0...(bytes.count - magic.count)
        where bytes[index] == magic[0] && bytes[index + 1] == magic[1]
            && bytes[index + 2] == magic[2] && bytes[index + 3] == magic[3] {
            return index
        }
        return nil
    }

    /// `asked` adds an id, `decided` removes it, so anything left unanswered is
    /// a prompt still on screen. A `decided` whose `asked` fell outside the
    /// tail is simply a no-op.
    private func answerIsPending(in text: String) -> Bool {
        var unanswered = Set<String>()
        for line in text.split(separator: "\n") where line.contains("\"approval/") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["data"] as? [String: Any],
                  let id = payload["id"] as? String else { continue }
            if type == "approval/asked" {
                unanswered.insert(id)
            } else if type == "approval/decided" {
                unanswered.remove(id)
            }
        }
        return !unanswered.isEmpty
    }
}
