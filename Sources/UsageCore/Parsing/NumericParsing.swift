import Foundation

/// Shared safe Int(Double) conversion. Int(Double) traps outside
/// ±9.2e18 — huge/garbage counters (e.g. 1e19) must clamp to 0, never
/// crash the menu-bar app.
public enum NumericParsing {
    public static func int(_ d: Double) -> Int {
        d.isFinite && d >= 0 && d < 9.2e18 ? Int(d) : 0
    }

    public static func int(_ raw: Any?) -> Int {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return int(d) }
        if let s = raw as? String, let i = Int(s) { return i }
        return 0
    }

    public static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double, d.isFinite, d.rounded() == d,
           d >= Double(Int.min), d < 9.22e18 {
            return Int(d)
        }
        if let s = raw as? String, let i = Int(s) { return i }
        return nil
    }

    public static func double(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String, let d = Double(s) { return d }
        return nil
    }

    public static func percent(_ raw: Any?) -> Double? {
        guard let value = double(raw), value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }
}
