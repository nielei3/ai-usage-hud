import Foundation
import Testing

@testable import UsageCore

private func fixture(_ parts: String...) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    return parts.reduce(here) { $0.appendingPathComponent($1) }.path
}

@Suite struct ClaudeParsingTests {
    private let parser = ClaudeLineParser()

    @Test func parsesFlatCacheCreationRow() {
        let url = fixture("claude", "projects", "11111111-aaaa-4bbb-8ccc-222222222222", "session.jsonl")
        let rows = try! String(contentsOfFile: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { parser.parse(String($0)) }

        #expect(rows.count == 3)
        #expect(rows[0].usage.inputTokens == 1000)
        #expect(rows[0].usage.outputTokens == 500)
        #expect(rows[0].usage.cacheReadTokens == 2000)
        #expect(rows[0].usage.cacheCreationTokens == 300)
        #expect(rows[0].isSidechain == false)
        #expect(rows[0].model == "claude-sonnet-4-5")
    }

    @Test func parsesNestedCacheCreationRow() {
        let url = fixture("claude", "projects", "11111111-aaaa-4bbb-8ccc-222222222222", "session.jsonl")
        let rows = try! String(contentsOfFile: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { parser.parse(String($0)) }

        #expect(rows[1].usage.cacheCreationTokens == 400 + 200)
        #expect(rows[1].timestamp > rows[0].timestamp)
    }

    @Test func parsesSidechainRowsCarryingParentSessionId() {
        let url = fixture("claude", "projects", "11111111-aaaa-4bbb-8ccc-222222222222", "subagents", "agent-abc.jsonl")
        let rows = try! String(contentsOfFile: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { parser.parse(String($0)) }

        #expect(rows.count == 2)
        #expect(rows[0].isSidechain)
        #expect(rows[0].sessionId == "11111111-aaaa-4bbb-8ccc-222222222222")
    }

    @Test func parsesLegacyInlineSidechainRow() {
        let url = fixture("claude", "projects", "33333333-bbbb-4ccc-8ddd-444444444444", "legacy.jsonl")
        let rows = try! String(contentsOfFile: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { parser.parse(String($0)) }

        #expect(rows.count == 1)
        #expect(rows[0].isSidechain)
        #expect(rows[0].usage.inputTokens == 200)
    }

    @Test func skipsCorruptAndNonAssistantLines() {
        #expect(parser.parse("{ not json") == nil)
        #expect(parser.parse(#"{"type":"user","timestamp":"2026-10-01T00:00:00Z","sessionId":"s"}"#) == nil)
        #expect(parser.parse("") == nil)
    }
}

@Suite struct CodexParsingTests {
    private let parser = CodexLineParser()

    private func rows(_ parts: [String]) -> [CodexUsageRow] {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let url = parts.reduce(base) { $0.appendingPathComponent($1) }
        return try! String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { parser.parse(String($0)) }
    }

    @Test func parsesTokenCountEventsWithLastAndTotalUsage() {
        let parsed = rows(["codex", "sessions", "2026", "09", "30", "rollout-fix.jsonl"])
        #expect(parsed.count == 3)

        #expect(parsed[0].last?.inputTokens == 10000)
        #expect(parsed[0].last?.cachedInputTokens == 2000)
        #expect(parsed[0].last?.cacheWriteTokens == 500)
        #expect(parsed[0].last?.outputTokens == 4000)
        #expect(parsed[0].last?.reasoningOutputTokens == 1500)
        #expect(parsed[0].total?.totalTokens == 14000)
    }

    @Test func parsesSingleWindowRateLimits() {
        let parsed = rows(["codex", "sessions", "2026", "09", "30", "rollout-fix.jsonl"])
        let limits = parsed[0].rateLimits
        #expect(limits?.planType == "pro")
        #expect(limits?.primary?.windowMinutes == 10_080)
        #expect(limits?.primary?.usedPercent == 75.0)
        #expect(limits?.secondary == nil)
        #expect(limits?.primary?.resetsAt == Date(timeIntervalSince1970: 1_799_999_999.0))
    }

    @Test func parsesDualWindowRateLimits() {
        let parsed = rows(["codex", "sessions", "2026", "09", "30", "rollout-fix.jsonl"])
        let limits = parsed[1].rateLimits
        #expect(limits?.primary?.usedPercent == 78.5)
        #expect(limits?.secondary?.windowMinutes == 300)
        #expect(limits?.secondary?.usedPercent == 42.0)
        #expect(limits?.primary?.resetsAt == Date(timeIntervalSince1970: 1_800_086_399.0))
    }

    @Test func thirdEventCarriesNoRateLimits() {
        let parsed = rows(["codex", "sessions", "2026", "09", "30", "rollout-fix.jsonl"])
        #expect(parsed[2].rateLimits == nil)
        #expect(parsed[2].last?.totalTokens == 4500)
    }

    @Test func skipsNonTokenCountLines() {
        #expect(parser.parse(#"{"timestamp":"2026-10-01T00:00:00Z","type":"event_msg","payload":{"type":"turn_started"}}"#) == nil)
        #expect(parser.parse("garbage") == nil)
    }
}
