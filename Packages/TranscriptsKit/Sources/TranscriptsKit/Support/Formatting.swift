import Foundation

public enum TimeFormat {
    /// "04:12" or "1:04:12".
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// "42 min", "1 h 12 min", "38 s".
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(localized: "\(max(total, 0)) s", comment: "seconds, short") }
        let minutes = (total + 30) / 60
        if minutes < 60 { return String(localized: "\(minutes) min", comment: "minutes, short") }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? String(localized: "\(hours) h", comment: "hours, short") : String(localized: "\(hours) h \(rest) min", comment: "hours and minutes, short")
    }

    /// The interface's language, with the user's region.
    private static var locale: Locale { AppLocale.current }

    /// "Heute", "Gestern", "Freitag, 2. Oktober", "12. März 2025".
    public static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Heute") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return String(localized: "Gestern") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return String(localized: "Morgen") }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar)
        return sameYear
            ? date.formatted(style.weekday(.wide).day().month(.wide))
            : date.formatted(style.day().month(.wide).year())
    }

    /// "Heute", "Gestern", "Fr" within the last week, else "2. Okt.".
    public static func compactDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Heute") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return String(localized: "Gestern") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days > 0 && days < 7 {
            return date.formatted(Date.FormatStyle(locale: locale).weekday(.wide))
        }
        return date.formatted(Date.FormatStyle(locale: locale).day().month(.abbreviated))
    }

    /// "10:00".
    public static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
    }

    /// "Montag, 5. Oktober · 10:00–10:42".
    public static func meetingLine(start: Date, duration: Double) -> String {
        let day = start.formatted(Date.FormatStyle(locale: locale).weekday(.wide).day().month(.wide))
        let end = start.addingTimeInterval(duration)
        return duration > 0 ? "\(day) · \(time(start))–\(time(end))" : "\(day) · \(time(start))"
    }

    /// "5. Okt. 2026".
    public static func shortDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).day().month(.abbreviated).year())
    }

    /// "Mi", "Fr" for dates this week, else "12.10.".
    public static func shortDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return time(date) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days < 7 && days > 0 {
            return date.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated)).replacingOccurrences(of: ".", with: "")
        }
        return date.formatted(Date.FormatStyle(locale: locale).day(.twoDigits).month(.twoDigits))
    }

    /// "in 12 Min.", "jetzt", "seit 5 Min.".
    public static func relative(to date: Date, now: Date = Date()) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded())
        if minutes == 0 { return String(localized: "jetzt", comment: "a meeting starts now") }
        if minutes > 0 {
            if minutes < 60 { return String(localized: "in \(minutes) Min.", comment: "a meeting starts in so many minutes") }
            return String(localized: "in \(minutes / 60) Std.", comment: "a meeting starts in so many hours")
        }
        let ago = -minutes
        if ago < 60 { return String(localized: "seit \(ago) Min.", comment: "a meeting has been running for so many minutes") }
        return String(localized: "seit \(ago / 60) Std.", comment: "a meeting has been running for so many hours")
    }

    public static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
