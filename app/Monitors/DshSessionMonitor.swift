import Darwin
import Foundation

/// Tracks DeepSeek Harness (dsh) sessions.
///
/// Two sources, because neither is complete on its own:
///
/// * `~/.dsh/status/*.json` — written by `hooks/dsh_report_status.py` through
///   dsh's Claude Code hook bridge. Exact event edges (`waiting_user` for
///   `ask_user_question`), but the bridge has no `SessionEnd` and no
///   heartbeat, so it cannot say whether the session is still alive.
/// * `~/.dsh/storages/session_projcache/sessions/*.json` — dsh's own
///   projection checkpoints: title, cwd, token totals, and the live
///   `sessionStats` row (`openStep` = model is generating, `pendingCalls` =
///   a tool is in flight).
///
/// Liveness comes from the kernel: dsh holds a `flock(2)` on
/// `<session>/session.lock` for the whole life of the session, and the lock
/// dies with the process — so a probe decides "alive" without any heartbeat.
final class DshSessionMonitor: ObservableObject {
    static let shared = DshSessionMonitor(home: NSHomeDirectory())

    struct Entry: Identifiable {
        var id: String { sessionId }
        let sessionId: String
        let title: String?
        let cwd: String?
        let effective: EffectiveStatus
        let updatedAt: Double?
        let event: String?
        let inputTokens: Int
        let outputTokens: Int
        let lastPromptAt: Double?
    }

    @Published private(set) var entries: [Entry] = []

    let statusDir: String
    let sessionsRoot: String
    let projectionDir: String

    /// `home` is injectable so the resolution rules can be exercised against
    /// fixture directories; the app always uses `NSHomeDirectory()`.
    init(home: String) {
        statusDir = home + "/.dsh/status"
        sessionsRoot = home + "/.dsh/sessions"
        projectionDir = home + "/.dsh/storages/session_projcache/sessions"
    }

    /// Nothing observed for this long *and* no lock held → dead; state removed.
    let staleAfter: TimeInterval = 150
    /// An idle session stays visible this long after its last real activity, so
    /// a harness process that keeps sessions loaded does not grow a tile per
    /// session ever opened.
    let idleRetention: TimeInterval = 10 * 60

    /// Last time each session was seen doing something, keyed by a fingerprint
    /// of the observed state (see `refresh`).
    private struct Activity {
        let fingerprint: String
        let at: Double
    }
    private var activity: [String: Activity] = [:]

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        let decoder = JSONDecoder()

        // ── Hook state (event edges) ────────────────────────────────
        var hooks: [String: (state: SessionState, mtime: Double)] = [:]
        for (name, mtime) in files(in: statusDir, fm: fm) where name.hasSuffix(".json") {
            guard let data = fm.contents(atPath: statusDir + "/" + name),
                  let state = try? decoder.decode(SessionState.self, from: data) else { continue }
            hooks[state.session_id] = (state, mtime)
        }

        // ── Projection checkpoints (title / cwd / tokens / live stats) ──
        var projections: [String: (projection: DshProjection, mtime: Double)] = [:]
        for (name, mtime) in files(in: projectionDir, fm: fm) where name.hasSuffix(".json") {
            guard let data = fm.contents(atPath: projectionDir + "/" + name),
                  let projection = try? decoder.decode(DshProjection.self, from: data) else { continue }
            projections[String(name.dropLast(5))] = (projection, mtime)
        }

        // ── Liveness: session id → lock/log paths, then probe the flock ──
        let files = sessionFiles(fm: fm)

        var result: [Entry] = []
        for id in Set(hooks.keys).union(projections.keys) {
            let hook = hooks[id]
            let projection = projections[id]?.projection
            let projectionMtime = projections[id]?.mtime
            let lockPath = files[id]?.lock

            let live = lockPath.map(lockHeld) ?? false
            let hookFresh = hook.map { now - $0.mtime < staleAfter } ?? false
            let projectionFresh = projectionMtime.map { now - $0 < staleAfter } ?? false
            guard live || hookFresh || projectionFresh else {
                // Process gone (lock released) and nothing recent: reap our state.
                if let hook, now - hook.mtime > staleAfter {
                    try? fm.removeItem(atPath: statusDir + "/" + id + ".json")
                }
                continue
            }

            // A tool call in flight is work — unless dsh is genuinely blocked on
            // an approval prompt, which only the session log records. The lookup
            // is cached against the log's size+mtime, so it costs nothing while
            // the prompt sits there. (An `ask_user_question` arrives through the
            // hook instead and is handled inside `effective`.)
            let logPath = files[id]?.log ?? ""
            let approvalPending = projection?.stats?.openStep == nil
                && !(projection?.stats?.pendingCalls ?? [:]).isEmpty
                && !logPath.isEmpty
                && DshApprovalLog.shared.hasPendingApproval(logPath: logPath)

            let (status, stamp) = effective(hook: hook?.state, projection: projection,
                                            approvalPending: approvalPending, now: now)

            // An idle session is shown for `idleRetention` after its last real
            // activity, then dropped. The activity clock must not come from the
            // checkpoint's mtime: dsh rewrites it periodically even when nothing
            // happened. Instead it is the semantic stamp (prompt / step start /
            // tool call / hook event), refreshed to "now" whenever the observed
            // state actually changes — so a long turn that just ended still gets
            // its full retention window.
            let baseline = max(stamp ?? 0, projection?.lastPromptAt ?? 0,
                               max(hook?.state.updated_at ?? 0, hook?.state.heartbeat_at ?? 0))
            let fingerprint = "\(status.rawValue)|\(stamp ?? 0)"
            if let previous = activity[id] {
                // An observed change is activity *now*; an unchanged state keeps
                // its original clock.
                if previous.fingerprint != fingerprint {
                    activity[id] = Activity(fingerprint: fingerprint, at: now)
                }
            } else {
                // First sighting: trust the recorded stamp, so a session left
                // idle long ago disappears immediately instead of lingering.
                activity[id] = Activity(fingerprint: fingerprint, at: baseline)
            }
            if status == .idle, now - (activity[id]?.at ?? baseline) > idleRetention { continue }

            result.append(Entry(
                sessionId: id,
                title: projection?.title.flatMap { $0.isEmpty ? nil : $0 } ?? hook?.state.session_title,
                cwd: projection?.cwd ?? hook?.state.cwd,
                effective: status,
                updatedAt: stamp,
                event: hook?.state.event,
                inputTokens: projection?.totals?.input ?? 0,
                outputTokens: projection?.totals?.output ?? 0,
                lastPromptAt: projection?.lastPromptAt
            ))
        }

