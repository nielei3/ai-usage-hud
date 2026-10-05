import Foundation

/// Reads the OMC plugin's Anthropic usage cache, which is populated by the
/// HUD script's periodic call to api.anthropic.com/api/oauth/usage.
public struct ClaudeUsageCache: Sendable, Equatable {
    public var fiveHourPercent: Double?
    public var fiveHourResetsAt: Date?
    public var weeklyPercent: Double?
    public var weeklyResetsAt: Date?
    public var timestamp: Date?

    public init(
        fiveHourPercent: Double? = nil,
        fiveHourResetsAt: Date? = nil,
        weeklyPercent: Double? = nil,
        weeklyResetsAt: Date? = nil,
        timestamp: Date? = nil
    ) {
        self.fiveHourPercent = fiveHourPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weeklyPercent = weeklyPercent
        self.weeklyResetsAt = weeklyResetsAt
        self.timestamp = timestamp
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

    public static func read(from url: URL) -> ClaudeUsageCache? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let d = obj["data"] as? [String: Any]
        let hasError = (obj["error"] as? Bool) ?? false
        guard !hasError else { return nil }

        let fiveHourPct = (d?["fiveHourPercent"] as? Double) ?? (d?["fiveHourPercent"] as? Int).map(Double.init)
        let weeklyPct = (d?["weeklyPercent"] as? Double) ?? (d?["weeklyPercent"] as? Int).map(Double.init)

        return ClaudeUsageCache(
            fiveHourPercent: fiveHourPct,
            fiveHourResetsAt: parseDate(d?["fiveHourResetsAt"]),
            weeklyPercent: weeklyPct,
            weeklyResetsAt: parseDate(d?["weeklyResetsAt"]),
            timestamp: (obj["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}
