import Foundation

public struct UsageSnapshot: Sendable, Equatable {
    public struct Claude: Sendable, Equatable {
        public var todayUsage: TokenUsage
        public var blockUsage: TokenUsage
        public var blockStart: Date?
        public var activeSessions: Int
        public var lastActivity: Date?
        public var lastModel: String?

        public init(
            todayUsage: TokenUsage = TokenUsage(),
            blockUsage: TokenUsage = TokenUsage(),
            blockStart: Date? = nil,
            activeSessions: Int = 0,
            lastActivity: Date? = nil,
            lastModel: String? = nil
        ) {
            self.todayUsage = todayUsage
            self.blockUsage = blockUsage
            self.blockStart = blockStart
            self.activeSessions = activeSessions
            self.lastActivity = lastActivity
            self.lastModel = lastModel
        }
    }

    public struct Codex: Sendable, Equatable {
        public var todayUsage: CodexTokenUsage
        public var rateLimits: [RateLimitWindow]
        public var planType: String?
        public var activeSessions: Int
        public var lastActivity: Date?

        public init(
            todayUsage: CodexTokenUsage = CodexTokenUsage(),
            rateLimits: [RateLimitWindow] = [],
            planType: String? = nil,
            activeSessions: Int = 0,
            lastActivity: Date? = nil
        ) {
            self.todayUsage = todayUsage
            self.rateLimits = rateLimits
            self.planType = planType
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
