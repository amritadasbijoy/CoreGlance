import Foundation

/// How much internet data this Mac has used, counted by CoreGlance itself.
///
/// macOS keeps no history of this, so the log starts on the day the feature first runs and
/// only grows while the app is running. It stays small: one total per hour for the last two
/// days and one per day for a little over a year. Nothing here leaves the Mac.
struct UsageLog: Codable, Equatable {
    struct Amount: Codable, Equatable {
        var down: UInt64 = 0
        var up: UInt64 = 0
        var total: UInt64 { down &+ up }
        static func + (a: Amount, b: Amount) -> Amount { Amount(down: a.down &+ b.down, up: a.up &+ b.up) }
    }

    static let hoursKept = 48
    static let daysKept = 400   // enough for "this year" and "last 12 months"

    /// Key: hours since 1970.
    private(set) var hours: [Int: Amount] = [:]
    /// Key: the local date as a number, 20261123 for 23 November 2026.
    private(set) var days: [Int: Amount] = [:]
    /// When counting started (first run, or the last reset).
    var since = Date()

    static func hourKey(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 3600).rounded(.down)) }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    mutating func add(down: UInt64, up: UInt64, at date: Date = Date(), calendar: Calendar = .current) {
        guard down > 0 || up > 0 else { return }
        let amount = Amount(down: down, up: up)
        hours[Self.hourKey(date), default: Amount()] = hours[Self.hourKey(date), default: Amount()] + amount
        let day = Self.dayKey(date, calendar: calendar)
        days[day, default: Amount()] = days[day, default: Amount()] + amount
    }

    /// Drops entries that are too old to be shown.
    mutating func prune(now: Date = Date(), calendar: Calendar = .current) {
        let oldestHour = Self.hourKey(now) - Self.hoursKept
        hours = hours.filter { $0.key > oldestHour }
        if let cutoff = calendar.date(byAdding: .day, value: -Self.daysKept, to: now) {
            let oldestDay = Self.dayKey(cutoff, calendar: calendar)
            days = days.filter { $0.key > oldestDay }
        }
    }

    // MARK: Totals

    func today(now: Date = Date(), calendar: Calendar = .current) -> Amount {
        days[Self.dayKey(now, calendar: calendar)] ?? Amount()
    }

    /// The calendar week that contains `now` (it starts on the day the Mac's region uses).
    func thisWeek(now: Date = Date(), calendar: Calendar = .current) -> Amount {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return today(now: now, calendar: calendar) }
        return (0..<7).reduce(Amount()) { sum, offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: week.start) else { return sum }
            return sum + (days[Self.dayKey(day, calendar: calendar)] ?? Amount())
        }
    }

    func thisMonth(now: Date = Date(), calendar: Calendar = .current) -> Amount {
        month(Self.dayKey(now, calendar: calendar) / 100)
    }

    func thisYear(now: Date = Date(), calendar: Calendar = .current) -> Amount {
        let year = Self.dayKey(now, calendar: calendar) / 10_000
        return days.reduce(Amount()) { $1.key / 10_000 == year ? $0 + $1.value : $0 }
    }

    /// `yearMonth` is 202611 for November 2026.
    func month(_ yearMonth: Int) -> Amount {
        days.reduce(Amount()) { $1.key / 100 == yearMonth ? $0 + $1.value : $0 }
    }

    // MARK: Series for the charts (oldest first)

    func lastHours(_ count: Int = 24, now: Date = Date()) -> [Amount] {
        let current = Self.hourKey(now)
        return (0..<count).map { hours[current - (count - 1 - $0)] ?? Amount() }
    }

    func lastDays(_ count: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> [Amount] {
        (0..<count).map { index in
            guard let day = calendar.date(byAdding: .day, value: index - (count - 1), to: now) else { return Amount() }
            return days[Self.dayKey(day, calendar: calendar)] ?? Amount()
        }
    }

    /// The months that have any data, newest first, at most `count` of them.
    func months(_ count: Int = 12) -> [(yearMonth: Int, amount: Amount)] {
        Set(days.keys.map { $0 / 100 }).sorted(by: >).prefix(count).map { ($0, month($0)) }
    }
}

/// Reads and writes the log as a small JSON file in Application Support.
enum UsageStore {
    static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CoreGlance", isDirectory: true)
            .appendingPathComponent("usage.json")
    }

    static func load() -> UsageLog {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let log = try? JSONDecoder().decode(UsageLog.self, from: data) else { return UsageLog() }
        return log
    }

    static func save(_ log: UsageLog) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(log) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("CoreGlance: could not save internet usage: \(error.localizedDescription)")
        }
    }
}
