import Foundation

public struct BlockEstimate: Sendable, Equatable {
    public var windowStart: Date
    public var usage: TokenUsage

    public init(windowStart: Date, usage: TokenUsage) {
        self.windowStart = windowStart
        self.usage = usage
    }

    public static func anchor(earliestEvent: Date?, now: Date) -> Date {
        let floor = now.addingTimeInterval(-5 * 3600)
        guard let earliestEvent else { return floor }
        return max(earliestEvent, floor)
    }
}
