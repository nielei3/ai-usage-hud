import Foundation

/// Fetches Codex credit usage directly from the ChatGPT backend API.
/// Endpoint: GET https://chatgpt.com/backend-api/wham/usage
/// Auth: Bearer token + ChatGPT-Account-Id header from ~/.codex/auth.json
public struct CodexUsageFetcher: Sendable {
    public struct CreditData: Sendable, Equatable {
        public var used: Double?
        public var limit: Double?
        public var remaining: Double?
        public var usedPercent: Double?
        public var rateLimits: [RateLimitWindow]

        public init(
            used: Double? = nil,
            limit: Double? = nil,
            remaining: Double? = nil,
            usedPercent: Double? = nil,
            rateLimits: [RateLimitWindow] = []
        ) {
            self.used = used
            self.limit = limit
            self.remaining = remaining
            self.usedPercent = usedPercent
            self.rateLimits = rateLimits
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

    private static func loadDiskCache() -> CreditData? {
        guard let data = try? Data(contentsOf: diskCacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return decodeDiskCache(obj)
    }

    static func decodeDiskCache(_ obj: [String: Any]) -> CreditData {
        let rateLimits = (obj["rateLimits"] as? [[String: Any]] ?? []).compactMap { raw -> RateLimitWindow? in
            guard let windowMinutes = NumericParsing.intValue(raw["windowMinutes"]),
                  windowMinutes >= 0,
                  let usedPercent = NumericParsing.percent(raw["usedPercent"]),
                  let resetTimestamp = NumericParsing.double(raw["resetsAt"]),
                  resetTimestamp.isFinite
            else { return nil }
            return RateLimitWindow(
                windowMinutes: windowMinutes,
                usedPercent: usedPercent,
                resetsAt: Date(timeIntervalSince1970: resetTimestamp)
            )
        }

        return CreditData(
            used: NumericParsing.double(obj["used"]),
            limit: NumericParsing.double(obj["limit"]),
            remaining: NumericParsing.double(obj["remaining"]),
            usedPercent: NumericParsing.percent(obj["usedPercent"]),
            rateLimits: rateLimits
        )
    }

    static func encodeDiskCache(_ data: CreditData) -> [String: Any] {
        [
            "used": data.used as Any,
            "limit": data.limit as Any,
            "remaining": data.remaining as Any,
            "usedPercent": data.usedPercent as Any,
            "rateLimits": data.rateLimits.map { window in
                [
                    "windowMinutes": window.windowMinutes,
                    "usedPercent": window.usedPercent,
                    "resetsAt": window.resetsAt.timeIntervalSince1970,
                ]
            },
        ]
    }

    /// Parses the response without requiring credentials or a network request.
    /// The endpoint's current rate-limit shape is separate from the legacy
    /// spend_control.individual_limit credit shape.
    public static func parseResponse(_ data: Data) -> CreditData? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["error"] == nil
        else { return nil }
        return parseResponseObject(obj)
    }

    private static func parseResponseObject(_ obj: [String: Any]) -> CreditData {
        let spendControl = obj["spend_control"] as? [String: Any]
        let individualLimit = spendControl?["individual_limit"] as? [String: Any]

        let used = NumericParsing.double(individualLimit?["used"])
        let limit = NumericParsing.double(individualLimit?["limit"])
        let remaining = NumericParsing.double(individualLimit?["remaining"])
        let usedPercent: Double? = {
            guard let u = used, u.isFinite,
                  let l = limit, l.isFinite, l > 0
            else { return nil }
            let percent = u / l * 100
            guard percent.isFinite else { return nil }
            return min(max(percent, 0), 100)
        }()

        let rateLimit = obj["rate_limit"] as? [String: Any]
        let rateLimits = [rateLimit?["primary_window"], rateLimit?["secondary_window"]]
            .compactMap(parseRateLimitWindow)

        return CreditData(
            used: used,
            limit: limit,
            remaining: remaining,
            usedPercent: usedPercent,
            rateLimits: rateLimits
        )
    }

    private static func parseRateLimitWindow(_ raw: Any?) -> RateLimitWindow? {
        guard let window = raw as? [String: Any],
              let usedPercent = NumericParsing.percent(window["used_percent"]),
              let seconds = NumericParsing.double(window["limit_window_seconds"]),
              seconds.isFinite,
              seconds >= 0,
              let resetsAt = NumericParsing.double(window["reset_at"]),
              resetsAt.isFinite
        else { return nil }

        return RateLimitWindow(
            windowMinutes: NumericParsing.int(seconds / 60),
            usedPercent: usedPercent,
            resetsAt: Date(timeIntervalSince1970: resetsAt)
        )
    }

    private static func saveDiskCache(_ data: CreditData) {
        let obj = encodeDiskCache(data)
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
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return cachedData }

        if obj["error"] != nil { return cachedData }

        let result = parseResponseObject(obj)

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
