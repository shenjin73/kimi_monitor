import Foundation

/// Fetches Kimi Code plan usage from the cloud API.
///
/// Credentials live in ~/.kimi-code/credentials/kimi-code.json (shared with the
/// CLI). The access token expires every ~15 min; when expired we refresh it via
/// {oauthHost}/api/oauth/token and atomically write the rotated tokens back.
/// If the CLI refreshes concurrently our request may fail once — the next poll
/// re-reads the file and recovers.
final class QuotaMonitor: ObservableObject {
    static let shared = QuotaMonitor()

    @Published private(set) var usage: UsageResponse?
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?

    private let credentialsPath = NSHomeDirectory() + "/.kimi-code/credentials/kimi-code.json"
    private let regionPath = NSHomeDirectory() + "/.kimi-code/region"
    private let clientId = "17e5f671-d194-4dfb-9706-5516cb48c098"

    private var timer: Timer?
    private var refreshing = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        Task { await self.refresh() }
        // Quota changes slowly; poll once a minute.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    private var isCNRegion: Bool {
        let region = (try? String(contentsOfFile: regionPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "cn"
        return region != "global"
    }

    private var oauthHost: String { isCNRegion ? "https://auth.kimi.com" : "https://auth.kimi.ai" }
    private var apiBase: String { isCNRegion ? "https://api.kimi.com/coding/v1" : "https://api.kimi.ai/coding/v1" }

    // MARK: - Credentials

    private struct Credentials: Codable {
        var access_token: String
        var refresh_token: String?
        var expires_at: Double?
        var token_type: String?
        var scope: String?
    }

    private func loadCredentials() throws -> Credentials {
        let data = try Data(contentsOf: URL(fileURLWithPath: credentialsPath))
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    /// Returns a valid access token, refreshing via the refresh token if needed.
    private func validAccessToken() async throws -> String {
        var creds = try loadCredentials()
        let fresh = (creds.expires_at ?? 0) > Date().timeIntervalSince1970 + 30
        if fresh { return creds.access_token }

        guard let refreshToken = creds.refresh_token else {
            throw NSError(domain: "QuotaMonitor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有 refresh_token，请先在 CLI 中 /login"])
        }
        var comps = URLComponents(string: oauthHost + "/api/oauth/token")!
        comps.queryItems = nil
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "QuotaMonitor", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "刷新 token 失败 (HTTP \(code))"])
        }
        struct RefreshResponse: Codable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
            let token_type: String?
            let scope: String?
        }
        let refreshed = try JSONDecoder().decode(RefreshResponse.self, from: data)

        creds.access_token = refreshed.access_token
        if let rt = refreshed.refresh_token { creds.refresh_token = rt }
        if let ei = refreshed.expires_in { creds.expires_at = Date().timeIntervalSince1970 + ei }

        // Atomic write-back (tmp + rename) so the CLI never sees a partial file.
        let out = try JSONEncoder().encode(creds)
        let tmp = credentialsPath + ".tmp-monitor"
        try out.write(to: URL(fileURLWithPath: tmp))
        try FileManager.default.moveItem(atPath: tmp, toPath: credentialsPath)
        return creds.access_token
    }

    // MARK: - Refresh

    @MainActor
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let token = try await validAccessToken()
            var req = URLRequest(url: URL(string: apiBase + "/usages")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw NSError(domain: "QuotaMonitor", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "查询用量失败 (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1))"])
            }
            self.usage = try JSONDecoder().decode(UsageResponse.self, from: data)
            self.lastError = nil
            self.lastUpdated = Date()
        } catch {
            self.lastError = error.localizedDescription
        }
    }
}
