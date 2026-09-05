import Foundation

/// Polls ~/.kimi-code/status/*.json (written by the Kimi CLI hook).
final class SessionMonitor: ObservableObject {
    static let shared = SessionMonitor()

    struct Entry: Identifiable {
        var id: String { state.session_id }
        let state: SessionState
        let effective: EffectiveStatus
    }

    @Published private(set) var entries: [Entry] = []

    let statusDir = NSHomeDirectory() + "/.kimi-code/status"
    /// No event/heartbeat for this long → session considered dead, hidden and removed.
    let staleAfter: TimeInterval = 150

    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: statusDir) else {
            publish([])
            return
        }
        let now = Date().timeIntervalSince1970
        let decoder = JSONDecoder()
        var result: [Entry] = []
        for name in files where name.hasSuffix(".json") {
            guard let data = fm.contents(atPath: statusDir + "/" + name),
                  let state = try? decoder.decode(SessionState.self, from: data) else { continue }
            let lastSeen = max(state.heartbeat_at ?? 0, state.updated_at ?? 0)
            let effective = EffectiveStatus(rawValue: state.status ?? "idle") ?? .idle
            // Dead sessions (no heartbeat): drop from the list and clean up the file.
            if now - lastSeen > staleAfter {
                try? fm.removeItem(atPath: statusDir + "/" + name)
                continue
            }
            result.append(Entry(state: state, effective: effective))
        }
        result.sort {
            if $0.effective.rank != $1.effective.rank { return $0.effective.rank < $1.effective.rank }
            return ($0.state.updated_at ?? 0) > ($1.state.updated_at ?? 0)
        }
        publish(result)
    }

    var aggregate: EffectiveStatus? {
        entries.map { $0.effective }.min(by: { $0.rank < $1.rank })
    }

    private func publish(_ entries: [Entry]) {
        // Avoid view churn when nothing changed.
        let changed = entries.count != self.entries.count
            || zip(entries, self.entries).contains {
                $0.id != $1.id
                    || $0.effective != $1.effective
                    || $0.state.event != $1.state.event
                    || $0.state.updated_at != $1.state.updated_at
                    || $0.state.session_title != $1.state.session_title
            }
        if changed { self.entries = entries }
    }
}
