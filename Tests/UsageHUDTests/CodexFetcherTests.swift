import Foundation
import Testing

@testable import UsageCore

@Suite struct CodexFetcherResponseTests {
    private let sampleJSON = #"""
        {"plan_type": "self_serve_business_prolite",
         "rate_limit": {"allowed": true, "limit_reached": false,
           "primary_window": {"used_percent": 0, "limit_window_seconds": 604800, "reset_after_seconds": 604800, "reset_at": 1792889404},
           "secondary_window": null},
         "spend_control": {"reached": false, "individual_limit": {"limit": "250000", "used": "2407.88", "remaining": "247592.11", "used_percent": 1, "reset_at": 1793491200}}}
        """#

    @Test func parsesCreditsFromSpendControl() {
        let data = sampleJSON.data(using: .utf8)!
        let result = CodexUsageFetcher.parseUsageResponse(data)!
        #expect(result.used == 2407.88)
        #expect(result.limit == 250000.0)
        #expect(result.remaining == 247592.11)
    }

    @Test func parsesPrimaryWindow() {
        let data = sampleJSON.data(using: .utf8)!
        let result = CodexUsageFetcher.parseUsageResponse(data)!
        let w = result.primaryWindow
        #expect(w?.usedPercent == 0)
        #expect(w?.windowMinutes == 10080)
        #expect(w?.resetsAt == Date(timeIntervalSince1970: 1_792_889_404))
    }

    @Test func secondaryWindowIsNilWhenAbsent() {
        let data = sampleJSON.data(using: .utf8)!
        let result = CodexUsageFetcher.parseUsageResponse(data)!
        #expect(result.secondaryWindow == nil)
    }

    @Test func parsesDualWindows() {
        let json = #"""
            {"rate_limit": {
               "primary_window": {"used_percent": 42, "limit_window_seconds": 604800, "reset_at": 1792889404},
               "secondary_window": {"used_percent": 15, "limit_window_seconds": 18000, "reset_at": 1792900404}},
             "spend_control": {"individual_limit": {"limit": "1000", "used": "100", "remaining": "900"}}}
            """#
        let data = json.data(using: .utf8)!
        let result = CodexUsageFetcher.parseUsageResponse(data)!
        #expect(result.primaryWindow?.usedPercent == 42)
        #expect(result.primaryWindow?.windowMinutes == 10080)
        #expect(result.secondaryWindow?.usedPercent == 15)
        #expect(result.secondaryWindow?.windowMinutes == 300)
        #expect(result.secondaryWindow?.resetsAt == Date(timeIntervalSince1970: 1_792_900_404))
    }

    @Test func returnsNilForErrorResponse() {
        let json = #"{"error": "rate_limited"}"#
        let data = json.data(using: .utf8)!
        #expect(CodexUsageFetcher.parseUsageResponse(data) == nil)
    }

    @Test func returnsNilForInvalidJSON() {
        #expect(CodexUsageFetcher.parseUsageResponse(Data("not json".utf8)) == nil)
    }

    @Test func handlesMissingRateLimit() {
        let json = #"{"spend_control": {"individual_limit": {"limit": "1000", "used": "500", "remaining": "500"}}}"#
        let data = json.data(using: .utf8)!
        let result = CodexUsageFetcher.parseUsageResponse(data)!
        #expect(result.primaryWindow == nil)
        #expect(result.secondaryWindow == nil)
        #expect(result.used == 500)
    }
}

@Suite struct NullWindowRolloutRuleTests {
    @Test func nullWindowsDoNotReplaceExistingOnes() {
        let existing = [RateLimitWindow(
            windowMinutes: 10080, usedPercent: 75.0,
            resetsAt: Date(timeIntervalSince1970: 1_799_999_999)
        )]
        let nullLimits = CodexRateLimits(
            primary: nil, secondary: nil, planType: "pro", creditBalance: nil
        )
        let result = UsageEngine.mergeRateLimits(current: existing, from: nullLimits)
        #expect(result == existing)
    }

    @Test func realWindowsReplaceExistingOnes() {
        let existing = [RateLimitWindow(
            windowMinutes: 10080, usedPercent: 75.0,
            resetsAt: Date(timeIntervalSince1970: 1_799_999_999)
        )]
        let newLimits = CodexRateLimits(
            primary: CodexRateLimitWindow(
                windowMinutes: 10080, usedPercent: 80.0,
                resetsAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            secondary: nil, planType: nil, creditBalance: nil
        )
        let result = UsageEngine.mergeRateLimits(current: existing, from: newLimits)
        #expect(result.count == 1)
        #expect(result[0].usedPercent == 80.0)
    }

    @Test func nilRateLimitsKeepsExisting() {
        let existing = [RateLimitWindow(
            windowMinutes: 300, usedPercent: 42.0,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000)
        )]
        let result = UsageEngine.mergeRateLimits(current: existing, from: nil)
        #expect(result == existing)
    }

    @Test func emptyCurrentStaysEmptyForNullWindows() {
        let nullLimits = CodexRateLimits(primary: nil, secondary: nil)
        let result = UsageEngine.mergeRateLimits(current: [], from: nullLimits)
        #expect(result.isEmpty)
    }
}
