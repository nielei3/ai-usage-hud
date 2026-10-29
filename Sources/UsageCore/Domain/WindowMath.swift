import Foundation

public enum WindowMath {
    public static func candidateCutoff(now: Date, clock: UsageClock) -> Date {
        let midnight = clock.calendar.startOfDay(for: now)
        let fiveHoursBack = now.addingTimeInterval(-5 * 3600)
        return min(midnight, fiveHoursBack)
    }

    public static func isToday(_ date: Date, now: Date, clock: UsageClock) -> Bool {
        clock.calendar.isDate(date, inSameDayAs: now)
    }

    public static func startOfDay(for date: Date, clock: UsageClock) -> Date {
        clock.calendar.startOfDay(for: date)
    }

    public static func isWithinFiveHours(_ date: Date, now: Date) -> Bool {
        date >= now.addingTimeInterval(-5 * 3600) && date <= now
    }

    public static func isWithinWeek(_ date: Date, now: Date) -> Bool {
        date >= now.addingTimeInterval(-7 * 24 * 3600) && date <= now
    }
}
