import Foundation

/// Totals dsh's provider-reported token usage for one local day, by replaying
/// the session logs.
///
/// The projection cache only carries each session's *lifetime* totals — it has
/// no date buckets — so "today" cannot be derived from it. The session logs
/// (`~/.dsh/sessions/<cwd>/<id>/session.v3.jsonl.zstd`) do record every
/// assistant message with a timestamp and its full usage, but they are zstd and
/// neither Foundation nor Apple's Compression framework decodes that. The files
/// are therefore piped through a `zstd` executable when one can be located;
/// when none can, the caller is told the number is unavailable instead of being
/// handed a guess.
final class DshTokenLog {
    static let shared = DshTokenLog()

    private let sessionsRoot = NSHomeDirectory() + "/.dsh/sessions"

    /// Checked before `$PATH`: an app launched from Finder, or as a login item,
    /// inherits launchd's minimal PATH, which rarely contains Homebrew or conda.
    private let zstdCandidates = [
        "/opt/homebrew/bin/zstd",
        "/usr/local/bin/zstd",
        "/opt/miniconda3/bin/zstd",
        "/opt/anaconda3/bin/zstd",
        "/usr/bin/zstd",
    ]

    private init() {}

    // MARK: - Availability

    private(set) lazy var zstdPath: String? = {
        let fm = FileManager.default
        for path in zstdCandidates where fm.isExecutableFile(atPath: path) { return path }
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in searchPath.split(separator: ":") {
            let path = String(directory) + "/zstd"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }()

    /// False when no `zstd` executable exists, so the UI can explain itself.
    var isSupported: Bool { zstdPath != nil }

    // MARK: - Scanning

    /// Provider-reported tokens recorded on the local calendar day containing
    /// `day`, summed over every dsh session. `nil` when the logs cannot be read.
    func tokens(on day: Date, calendar: Calendar = .current) -> Int? {
        guard let zstd = zstdPath else { return nil }
        let files = logFiles()
        guard !files.isEmpty else { return nil }

        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }

        guard let output = decompress(zstd, files) else { return nil }
        return sum(output,
                   from: dayStart.timeIntervalSince1970 * 1000,
                   to: dayEnd.timeIntervalSince1970 * 1000)
    }

    /// One `zstd -dc` for all logs at once — a process per file would be far
    /// slower than the ~0.3 s this takes.
    private func decompress(_ zstd: String, _ files: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-dc", "--quiet"] + files
        let pipe = Pipe()
        process.standardOutput = pipe
        // The live session's log is appended while it runs, so a truncated
        // trailing frame is normal: keep whatever decoded, ignore stderr.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data.isEmpty ? nil : data
    }

    /// Cheap byte pre-filter first, then a real decode only for matching lines:
    /// the logs are dominated by tool results nobody needs to parse.
    private func sum(_ data: Data, from lower: Double, to upper: Double) -> Int {
        let marker = Data("\"assistant/message\"".utf8)
        var total = 0
        for line in data.split(separator: 0x0A) where line.range(of: marker) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let time = object["time"] as? Double, time >= lower, time < upper,
                  let payload = object["data"] as? [String: Any],
                  let usage = payload["usage"] as? [String: Any] else { continue }
            total += (usage["inputTokens"] as? Int ?? 0)
                + (usage["outputTokens"] as? Int ?? 0)
                + (usage["cacheReadTokens"] as? Int ?? 0)
        }
        return total
    }

    /// `session.v3.jsonl.zstd` when it exists, else the legacy
    /// `session.jsonl.zstd`. Never both: they hold the same records, so summing
    /// them would double count.
    private func logFiles() -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        for cwd in (try? fm.contentsOfDirectory(atPath: sessionsRoot)) ?? [] {
            let cwdDirectory = sessionsRoot + "/" + cwd
            for session in (try? fm.contentsOfDirectory(atPath: cwdDirectory)) ?? [] {
                let directory = cwdDirectory + "/" + session
                let modern = directory + "/session.v3.jsonl.zstd"
                let legacy = directory + "/session.jsonl.zstd"
                if fm.fileExists(atPath: modern) { found.append(modern) }
                else if fm.fileExists(atPath: legacy) { found.append(legacy) }
            }
        }
        return found.sorted()
    }
}
