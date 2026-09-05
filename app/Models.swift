import Foundation

// MARK: - Session state (written by ~/.kimi-code/hooks/report_status.py)

struct SessionState: Codable {
    let session_id: String
    let session_title: String?
    let cwd: String?
    let status: String?
    let event: String?
    let updated_at: Double?
    let heartbeat_at: Double?
    let uptime_ms: Double?
}

enum EffectiveStatus: String {
    case working
    case waitingUser = "waiting_user"
    case idle
    case offline

    var dot: String {
        switch self {
        case .working: return "🔵"
        case .waitingUser: return "🟠"
        case .idle: return "🟢"
        case .offline: return "⚪"
        }
    }

    var label: String {
        switch self {
        case .working: return "工作中"
        case .waitingUser: return "等待用户"
        case .idle: return "空闲"
        case .offline: return "离线"
        }
    }

    /// Lower rank = needs more attention.
    var rank: Int {
        switch self {
        case .waitingUser: return 0
        case .working: return 1
        case .idle: return 2
        case .offline: return 3
        }
    }
}

// MARK: - Quota API (GET {apiBase}/usages)

struct UsageResponse: Codable {
    struct Quota: Codable {
        let limit: String?
        let used: String?
        let remaining: String?
        let resetTime: String?

        var usedFraction: Double {
            guard let l = Double(limit ?? ""), l > 0, let u = Double(used ?? "") else { return 0 }
            return min(max(u / l, 0), 1)
        }
    }

    struct LimitEntry: Codable {
        struct Window: Codable {
            let duration: Int?
            let timeUnit: String?
        }
        let window: Window?
        let detail: Quota?

        var windowLabel: String {
            guard let d = window?.duration else { return "限额" }
            switch window?.timeUnit {
            case "TIME_UNIT_MINUTE":
                return d % 60 == 0 ? "\(d / 60) 小时窗口" : "\(d) 分钟窗口"
            case "TIME_UNIT_HOUR": return "\(d) 小时窗口"
            case "TIME_UNIT_DAY": return "\(d) 天窗口"
            default: return "\(d) 单位窗口"
            }
        }
    }

    struct User: Codable {
        struct Membership: Codable { let level: String? }
        let region: String?
        let membership: Membership?
    }

    let user: User?
    let usage: Quota?          // weekly quota
    let limits: [LimitEntry]?  // rolling windows (e.g. 5-hour)
}

// MARK: - Shared helpers

func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func parseISO8601(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func relativeTime(_ date: Date) -> String {
    let seconds = Int(date.timeIntervalSinceNow)
    if seconds <= 0 { return "现在" }
    let h = seconds / 3600, m = (seconds % 3600) / 60
    if h >= 24 { return "\(h / 24) 天 \(h % 24) 小时后" }
    if h > 0 { return "\(h) 小时 \(m) 分后" }
    return "\(max(m, 1)) 分钟后"
}