        result.sort {
            if $0.effective.rank != $1.effective.rank { return $0.effective.rank < $1.effective.rank }
            return ($0.updatedAt ?? $0.lastPromptAt ?? 0) > ($1.updatedAt ?? $1.lastPromptAt ?? 0)
        }
        // Forget sessions whose files are gone, so the map stays bounded.
        let known = Set(hooks.keys).union(projections.keys)
        activity = activity.filter { known.contains($0.key) }
        publish(result)
    }

    var aggregate: EffectiveStatus? {
        entries.map { $0.effective }.min(by: { $0.rank < $1.rank })
    }

    // MARK: - Status resolution

    /// The projection's live rows are the most trustworthy signal; the hook
    /// refines them (exact `waiting_user`) and covers the first seconds before
    /// a throttled checkpoint lands.
    private func effective(hook: SessionState?,
                           projection: DshProjection?,
                           approvalPending: Bool,
                           now: Double) -> (EffectiveStatus, Double?) {
        let hookStatus = hook?.status.flatMap(EffectiveStatus.init(rawValue:))
        let hookStamp = hook.map { max($0.updated_at ?? 0, $0.heartbeat_at ?? 0) }
        let hookFresh = hookStamp.map { now - $0 < staleAfter } ?? false

        // 1. An explicit hook "waiting for the human" while no step is generating.
        if hookFresh, hookStatus == .waitingUser, projection?.stats?.openStep == nil {
            return (.waitingUser, hookStamp)
        }
        // 2. Model is generating right now.
        if let open = projection?.stats?.openStep {
            return (.working, open.startTime.map { $0 / 1000 } ?? hookStamp)
        }
        // 3. A tool call in flight — that is work, however long it takes.
        //
        //    Do *not* guess "waiting for the user" from the elapsed time: dsh
        //    gives no signal that separates an approval prompt from a slow
        //    tool. The bridge fires PreToolUse before the approval ask, so both
        //    leave the hook saying "working" and the checkpoint showing one
        //    pending call with no open step. A build, a test run or a subagent
        //    spends minutes in exactly that state, so the old "pending > 12 s
        //    means blocked on the human" rule mislabelled every slow tool. The
        //    one genuine exception is an approval prompt, which the session log
        //    does record — `approvalPending` is that answer, read from the log
        //    by `DshApprovalLog`, and a real question still arrives through
        //    rule 1 with a `waiting_user` hook status.
        if let pending = projection?.stats?.pendingCalls, !pending.isEmpty {
            let oldest = pending.values.min() ?? 0
            return (approvalPending ? .waitingUser : .working, oldest / 1000)
        }
        // 4. Fall back to the last recorded hook edge.
        if hookFresh, let hookStatus { return (hookStatus, hookStamp) }
        // 5. Nothing is running.
        return (.idle, projection?.lastPromptAt ?? hookStamp)
    }

    // MARK: - Filesystem helpers

    private func files(in dir: String, fm: FileManager) -> [(String, Double)] {
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names.map { name in
            let attrs = try? fm.attributesOfItem(atPath: dir + "/" + name)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return (name, mtime)
        }
    }

    /// dsh lays sessions out as ~/.dsh/sessions/<enc cwd>/<session id>/, with the
    /// kernel lock and the session log side by side.
    private func sessionFiles(fm: FileManager) -> [String: (lock: String, log: String)] {
        guard let cwds = try? fm.contentsOfDirectory(atPath: sessionsRoot) else { return [:] }
        var result: [String: (lock: String, log: String)] = [:]
        for cwd in cwds {
            let dir = sessionsRoot + "/" + cwd
            guard let sessions = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for session in sessions {
                let sessionDir = dir + "/" + session
                let lock = sessionDir + "/session.lock"
                guard fm.fileExists(atPath: lock) else { continue }
                // v3 log when present, else the legacy one.
                let modern = sessionDir + "/session.v3.jsonl.zstd"
                let legacy = sessionDir + "/session.jsonl.zstd"
                let log = fm.fileExists(atPath: modern) ? modern
                    : (fm.fileExists(atPath: legacy) ? legacy : "")
                result[session] = (lock, log)
            }
        }
        return result
    }

    /// True while some process holds the exclusive flock. The probe only reads,
    /// and immediately releases anything it managed to take.
    private func lockHeld(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    private func publish(_ entries: [Entry]) {
        let changed = entries.count != self.entries.count
            || zip(entries, self.entries).contains {
                $0.id != $1.id
                    || $0.effective != $1.effective
                    || $0.updatedAt != $1.updatedAt
                    || $0.title != $1.title
                    || $0.inputTokens != $1.inputTokens
                    || $0.outputTokens != $1.outputTokens
            }
        if changed { self.entries = entries }
    }
}
