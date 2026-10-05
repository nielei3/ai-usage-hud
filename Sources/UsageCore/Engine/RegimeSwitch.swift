import Foundation

public enum Regime: Sendable, Equatable {
    case fullScan
    case incrementalTail
}

/// Last full scan took >1s → tail regime (per-file offsets + 60s sweep);
/// ≤1s → full rescan of the candidate set on every event.
public struct RegimeSwitch: Sendable {
    private let threshold: TimeInterval
    public private(set) var lastFullScanDuration: TimeInterval = 0

    public init(threshold: TimeInterval = 1.0) {
        self.threshold = threshold
    }

    public var regime: Regime {
        lastFullScanDuration > threshold ? .incrementalTail : .fullScan
    }

    public mutating func recordFullScan(duration: TimeInterval) {
        lastFullScanDuration = duration
    }
}
