import Foundation

public struct UsageSnapshot: Sendable, Equatable {
    public struct Claude: Sendable, Equatable {
        public var todayUsage: TokenUsage
        public var blockUsage: TokenUsage
        public var blockStart: Date?
        public var weeklyUsage: TokenUsage
        public var fiveHourPercent: Double?
        public var fiveHourResetsAt: Date?
        public var weeklyPercent: Double?
        public var weeklyResetsAt: Date?
        public var creditUsedUsd: Double?
        public var creditLimitUsd: Double?
        public var activeSessions: Int
        public var lastActivity: Date?
        public var lastModel: String?

        public init(
            todayUsage: TokenUsage = TokenUsage(),
            blockUsage: TokenUsage = TokenUsage(),
            blockStart: Date? = nil,
            weeklyUsage: TokenUsage = TokenUsage(),
            fiveHourPercent: Double? = nil,
            fiveHourResetsAt: Date? = nil,
            weeklyPercent: Double? = nil,
            weeklyResetsAt: Date? = nil,
            creditUsedUsd: Double? = nil,
            creditLimitUsd: Double? = nil,
            activeSessions: Int = 0,
            lastActivity: Date? = nil,
            lastModel: String? = nil
        ) {
            self.todayUsage = todayUsage
            self.blockUsage = blockUsage
            self.blockStart = blockStart
            self.weeklyUsage = weeklyUsage
            self.fiveHourPercent = fiveHourPercent
            self.fiveHourResetsAt = fiveHourResetsAt
            self.weeklyPercent = weeklyPercent
            self.weeklyResetsAt = weeklyResetsAt
            self.creditUsedUsd = creditUsedUsd
            self.creditLimitUsd = creditLimitUsd
            self.activeSessions = activeSessions
            self.lastActivity = lastActivity
            self.lastModel = lastModel
        }
    }

    public struct Codex: Sendable, Equatable {
        public var todayUsage: CodexTokenUsage
        public var rateLimits: [RateLimitWindow]
        public var planType: String?
        public var creditBalance: Double?
        public var creditLimit: Double?
        public var activeSessions: Int
        public var lastActivity: Date?

        public init(
            todayUsage: CodexTokenUsage = CodexTokenUsage(),
            rateLimits: [RateLimitWindow] = [],
            planType: String? = nil,
            creditBalance: Double? = nil,
            creditLimit: Double? = nil,
            activeSessions: Int = 0,
            lastActivity: Date? = nil
        ) {
            self.todayUsage = todayUsage
            self.rateLimits = rateLimits
            self.planType = planType
            self.creditBalance = creditBalance
            self.creditLimit = creditLimit
            self.activeSessions = activeSessions
            self.lastActivity = lastActivity
        }
    }

    public var claude: Claude
    public var codex: Codex

    public init(claude: Claude = Claude(), codex: Codex = Codex()) {
        self.claude = claude
        self.codex = codex
    }
}
