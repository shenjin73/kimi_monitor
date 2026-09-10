import Foundation

/// DeepSeek account state for the 「套餐用量」 panel.
///
/// Two independent sources, because neither covers everything on its own:
///
/// * `GET https://api.deepseek.com/user/balance` — the documented API-key
///   endpoint, read with the same key dsh keeps in its credential store. Always
///   available, and the authoritative spendable balance.
/// * The open platform's dashboard API (`platform.deepseek.com`), which backs
///   the official usage page and is the only source of account lifetime spend
///   and account-wide token counts. It authenticates with the *web* `userToken`
///   (the `localStorage.userToken` value on that site) — API keys are rejected
///   there — so it is optional and configured from the tile itself.
///
/// With no `userToken` the tile degrades to local dsh session totals: exact
/// token counts from the projection checkpoints, and a clearly marked cost
/// estimate at the published list price.
final class DeepSeekMonitor: ObservableObject {
    static let shared = DeepSeekMonitor()

    @Published private(set) var balance: DeepSeekBalance?
    @Published private(set) var usage: DeepSeekUsage?
    @Published private(set) var balanceError: String?
    @Published private(set) var platformError: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var hasPlatformToken = false
    @Published private(set) var isRefreshing = false

    private let credentialsPath = NSHomeDirectory() + "/.dsh/.credentials.yaml"
    private let configDir = NSHomeDirectory() + "/.kimi-monitor"
    private let configPath = NSHomeDirectory() + "/.kimi-monitor/deepseek.json"
    /// dsh's own projection checkpoints; the local fallback sums their totals.
    private let projectionsDir = NSHomeDirectory() + "/.dsh/storages/session_projcache/sessions"

    private let balanceEndpoint = URL(string: "https://api.deepseek.com/user/balance")!
    private let platformBase = "https://platform.deepseek.com"

    /// The platform's `tz` parameter is seconds east of UTC.
    private static let platformTZ = 28_800
    /// The usage API truncates very wide ranges, so the cumulative query is
    /// issued in windows no wider than this.
    private let windowSeconds: TimeInterval = 31 * 24 * 3600
    /// Upper bound on those windows, so a very old account cannot fan out.
    private let maxWindows = 12
    /// Earliest day the platform keeps usage statistics for.
    private let statsSince = "2026-08-01"

    /// deepseek-flash list price in CNY per 1M tokens, off-peak (peak is
    /// double). Snapshot 2026-09-10, only used to estimate spend when no
    /// platform token is configured.
    /// https://api-docs.deepseek.com/zh-cn/quick_start/pricing
    private enum Price {
        static let cacheMiss = 1.0
        static let cacheHit = 0.02
        static let output = 4.0
    }

    private var timer: Timer?
    private var refreshing = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        Task { await self.refresh() }
        // Balance and spend move slowly; a slow poll plus manual refresh is enough.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    // MARK: - Platform token configuration
    //
    // ~/.kimi-monitor/deepseek.json, mode 0600. Deliberately *not* dsh's
    // credentials file: that one is dsh's own managed store and the app must
    // not rewrite it.

    private struct Config: Codable {
        var platformToken: String?
    }

    private func loadConfig() -> Config {
        guard let data = FileManager.default.contents(atPath: configPath),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return config
    }

    /// The configured web token: an explicit environment override first, then
    /// whatever the tile's input field last saved.
    private func platformToken() -> String? {
        let env = ProcessInfo.processInfo.environment["DEEPSEEK_PLATFORM_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty { return env }
        let stored = loadConfig().platformToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (stored?.isEmpty ?? true) ? nil : stored
    }

    /// Persists (or, with an empty string, clears) the platform token.
    @MainActor
    func savePlatformToken(_ raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = loadConfig()
        config.platformToken = token.isEmpty ? nil : token
        writeConfig(config)
        platformError = nil
        hasPlatformToken = platformToken() != nil
    }

    private func writeConfig(_ config: Config) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(config) else { return }
        // Atomic write-back via POSIX rename(2): FileManager.moveItem refuses to
        // replace an existing destination.
        let tmp = configPath + ".tmp-monitor"
        guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
        if rename(tmp, configPath) != 0 { try? fm.removeItem(atPath: tmp) }
    }

