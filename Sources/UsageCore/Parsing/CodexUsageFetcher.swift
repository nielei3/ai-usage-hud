import Foundation

public struct ApiRateLimitWindow: Sendable, Equatable {
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

/// Fetches Codex credit usage directly from the ChatGPT backend API.
/// Endpoint: GET https://chatgpt.com/backend-api/wham/usage
/// Auth: Bearer token + ChatGPT-Account-Id header from ~/.codex/auth.json
public struct CodexUsageFetcher: Sendable {
    public struct CreditData: Sendable, Equatable {
        public var used: Double?
        public var limit: Double?
        public var remaining: Double?
        public var usedPercent: Double?
        public var primaryWindow: ApiRateLimitWindow?
        public var secondaryWindow: ApiRateLimitWindow?

        public init(
            used: Double? = nil, limit: Double? = nil, remaining: Double? = nil,
            usedPercent: Double? = nil,
            primaryWindow: ApiRateLimitWindow? = nil,
            secondaryWindow: ApiRateLimitWindow? = nil
        ) {
            self.used = used
            self.limit = limit
            self.remaining = remaining
            self.usedPercent = usedPercent
            self.primaryWindow = primaryWindow
            self.secondaryWindow = secondaryWindow
        }
    }

    private static var cachedData: CreditData?
    private static var cachedAt: Date?
    private static let cacheTTL: TimeInterval = 120
    private static let lock = NSLock()

    private static func readAuth() -> (token: String, accountId: String)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authURL = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              let accountId = tokens["account_id"] as? String
        else { return nil }
        return (token, accountId)
    }

    private static var diskCacheURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/plugins/oh-my-claudecode/.usage-hud-codex-cache.json")
    }

    /// Pure JSON parsing of the wham/usage response — testable without network.
    public static func parseUsageResponse(_ data: Data) -> CreditData? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["error"] == nil
        else { return nil }

        let spendControl = obj["spend_control"] as? [String: Any]
        let individualLimit = spendControl?["individual_limit"] as? [String: Any]

        let used = (individualLimit?["used"] as? String).flatMap(Double.init)
        let limit = (individualLimit?["limit"] as? String).flatMap(Double.init)
        let remaining = (individualLimit?["remaining"] as? String).flatMap(Double.init)
        let usedPercent: Double? = {
            guard let u = used, let l = limit, l > 0 else { return nil }
            return min(max(u / l * 100, 0), 100)
        }()

        let rateLimit = obj["rate_limit"] as? [String: Any]
        let primaryWindow = parseApiWindow(rateLimit?["primary_window"])
        let secondaryWindow = parseApiWindow(rateLimit?["secondary_window"])

        return CreditData(
            used: used, limit: limit, remaining: remaining, usedPercent: usedPercent,
            primaryWindow: primaryWindow, secondaryWindow: secondaryWindow
        )
    }

    private static func parseApiWindow(_ raw: Any?) -> ApiRateLimitWindow? {
        guard let d = raw as? [String: Any] else { return nil }
        let usedPercent = NumericParsing.double(d["used_percent"]) ?? 0
        let seconds = NumericParsing.int(d["limit_window_seconds"])
        guard let resetAt = NumericParsing.double(d["reset_at"]) else { return nil }
        return ApiRateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: seconds / 60,
            resetsAt: Date(timeIntervalSince1970: resetAt)
        )
    }

    private static func loadDiskCache() -> CreditData? {
        guard let data = try? Data(contentsOf: diskCacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return CreditData(
            used: (obj["used"] as? Double) ?? (obj["used"] as? String).flatMap(Double.init),
            limit: (obj["limit"] as? Double) ?? (obj["limit"] as? String).flatMap(Double.init),
            remaining: (obj["remaining"] as? Double) ?? (obj["remaining"] as? String).flatMap(Double.init),
            usedPercent: (obj["usedPercent"] as? Double) ?? (obj["usedPercent"] as? Int).map(Double.init),
            primaryWindow: parseDiskWindow(obj["primaryWindow"]),
            secondaryWindow: parseDiskWindow(obj["secondaryWindow"])
        )
    }

    private static func parseDiskWindow(_ raw: Any?) -> ApiRateLimitWindow? {
        guard let d = raw as? [String: Any] else { return nil }
        let usedPercent = NumericParsing.double(d["usedPercent"]) ?? 0
        let windowMinutes = NumericParsing.int(d["windowMinutes"])
        guard let resetAt = NumericParsing.double(d["resetsAt"]) else { return nil }
        return ApiRateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: Date(timeIntervalSince1970: resetAt)
        )
    }

    private static func saveDiskCache(_ data: CreditData) {
        var obj: [String: Any] = [
            "used": data.used as Any,
            "limit": data.limit as Any,
            "remaining": data.remaining as Any,
            "usedPercent": data.usedPercent as Any,
        ]
        if let w = data.primaryWindow {
            obj["primaryWindow"] = [
                "usedPercent": w.usedPercent,
                "windowMinutes": w.windowMinutes,
                "resetsAt": w.resetsAt.timeIntervalSince1970
            ] as [String: Any]
        }
        if let w = data.secondaryWindow {
            obj["secondaryWindow"] = [
                "usedPercent": w.usedPercent,
                "windowMinutes": w.windowMinutes,
                "resetsAt": w.resetsAt.timeIntervalSince1970
            ] as [String: Any]
        }
        let dir = diskCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let json = try? JSONSerialization.data(withJSONObject: obj) {
            try? json.write(to: diskCacheURL)
        }
    }

    public static func fetch() -> CreditData? {
        lock.lock()
        if let cached = cachedData, let at = cachedAt,
           Date().timeIntervalSince(at) < cacheTTL {
            lock.unlock()
            return cached
        }
        if cachedData == nil, let disk = loadDiskCache() {
            cachedData = disk
            cachedAt = Date().addingTimeInterval(-cacheTTL + 10)
        }
        lock.unlock()

        guard let auth = readAuth() else { return cachedData }
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        req.setValue(auth.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        guard let data = try? URLSession.synchronousData(from: req),
              let result = parseUsageResponse(data)
        else { return cachedData }

        lock.lock()
        cachedData = result
        cachedAt = Date()
        lock.unlock()
        saveDiskCache(result)
        return result
    }
}

private extension URLSession {
    static func synchronousData(from request: URLRequest) throws -> Data {
        var result: Result<Data, Error>!
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { result = .failure(error) }
            else { result = .success(data ?? Data()) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }
}
