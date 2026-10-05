import Foundation

public struct CodexRateLimitWindow: Sendable, Equatable {
    public var windowMinutes: Int
    public var usedPercent: Double
    public var resetsAt: Date

    public init(windowMinutes: Int, usedPercent: Double, resetsAt: Date) {
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct CodexRateLimits: Sendable, Equatable {
    public var primary: CodexRateLimitWindow?
    public var secondary: CodexRateLimitWindow?
    public var planType: String?
    public var creditBalance: Double?

    public init(
        primary: CodexRateLimitWindow? = nil,
        secondary: CodexRateLimitWindow? = nil,
        planType: String? = nil,
        creditBalance: Double? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.creditBalance = creditBalance
    }
}

public struct CodexUsageRow: Sendable, Equatable {
    public var timestamp: Date
    public var last: CodexTokenUsage?
    public var total: CodexTokenUsage?
    public var rateLimits: CodexRateLimits?

    public init(
        timestamp: Date,
        last: CodexTokenUsage? = nil,
        total: CodexTokenUsage? = nil,
        rateLimits: CodexRateLimits? = nil
    ) {
        self.timestamp = timestamp
        self.last = last
        self.total = total
        self.rateLimits = rateLimits
    }
}

public struct CodexLineParser {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init() {}

    public func parse(_ line: String) -> CodexUsageRow? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count"
        else { return nil }

        let ts = isoDate(obj["timestamp"])
        guard let ts else { return nil }

        let info = payload["info"] as? [String: Any]
        let last = info.flatMap { tokenUsage($0["last_token_usage"]) }
        let total = info.flatMap { tokenUsage($0["total_token_usage"]) }
        let limits = rateLimits(payload["rate_limits"] ?? info?["rate_limits"])

        return CodexUsageRow(timestamp: ts, last: last, total: total, rateLimits: limits)
    }

    private func isoDate(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        return Self.isoFormatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private func intOf(_ raw: Any?) -> Int {
        NumericParsing.int(raw)
    }

    private func tokenUsage(_ raw: Any?) -> CodexTokenUsage? {
        guard let d = raw as? [String: Any] else { return nil }
        return CodexTokenUsage(
            inputTokens: intOf(d["input_tokens"]),
            cachedInputTokens: intOf(d["cached_input_tokens"]),
            cacheWriteTokens: intOf(d["cache_write_input_tokens"]),
            outputTokens: intOf(d["output_tokens"]),
            reasoningOutputTokens: intOf(d["reasoning_output_tokens"])
        )
    }

    private func window(_ raw: Any?) -> CodexRateLimitWindow? {
        guard let d = raw as? [String: Any] else { return nil }
        let minutes = intOf(d["window_minutes"])
        let pct = doubleOf(d["used_percent"] ?? d["used_percent"]) ?? 0
        guard let resets = doubleOf(d["resets_at"]) else { return nil }
        return CodexRateLimitWindow(
            windowMinutes: minutes,
            usedPercent: pct,
            resetsAt: Date(timeIntervalSince1970: resets)
        )
    }

    private func doubleOf(_ raw: Any?) -> Double? {
        NumericParsing.double(raw)
    }

    private func rateLimits(_ raw: Any?) -> CodexRateLimits? {
        guard let d = raw as? [String: Any] else { return nil }
        let credits = d["credits"] as? [String: Any]
        let balance = (credits?["balance"] as? Double) ?? (credits?["balance"] as? Int).map(Double.init)
        return CodexRateLimits(
            primary: window(d["primary"]),
            secondary: window(d["secondary"]),
            planType: d["plan_type"] as? String,
            creditBalance: balance
        )
    }
}
