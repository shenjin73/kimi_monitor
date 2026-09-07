import Foundation

/// Scans ~/.claude/projects/**/*.jsonl and tallies input/output tokens
/// for today and the past 7 days. Refreshes every 60 s.
final class ClaudeTokenMonitor: ObservableObject {
    static let shared = ClaudeTokenMonitor()

    struct Tally {
        var input: Int = 0
        var output: Int = 0
    }

    @Published private(set) var today = Tally()
    @Published private(set) var week  = Tally()

    private let projectsDir = NSHomeDirectory() + "/.claude/projects"
    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.scan()
            DispatchQueue.main.async {
                self.today = result.today
                self.week  = result.week
            }
        }
    }

    // MARK: - Scanning

    private struct ScanResult { var today = Tally(); var week = Tally() }

    private func scan() -> ScanResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: projectsDir) else { return ScanResult() }

        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOf7Days = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        var result = ScanResult()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        while let path = enumerator.nextObject() as? String {
            guard path.hasSuffix(".jsonl") else { continue }
            let full = projectsDir + "/" + path
            guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let msg = obj["message"] as? [String: Any],
                      msg["role"] as? String == "assistant",
                      let usage = msg["usage"] as? [String: Any],
                      let tsStr = obj["timestamp"] as? String,
                      let ts = iso.date(from: tsStr) else { continue }

                let inp = usage["input_tokens"] as? Int ?? 0
                let out = usage["output_tokens"] as? Int ?? 0

                if ts >= startOf7Days {
                    result.week.input  += inp
                    result.week.output += out
                }
                if ts >= startOfToday {
                    result.today.input  += inp
                    result.today.output += out
                }
            }
        }
        return result
    }
}
