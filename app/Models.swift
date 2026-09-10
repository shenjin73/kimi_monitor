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

// MARK: - DSH session projection cache
// (~/.dsh/storages/session_projcache/sessions/<session_id>.json)

/// The subset of a dsh projection record the monitor reads. Every row is
/// `{ver, seq, val}` and rows appear only once a plugin has written them, so
/// everything is optional.
struct DshProjection: Codable {
    struct Identity: Codable {
        let cwd: String?
        let createdAt: Double?
    }

    struct Row<T: Codable>: Codable {
        let val: T?
        let seq: Int?
    }

    struct TokenTotals: Codable {
        let uncachedInputTokens: Double?
        let outputTokens: Double?
        let cacheReadTokens: Double?
        let cacheWriteTokens: Double?

        /// Everything the model read: fresh prompt tokens + cache hits.
        var input: Int { Int((uncachedInputTokens ?? 0) + (cacheReadTokens ?? 0)) }
        var output: Int { Int(outputTokens ?? 0) }
    }

    struct Stats: Codable {
        struct OpenStep: Codable {
            let turn: Int?
            let step: Int?
            let startTime: Double?   // ms since epoch
        }
        let openStep: OpenStep?
        /// callId → dispatch time (ms since epoch) for in-flight tool calls.
        let pendingCalls: [String: Double]?
        let turns: Int?
        let steps: Int?
    }

    struct TokenUsage: Codable {
        let totals: TokenTotals?
    }

    struct ListMetadata: Codable {
        let blank: Bool?
        let lastPromptAt: Double?    // ms since epoch
    }

    struct Rows: Codable {
        let title: Row<String>?
        let tokenUsage: Row<TokenUsage>?
        let sessionStats: Row<Stats>?
        let sessionListMetadata: Row<ListMetadata>?
    }

    struct Record: Codable {
        let identity: Identity?
        let rows: Rows?
    }

    let record: Record?

    var title: String? { record?.rows?.title?.val }
    var cwd: String? { record?.identity?.cwd }
    var createdAt: Double? { record?.identity?.createdAt.map { $0 / 1000 } }
    var totals: TokenTotals? { record?.rows?.tokenUsage?.val?.totals }
    var stats: Stats? { record?.rows?.sessionStats?.val }
    var lastPromptAt: Double? { record?.rows?.sessionListMetadata?.val?.lastPromptAt.map { $0 / 1000 } }
}

// MARK: - DeepSeek balance API (GET https://api.deepseek.com/user/balance)

struct DeepSeekBalance: Codable {
    struct Info: Codable {
        let currency: String?
        let total_balance: String?
        let granted_balance: String?
        let topped_up_balance: String?

        var total: Double? { Double(total_balance ?? "") }
        var granted: Double? { Double(granted_balance ?? "") }
        var toppedUp: Double? { Double(topped_up_balance ?? "") }

        var symbol: String { currencySymbol(currency) }
    }

    let is_available: Bool?
    let balance_infos: [Info]?
}

// MARK: - DeepSeek open-platform dashboard API (platform.deepseek.com)
//
// These private endpoints back the official usage page at
// https://platform.deepseek.com/usage and are the only source of account
// lifetime spend and account-wide token counts. They authenticate with the
// *web* `userToken` (the `localStorage.userToken` value on that site), never
// with an API key: `sk-…` keys answer `40003 Authorization Failed`.

/// Decodes a JSON number, a numeric string, or nothing at all — the platform
/// is inconsistent about whether money arrives as `"1.23"` or `1.23`, and one
/// odd field must not fail the whole payload.
struct FlexibleDouble: Decodable {
    let value: Double?

    init(_ value: Double?) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Double(text)
        } else {
            value = nil
        }
    }
}

/// `{code, msg, data: {biz_code, biz_msg, biz_data}}` — the envelope shared by
/// every platform endpoint. Both layers must be zero for the payload to count.
struct PlatformEnvelope<Payload: Decodable>: Decodable {
    struct Body<Value: Decodable>: Decodable {
        let biz_code: Int?
        let biz_msg: String?
        let biz_data: Value?
    }

