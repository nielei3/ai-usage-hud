import Foundation

public enum StatusBarDecision {
    public enum Outcome: Sendable, Equatable {
        case maxPercent(claude: Double, codex: Double)
        case singleSide(side: Side, percent: Double)
        case tokenFallback(text: String)
        case idle
    }

    public enum Side: Sendable, Equatable {
        case claude
        case codex
    }

    public static func resolve(
        claudePercent: Double?,
        codexPercent: Double?,
        claudeTodayTokens: Int,
        codexTodayTokens: Int
    ) -> Outcome {
        switch (claudePercent, codexPercent) {
        case let (.some(c), .some(x)):
            return .maxPercent(claude: c, codex: x)
        case let (.some(c), .none):
            return .singleSide(side: .claude, percent: c)
        case let (.none, .some(x)):
            return .singleSide(side: .codex, percent: x)
        case (.none, .none):
            let larger = max(claudeTodayTokens, codexTodayTokens)
            if larger <= 0 { return .idle }
            return .tokenFallback(text: abbreviate(larger))
        }
    }

    public static func abbreviate(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens)" }
        if tokens < 1_000_000 {
            let k = Double(tokens) / 1_000
            return k >= 100 ? "\(Int(k))k" : String(format: "%.0fk", k)
        }
        let m = Double(tokens) / 1_000_000
        return m >= 100 ? "\(Int(m))M" : String(format: "%.1fM", m)
    }


    /// Claude 5h-block share of the user's token cap — nil means "no cap set".
    /// Uses blockUsage's own total, never todayUsage.
    public static func blockPercent(blockUsage: TokenUsage, limitTokens: Int?) -> Double? {
        guard let limitTokens, limitTokens > 0 else { return nil }
        let used = blockUsage.inputTokens + blockUsage.outputTokens
            + blockUsage.cacheReadTokens + blockUsage.cacheCreationTokens
        guard used > 0 else { return 0 }
        return max(0, min(100, Double(used) / Double(limitTokens) * 100))
    }
}