    // MARK: - Credentials (API key, shared with dsh)

    /// Pulls `DEEPSEEK_API_KEY` out of the `refs:` block. The file is a small
    /// hand-managed YAML document, so a targeted line scan avoids a YAML
    /// dependency and cannot be confused by the `records:` section below.
    private func apiKey() throws -> String {
        if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !env.isEmpty {
            return env
        }
        guard let text = try? String(contentsOfFile: credentialsPath, encoding: .utf8) else {
            throw PlatformError(message: "没有找到 \(credentialsPath)")
        }
        var inRefs = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let indented = rawLine.first.map { $0 == " " || $0 == "\t" } ?? false
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
            if !indented {
                // A top-level key ends the `refs:` block.
                inRefs = (key == "refs")
                continue
            }
            guard inRefs, key == "DEEPSEEK_API_KEY" else { continue }
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if value.hasPrefix("env:") {
                let name = String(value.dropFirst(4))
                guard let indirect = ProcessInfo.processInfo.environment[name], !indirect.isEmpty else {
                    throw PlatformError(message: "环境变量 \(name) 为空")
                }
                return indirect
            }
            guard !value.isEmpty else { break }
            return value
        }
        throw PlatformError(message: "没有找到 DEEPSEEK_API_KEY（~/.dsh/.credentials.yaml）")
    }

    // MARK: - Refresh

    @MainActor
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        isRefreshing = true
        defer {
            refreshing = false
            isRefreshing = false
        }

        let token = platformToken()
        hasPlatformToken = token != nil

        // The balance always comes from the API-key endpoint: documented,
        // independent of the web token, and the platform round-trips are only
        // needed for spend and tokens.
        var info: DeepSeekBalance.Info?
        do {
            let fetched = try await fetchBalance(key: try apiKey())
            balance = fetched
            info = fetched.balance_infos?.first
            balanceError = nil
        } catch {
            balanceError = error.localizedDescription
        }

        if let token {
            do {
                usage = try await fetchPlatformUsage(token: token, apiKeyInfo: info)
                platformError = nil
            } catch {
                // Keep the tile useful rather than blanking it out.
                platformError = error.localizedDescription
                usage = await localUsage(info: info)
            }
        } else {
            platformError = nil
            usage = await localUsage(info: info)
        }

        lastUpdated = Date()
    }

    private func fetchBalance(key: String) async throws -> DeepSeekBalance {
        var request = URLRequest(url: balanceEndpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PlatformError(message: "查询余额失败 (HTTP \(code))")
        }
        return try JSONDecoder().decode(DeepSeekBalance.self, from: data)
    }

    // MARK: - Open platform

    private struct PlatformError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Browser-shaped headers. The platform sits behind a WAF that answers a
    /// request carrying the default `URLSession` user agent (or an `sk-` API
    /// key) with an HTML "Request Blocked" page instead of JSON.
    private func platformHeaders(token: String) -> [String: String] {
        [
            "authorization": "Bearer \(token)",
            "x-app-version": "1.0.0",
            "origin": platformBase,
            "referer": platformBase + "/usage",
            "accept": "application/json",
            "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        ]
    }

    private func platformGet<T: Decodable>(_ path: String, token: String, as type: T.Type) async throws -> T {
        guard let url = URL(string: platformBase + path) else {
            throw PlatformError(message: "非法的平台地址 \(path)")
        }
        var request = URLRequest(url: url)
        for (field, value) in platformHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PlatformError(message: "平台返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let envelope: PlatformEnvelope<T>
        do {
            envelope = try JSONDecoder().decode(PlatformEnvelope<T>.self, from: data)
        } catch {
            throw PlatformError(message: "平台返回了非 JSON 内容（可能被风控拦截）")
        }
        guard let code = envelope.code else {
            throw PlatformError(message: "平台返回缺少 code 字段")
        }
        guard code == 0 else {
            throw PlatformError(message: envelope.msg ?? "平台返回 code \(code)")
        }
        guard let body = envelope.data else {
            throw PlatformError(message: "平台返回 data 为空")
        }
        if let bizCode = body.biz_code, bizCode != 0 {
            throw PlatformError(message: body.biz_msg ?? "平台业务错误 \(bizCode)")
        }
        guard let payload = body.biz_data else {
            throw PlatformError(message: "平台返回 biz_data 为空")
        }
        return payload
    }

    /// Running totals over one amount payload.
    private struct UsageTotals {
        var input = 0        // prompt tokens billed at the cache-miss rate
        var output = 0
        var cacheRead = 0    // prompt tokens billed at the cache-hit rate
        var requests = 0

        mutating func merge(_ payload: DeepSeekAmountSeries) {
            for series in payload.series ?? [] {
                for bucket in series.buckets ?? [] {
                    guard let usage = bucket.usage else { continue }
                    input += Int(usage.cacheMissTokens?.value ?? 0)
                    output += Int(usage.responseTokens?.value ?? 0)
                    cacheRead += Int(usage.cacheHitTokens?.value ?? 0)
                    requests += Int(usage.requests?.value ?? 0)
                }
            }
        }
    }

    private var platformCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: Self.platformTZ) ?? .gmt
        return calendar
    }

    /// GMT+8 midnight of a `yyyy-MM-dd` day.
    private func platformDay(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return platformCalendar.date(from: components)
    }

    private func usagePath(_ kind: String, from: Date, to: Date) -> String {
        let start = Int(from.timeIntervalSince1970)
        let end = Int(to.timeIntervalSince1970)
        return "/api/v0/usage/by_api_key/\(kind)?start=\(start)&end=\(end)&tz=\(Self.platformTZ)"
    }

    /// Exact account numbers straight from the platform dashboard API.
    private func fetchPlatformUsage(token: String,
                                    apiKeyInfo: DeepSeekBalance.Info?) async throws -> DeepSeekUsage {
        let now = Date()
        let todayStart = platformCalendar.startOfDay(for: now)
        let todayEnd = platformCalendar.date(byAdding: .day, value: 1, to: todayStart) ?? now

        let summary = try await platformGet("/api/v0/users/get_user_summary",
                                            token: token, as: DeepSeekUserSummary.self)

        let currency = apiKeyInfo?.currency
            ?? summary.normal_wallets?.first?.currency
            ?? summary.bonus_wallets?.first?.currency
            ?? "CNY"

        let todayAmount = try await platformGet(usagePath("amount", from: todayStart, to: todayEnd),
                                                token: token, as: DeepSeekAmountSeries.self)
        let todayCost = try await platformGet(usagePath("cost", from: todayStart, to: todayEnd),
                                              token: token, as: DeepSeekCostSeries.self)

        var today = UsageTotals()
        today.merge(todayAmount)

        // The platform keeps usage statistics only from `statsSince`, and
        // truncates very wide ranges — walk the span in bounded windows.
        // Walking *backwards* from today means the window cap can only drop the
        // oldest months, never the most recent ones; `coveredSince` reports
        // what was actually summed.
        var cumulative = UsageTotals()
        var coveredSince = todayStart
        if let since = platformDay(statsSince) {
            var cursor = todayEnd
            var windows = 0
            while cursor > since, windows < maxWindows {
                let start = max(cursor.addingTimeInterval(-windowSeconds), since)
                let payload = try await platformGet(usagePath("amount", from: start, to: cursor),
                                                    token: token, as: DeepSeekAmountSeries.self)
                cumulative.merge(payload)
                cursor = start
                windows += 1
            }
            coveredSince = cursor
        }

        let walletTotal: Double? = {
            let normal = summary.normal_wallets?.first { $0.currency == currency }?.balance?.value
            let bonus = summary.bonus_wallets?.first { $0.currency == currency }?.balance?.value
            guard normal != nil || bonus != nil else { return nil }
            return (normal ?? 0) + (bonus ?? 0)
        }()
        let lifetimeCost = summary.total_costs?.first { $0.currency == currency }?.amount?.value
            ?? summary.total_costs?.first?.amount?.value
        let todaySpend = sumCost(todayCost, currency: currency)

        return DeepSeekUsage(
            source: .platform,
            currency: currency,
            symbol: currencySymbol(currency),
            // The API key endpoint is authoritative when it answered.
            balance: apiKeyInfo?.total ?? walletTotal,
            bonusBalance: apiKeyInfo?.granted
                ?? summary.bonus_wallets?.first { $0.currency == currency }?.balance?.value,
            totalCost: lifetimeCost,
            costIsEstimate: false,
            inputTokens: cumulative.input,
            outputTokens: cumulative.output,
            cacheReadTokens: cumulative.cacheRead,
            requests: cumulative.requests,
            todayTokens: today.input + today.output + today.cacheRead,
            todayCost: todaySpend,
            todayError: nil,
            sessionCount: nil,
            since: platformDayString(coveredSince),
            fetchedAt: now
        )
    }

    /// `yyyy-MM-dd` in the platform's own time zone.
    private func platformDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: Self.platformTZ)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private func sumCost(_ payload: DeepSeekCostSeries, currency: String) -> Double {
        var total = 0.0
        for group in payload.data ?? [] where (group.currency ?? currency) == currency {
            for series in group.series ?? [] {
                for bucket in series.buckets ?? [] {
                    total += bucket.cost?.value ?? 0
                }
            }
        }
        return total
    }

    // MARK: - Local fallback

    /// Sums every dsh projection checkpoint on this Mac. Lifetime token counts
    /// are exact; the money figure is an estimate at the published list price,
    /// and today's tokens come from the session logs (the checkpoints have no
    /// date buckets).
    private func localUsage(info: DeepSeekBalance.Info?) async -> DeepSeekUsage {
        var totals = UsageTotals()
        var sessions = 0
        let fm = FileManager.default
        let decoder = JSONDecoder()
        for name in (try? fm.contentsOfDirectory(atPath: projectionsDir)) ?? [] where name.hasSuffix(".json") {
            guard let data = fm.contents(atPath: projectionsDir + "/" + name),
                  let projection = try? decoder.decode(DshProjection.self, from: data),
                  let tokens = projection.totals else { continue }
            totals.input += Int(tokens.uncachedInputTokens ?? 0)
            totals.output += Int(tokens.outputTokens ?? 0)
            totals.cacheRead += Int(tokens.cacheReadTokens ?? 0)
            sessions += 1
        }

        let currency = info?.currency ?? "CNY"
        let estimate = (Double(totals.input) * Price.cacheMiss
            + Double(totals.cacheRead) * Price.cacheHit
            + Double(totals.output) * Price.output) / 1_000_000

        // Replaying the compressed session logs is too heavy for the main
        // thread, and `localUsage` being `async` is what keeps it off.
        let scanner = DshTokenLog.shared
        let today = scanner.tokens(on: Date())

        return DeepSeekUsage(
            source: .local,
            currency: currency,
            symbol: currencySymbol(currency),
            balance: info?.total,
            bonusBalance: info?.granted,
            totalCost: estimate,
            costIsEstimate: true,
            inputTokens: totals.input,
            outputTokens: totals.output,
            cacheReadTokens: totals.cacheRead,
            requests: nil,
            todayTokens: today,
            todayCost: nil,
            todayError: today == nil
                ? (scanner.isSupported ? "读取 dsh 会话日志失败"
                                       : "未找到 zstd 命令（brew install zstd）")
                : nil,
            sessionCount: sessions,
            since: nil,
            fetchedAt: Date()
        )
    }
}
