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

        public init(used: Double? = nil, limit: Double? = nil, remaining: Double? = nil, usedPercent: Double? = nil) {
            self.used = used
            self.limit = limit
            self.remaining = remaining
            self.usedPercent = usedPercent
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
        return CreditData(
            used: (obj["used"] as? Double) ?? (obj["used"] as? String).flatMap(Double.init),
            limit: (obj["limit"] as? Double) ?? (obj["limit"] as? String).flatMap(Double.init),
            remaining: (obj["remaining"] as? Double) ?? (obj["remaining"] as? String).flatMap(Double.init),
            usedPercent: (obj["usedPercent"] as? Double) ?? (obj["usedPercent"] as? Int).map(Double.init)
        )
    }

    private static func saveDiskCache(_ data: CreditData) {
        let obj: [String: Any] = [
            "used": data.used as Any,
            "limit": data.limit as Any,
            "remaining": data.remaining as Any,
            "usedPercent": data.usedPercent as Any,
        ]
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

        let spendControl = obj["spend_control"] as? [String: Any]
        let individualLimit = spendControl?["individual_limit"] as? [String: Any]

        let used = (individualLimit?["used"] as? String).flatMap(Double.init)
        let limit = (individualLimit?["limit"] as? String).flatMap(Double.init)
        let remaining = (individualLimit?["remaining"] as? String).flatMap(Double.init)
        let usedPercent: Double? = {
            guard let u = used, let l = limit, l > 0 else { return nil }
            return min(max(u / l * 100, 0), 100)
        }()

        let result = CreditData(used: used, limit: limit, remaining: remaining, usedPercent: usedPercent)

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
