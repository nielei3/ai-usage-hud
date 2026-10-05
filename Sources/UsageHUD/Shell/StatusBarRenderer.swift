import AppKit
import UsageCore

enum StatusBarRenderer {
    /// Pure: `limitTokens` is the user's Claude 5h cap (nil = no cap set).
    /// The decision and both percents come from StatusBarDecision (UsageCore).
    static func text(for snapshot: UsageSnapshot, limitTokens: Int?) -> String {
        let claudePct = StatusBarDecision.blockPercent(
            blockUsage: snapshot.claude.blockUsage, limitTokens: limitTokens
        )
        let codexPct = snapshot.codex.rateLimits.first?.usedPercent
        switch StatusBarDecision.resolve(
            claudePercent: claudePct,
            codexPercent: codexPct,
            claudeTodayTokens: snapshot.claude.todayUsage.totalTokens,
            codexTodayTokens: snapshot.codex.todayUsage.totalTokens
        ) {
        case .maxPercent(let claude, let codex):
            return String(format: "%.0f%%/%.0f%%", claude, codex)
        case .singleSide(let side, let percent):
            let name = side == .claude ? "C" : "Codex"
            return String(format: "%@%.0f%%", name, percent)
        case .tokenFallback(let text):
            return text
        case .idle:
            return "—"
        }
    }
}