    let code: Int?
    let msg: String?
    let data: Body<Payload>?
}

/// GET /api/v0/users/get_user_summary
struct DeepSeekUserSummary: Decodable {
    struct Wallet: Decodable {
        let currency: String?
        let balance: FlexibleDouble?
    }

    struct Cost: Decodable {
        let currency: String?
        /// Account lifetime spend.
        let amount: FlexibleDouble?
    }

    let normal_wallets: [Wallet]?   // topped-up
    let bonus_wallets: [Wallet]?    // granted
    let total_costs: [Cost]?
}

/// GET /api/v0/usage/by_api_key/amount
struct DeepSeekAmountSeries: Decodable {    struct Usage: Decodable {
        let responseTokens: FlexibleDouble?
        let requests: FlexibleDouble?
        let cacheHitTokens: FlexibleDouble?
        let cacheMissTokens: FlexibleDouble?

        enum CodingKeys: String, CodingKey {
            case responseTokens = "RESPONSE_TOKEN"
            case requests = "REQUEST"
            case cacheHitTokens = "PROMPT_CACHE_HIT_TOKEN"
            case cacheMissTokens = "PROMPT_CACHE_MISS_TOKEN"
        }
    }

    struct Bucket: Decodable {
        let usage: Usage?
    }

    struct Series: Decodable {
        let model: String?
        let buckets: [Bucket]?
    }

    let series: [Series]?
}

/// GET /api/v0/usage/by_api_key/cost
struct DeepSeekCostSeries: Decodable {
    struct Bucket: Decodable {
        let cost: FlexibleDouble?
    }

    struct Series: Decodable {
        let model: String?
        let buckets: [Bucket]?
    }

    struct CurrencyGroup: Decodable {
        let currency: String?
        let series: [Series]?
    }

    let data: [CurrencyGroup]?
}

/// Everything the DeepSeek tile renders.
///
/// The balance always comes from the documented API-key endpoint. The cost and
/// token numbers come from the open platform when a web token is configured;
/// otherwise the tile falls back to local dsh session totals, which are exact
/// for tokens but only *estimate* money at the published list price.
struct DeepSeekUsage: Equatable {
    enum Source: Equatable {
        case platform
        case local
    }

    var source: Source
    var currency: String
    var symbol: String

    /// Spendable balance (granted + topped up).
    var balance: Double?
    var bonusBalance: Double?

    /// Account spend. `costIsEstimate` marks the locally derived figure.
    var totalCost: Double?
    var costIsEstimate: Bool

    var inputTokens: Int        // prompt tokens billed at the cache-miss rate
    var outputTokens: Int
    var cacheReadTokens: Int    // prompt tokens billed at the cache-hit rate

    var requests: Int?
    var todayTokens: Int?
    var todayCost: Double?
    /// Set when `todayTokens` could not be computed, so the tile can explain
    /// the gap instead of silently omitting the row.
    var todayError: String?
    /// Local fallback only: how many dsh sessions were aggregated.
    var sessionCount: Int?
    /// First day covered by the token statistics, e.g. "2026-08-01".
    var since: String?
    var fetchedAt: Date

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens }
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

        /// Tile title for this window, named after the tool it belongs to so
        /// the 套餐用量 row reads unambiguously next to the DeepSeek tile.
        var windowLabel: String {
            guard let d = window?.duration else { return "Kimi限额" }
            switch window?.timeUnit {
            case "TIME_UNIT_MINUTE":
                return "Kimi" + (d % 60 == 0 ? "\(d / 60)小时窗口" : "\(d)分钟窗口")
            case "TIME_UNIT_HOUR": return "Kimi\(d)小时窗口"
            case "TIME_UNIT_DAY": return "Kimi\(d)天窗口"
            default: return "Kimi\(d)单位窗口"
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

func currencySymbol(_ code: String?) -> String {
    switch code {
    case "CNY": return "¥"
    case "USD": return "$"
    default: return ""
    }
}

/// 1234567 → "1.2M", 12345 → "12.3K", 999 → "999".
func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}

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
