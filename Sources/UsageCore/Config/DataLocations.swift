import Foundation

public struct DataLocations: Sendable, Equatable {
    public var claudeRoot: URL
    public var codexRoot: URL
    public var claudeUsageCache: URL

    public init(claudeRoot: URL, codexRoot: URL, claudeUsageCache: URL) {
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
        self.claudeUsageCache = claudeUsageCache
    }

    /// env overrides win over home defaults (e2e fixture path).
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> DataLocations {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeRoot = environment["USAGE_HUD_CLAUDE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
        let codexRoot = environment["USAGE_HUD_CODEX_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let claudeUsageCache = environment["USAGE_HUD_CLAUDE_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude/plugins/oh-my-claudecode/.usage-cache-anthropic.json")
        return DataLocations(claudeRoot: claudeRoot, codexRoot: codexRoot, claudeUsageCache: claudeUsageCache)
    }
}
