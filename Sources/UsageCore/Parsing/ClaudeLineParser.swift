import Foundation

public struct ClaudeUsageRow: Sendable, Equatable {
    public var timestamp: Date
    public var sessionId: String
    public var model: String?
    public var isSidechain: Bool
    public var usage: TokenUsage

    public init(
        timestamp: Date,
        sessionId: String,
        model: String? = nil,
        isSidechain: Bool = false,
        usage: TokenUsage = TokenUsage()
    ) {
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.model = model
        self.isSidechain = isSidechain
        self.usage = usage
    }
}

public struct ClaudeLineParser {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction = ISO8601DateFormatter()

    public init() {}

    public func parse(_ line: String) -> ClaudeUsageRow? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let ts = parseTimestamp(obj["timestamp"]) else { return nil }
        let sessionId = (obj["sessionId"] as? String) ?? ""
        let isSidechain = (obj["isSidechain"] as? Bool) ?? ((obj["isSidechain"] as? Bool) ?? false)

        guard let message = obj["message"] as? [String: Any],
              let usageDict = message["usage"] as? [String: Any]
        else { return nil }

        let usage = parseUsage(usageDict)
        let model = message["model"] as? String
        return ClaudeUsageRow(
            timestamp: ts,
            sessionId: sessionId,
            model: model,
            isSidechain: isSidechain,
            usage: usage
        )
    }

    private func parseTimestamp(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        if let d = Self.isoFormatter.date(from: s) { return d }
        return Self.isoFormatterNoFraction.date(from: s)
    }

    private func parseUsage(_ dict: [String: Any]) -> TokenUsage {
        let input = intOf(dict["input_tokens"])
        let output = intOf(dict["output_tokens"])
        let cacheRead = intOf(dict["cache_read_input_tokens"])
        let cacheCreation = parseCacheCreation(dict["cache_creation_input_tokens"] ?? dict["cache_creation"])
        return TokenUsage(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation
        )
    }

    private func parseCacheCreation(_ raw: Any?) -> Int {
        if let flat = raw as? Int { return flat }
        if let flatStr = raw as? String, let f = Int(flatStr) { return f }
        if let nested = raw as? [String: Any] {
            let fiveMin = intOf(nested["ephemeral_5m_input_tokens"])
            let oneHour = intOf(nested["ephemeral_1h_input_tokens"])
            return fiveMin + oneHour
        }
        return 0
    }

    private func intOf(_ raw: Any?) -> Int {
        NumericParsing.int(raw)
    }
}
