import Foundation

/// Per-file Codex delta accumulator.
/// RULE: today rows sum `last_token_usage` when present. When a row lacks it,
/// today's delta = today's total_token_usage − the previous row's total — the
/// previous row may be YESTERDAY's last line, so `prevTotal` MUST be carried
/// across midnight per file. A file whose FIRST row already lacks the delta
/// uses baseline 0 (first cumulative total == its own delta).
public struct DeltaAccumulator {
    public private(set) var prevTotals: [String: Int]
    public private(set) var prevOutputs: [String: Int]

    public init() {
        self.prevTotals = [:]
        self.prevOutputs = [:]
    }

    /// Full rescan restarts every file from its first byte — the carried
    /// baselines would double-count against the re-ingested totals.
    public mutating func reset() {
        prevTotals = [:]
        prevOutputs = [:]
    }

    public mutating func absorb(
        row: CodexUsageRow,
        today: (Date) -> Bool,
        fileKey: String
    ) -> CodexTokenUsage {
        defer {
            if let total = row.total {
                prevTotals[fileKey] = total.inputTokens
                prevOutputs[fileKey] = total.outputTokens
            }
        }

        guard today(row.timestamp) else { return CodexTokenUsage() }

        if let last = row.last {
            return last
        }
        guard let total = row.total else { return CodexTokenUsage() }
        let baseline = prevTotals[fileKey] ?? 0
        let inputDelta = max(total.inputTokens - baseline, 0)
        let outputDelta = max(total.outputTokens - (prevOutputs[fileKey] ?? 0), 0)
        return CodexTokenUsage(
            inputTokens: inputDelta,
            cachedInputTokens: 0,
            cacheWriteTokens: 0,
            outputTokens: outputDelta,
            reasoningOutputTokens: 0
        )
    }
}
