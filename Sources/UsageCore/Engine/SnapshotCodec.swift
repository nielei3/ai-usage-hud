import Foundation

enum SnapshotCodec {
    static func encode(_ snapshot: UsageSnapshot) -> [String: Any]? {
        let claude: [String: Any] = [
            "fiveHourPercent": snapshot.claude.fiveHourPercent as Any,
            "fiveHourResetsAt": ISO8601DateFormatter().string(from: snapshot.claude.fiveHourResetsAt ?? Date()),
            "weeklyPercent": snapshot.claude.weeklyPercent as Any,
            "weeklyResetsAt": ISO8601DateFormatter().string(from: snapshot.claude.weeklyResetsAt ?? Date()),
            "creditUsedUsd": snapshot.claude.creditUsedUsd as Any,
            "creditLimitUsd": snapshot.claude.creditLimitUsd as Any,
        ]

        let rateLimits: [[String: Any]] = snapshot.codex.rateLimits.map { w in
            ["windowMinutes": w.windowMinutes, "usedPercent": w.usedPercent, "resetsAt": w.resetsAt.timeIntervalSince1970]
        }
        let codex: [String: Any] = [
            "rateLimits": rateLimits,
            "planType": snapshot.codex.planType as Any,
            "creditBalance": snapshot.codex.creditBalance as Any,
            "creditLimit": snapshot.codex.creditLimit as Any,
            "activeSessions": snapshot.codex.activeSessions,
        ]

        return ["claude": claude, "codex": codex]
    }

    static func decode(_ obj: [String: Any]) -> UsageSnapshot? {
        guard let claudeDict = obj["claude"] as? [String: Any] else { return nil }
        let f = ISO8601DateFormatter()

        let claude = UsageSnapshot.Claude(
            fiveHourPercent: (claudeDict["fiveHourPercent"] as? Double) ?? (claudeDict["fiveHourPercent"] as? Int).map(Double.init),
            fiveHourResetsAt: (claudeDict["fiveHourResetsAt"] as? String).flatMap { f.date(from: $0) },
            weeklyPercent: (claudeDict["weeklyPercent"] as? Double) ?? (claudeDict["weeklyPercent"] as? Int).map(Double.init),
            weeklyResetsAt: (claudeDict["weeklyResetsAt"] as? String).flatMap { f.date(from: $0) },
            creditUsedUsd: (claudeDict["creditUsedUsd"] as? Double) ?? (claudeDict["creditUsedUsd"] as? Int).map(Double.init),
            creditLimitUsd: (claudeDict["creditLimitUsd"] as? Double) ?? (claudeDict["creditLimitUsd"] as? Int).map(Double.init)
        )

        var rateLimits: [RateLimitWindow] = []
        if let rlArray = obj["codex"] as? [String: Any],
           let rls = rlArray["rateLimits"] as? [[String: Any]] {
            for rl in rls {
                if let mins = rl["windowMinutes"] as? Int,
                   let pct = rl["usedPercent"] as? Double,
                   let resetTs = rl["resetsAt"] as? Double {
                    rateLimits.append(RateLimitWindow(windowMinutes: mins, usedPercent: pct, resetsAt: Date(timeIntervalSince1970: resetTs)))
                }
            }
        }

        let codex = UsageSnapshot.Codex(
            rateLimits: rateLimits,
            planType: (obj["codex"] as? [String: Any])?["planType"] as? String,
            creditBalance: (obj["codex"] as? [String: Any])?["creditBalance"] as? Double,
            creditLimit: (obj["codex"] as? [String: Any])?["creditLimit"] as? Double
        )

        return UsageSnapshot(claude: claude, codex: codex)
    }
}
