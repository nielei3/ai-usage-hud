import Foundation

public struct RateLimitWindow: Sendable, Equatable {
    public var windowMinutes: Int
    public var usedPercent: Double
    public var resetsAt: Date

    public init(windowMinutes: Int, usedPercent: Double, resetsAt: Date) {
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var windowName: String {
        switch windowMinutes {
        case 300: "5h"
        case 10080: "weekly"
        default: "\(windowMinutes)m"
        }
    }
}
