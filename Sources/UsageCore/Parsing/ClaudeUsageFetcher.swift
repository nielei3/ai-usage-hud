import Foundation

/// Reads Claude Code usage directly from the Anthropic OAuth API.
/// Fetches live data every 60 seconds — does NOT depend on the OMC cache
/// which can go stale when no Claude Code session is active.
public struct ClaudeUsageFetcher: Sendable {
    public struct UsageData: Sendable, Equatable {
        public var fiveHourPercent: Double?
        public var fiveHourResetsAt: Date?
        public var weeklyPercent: Double?
        public var weeklyResetsAt: Date?
        public var creditUsedUsd: Double?
        public var creditLimitUsd: Double?

        public init(
            fiveHourPercent: Double? = nil,
            fiveHourResetsAt: Date? = nil,
            weeklyPercent: Double? = nil,
            weeklyResetsAt: Date? = nil,
            creditUsedUsd: Double? = nil,
            creditLimitUsd: Double? = nil
        ) {
            self.fiveHourPercent = fiveHourPercent
            self.fiveHourResetsAt = fiveHourResetsAt
            self.weeklyPercent = weeklyPercent
            self.weeklyResetsAt = weeklyResetsAt
            self.creditUsedUsd = creditUsedUsd
            self.creditLimitUsd = creditLimitUsd
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction = ISO8601DateFormatter()

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        if let d = isoFormatter.date(from: s) { return d }
        return isoFormatterNoFraction.date(from: s)
    }

    /// Read OAuth access token from macOS Keychain.
    private static func getAccessToken() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return nil }
        guard task.terminationStatus == 0 else { return nil }
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = obj["claudeAiOauth"] as? [String: Any]
        return oauth?["accessToken"] as? String
    }

    private static var cachedData: UsageData?
    private static var cachedAt: Date?
    private static let cacheTTL: TimeInterval = 120
    private static let lock = NSLock()

    private static var diskCacheURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/plugins/oh-my-claudecode/.usage-hud-cache.json")
    }

    private static func loadDiskCache() -> UsageData? {
        guard let data = try? Data(contentsOf: diskCacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return UsageData(
            fiveHourPercent: (obj["fiveHourPercent"] as? Double) ?? (obj["fiveHourPercent"] as? Int).map(Double.init),
            fiveHourResetsAt: parseDate(obj["fiveHourResetsAt"]),
            weeklyPercent: (obj["weeklyPercent"] as? Double) ?? (obj["weeklyPercent"] as? Int).map(Double.init),
            weeklyResetsAt: parseDate(obj["weeklyResetsAt"]),
            creditUsedUsd: (obj["creditUsedUsd"] as? Double) ?? (obj["creditUsedUsd"] as? Int).map(Double.init),
            creditLimitUsd: (obj["creditLimitUsd"] as? Double) ?? (obj["creditLimitUsd"] as? Int).map(Double.init)
        )
    }

    private static func saveDiskCache(_ data: UsageData) {
        let obj: [String: Any] = [
            "fiveHourPercent": data.fiveHourPercent as Any,
            "fiveHourResetsAt": ISO8601DateFormatter().string(from: data.fiveHourResetsAt ?? Date()),
            "weeklyPercent": data.weeklyPercent as Any,
            "weeklyResetsAt": ISO8601DateFormatter().string(from: data.weeklyResetsAt ?? Date()),
            "creditUsedUsd": data.creditUsedUsd as Any,
            "creditLimitUsd": data.creditLimitUsd as Any,
        ]
        let dir = diskCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let json = try? JSONSerialization.data(withJSONObject: obj) {
            try? json.write(to: diskCacheURL)
        }
    }

    /// Fetch live usage data from the Anthropic OAuth API.
    /// On startup, loads from disk cache first, then fetches fresh data.
    public static func fetch() -> UsageData? {
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

        guard let token = getAccessToken() else { return cachedData }
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        guard let data = try? URLSession.synchronousData(from: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return cachedData
        }

        if obj["error"] != nil {
            return cachedData
        }

        let fiveHour = obj["five_hour"] as? [String: Any]
        let sevenDay = obj["seven_day"] as? [String: Any]
        let spend = obj["spend"] as? [String: Any]
        let used = spend?["used"] as? [String: Any]
        let limit = spend?["limit"] as? [String: Any]

        func dollars(_ d: [String: Any]?) -> Double? {
            guard let amountMinor = d?["amount_minor"] as? Int,
                  let exponent = d?["exponent"] as? Int else { return nil }
            return Double(amountMinor) / pow(10.0, Double(exponent))
        }

        let result = UsageData(
            fiveHourPercent: (fiveHour?["utilization"] as? Double) ?? (fiveHour?["utilization"] as? Int).map(Double.init),
            fiveHourResetsAt: parseDate(fiveHour?["resets_at"]),
            weeklyPercent: (sevenDay?["utilization"] as? Double) ?? (sevenDay?["utilization"] as? Int).map(Double.init),
            weeklyResetsAt: parseDate(sevenDay?["resets_at"]),
            creditUsedUsd: dollars(used),
            creditLimitUsd: dollars(limit)
        )

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
