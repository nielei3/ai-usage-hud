import Foundation

public protocol UsageClock: Sendable {
    func now() -> Date
    var calendar: Calendar { get }
}

public struct SystemClock: UsageClock {
    private let timeZone: TimeZone?

    public init(timeZone: TimeZone? = nil) {
        self.timeZone = timeZone
    }

    public func now() -> Date { Date() }

    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        if let timeZone { c.timeZone = timeZone }
        return c
    }
}

public struct ManualClock: UsageClock {
    private let state: LockedState

    public init(start: Date, timeZone: TimeZone = TimeZone(identifier: "UTC")!) {
        self.state = LockedState(current: start, timeZone: timeZone)
    }

    public func now() -> Date { state.current }

    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = state.timeZone
        return c
    }

    public mutating func advance(by interval: TimeInterval) {
        state.current = state.current.addingTimeInterval(interval)
    }

    public mutating func set(_ date: Date) { state.current = date }

    private final class LockedState: @unchecked Sendable {
        private let lock = NSLock()
        private var _current: Date
        let timeZone: TimeZone

        init(current: Date, timeZone: TimeZone) {
            _current = current
            self.timeZone = timeZone
        }

        var current: Date {
            get { lock.lock(); defer { lock.unlock() }; return _current }
            set { lock.lock(); defer { lock.unlock() }; _current = newValue }
        }
    }
}
