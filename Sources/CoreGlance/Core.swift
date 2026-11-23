import Foundation

// Pure logic with no system calls, so it can be unit tested.

/// Shown in the popup's settings panel. Leave a value empty to hide it.
enum AppInfo {
    static let developerName = "Amrita Chandra Das"
    static let websites: [(title: String, url: String)] = [
        ("amrita.bd", "https://amrita.bd"),
        ("techistbd.com", "https://techistbd.com"),
    ]
    static let sourceURL = "https://github.com/amritadasbijoy/CoreGlance"
}

enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .memory)
    }
    static func disk(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    /// Internet data used, in the decimal units providers bill in (1 GB = 1000 MB).
    static func data(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .file)
    }

    /// Full speed text for the popup. `bytesPerSec` is always bytes; `bits` picks the display unit.
    static func speed(_ bytesPerSec: Double, bits: Bool) -> String {
        if bits {
            let b = max(0, bytesPerSec) * 8
            switch b {
            case ..<1_000: return "\(Int(b)) bps"
            case ..<1_000_000: return String(format: "%.0f Kbps", b / 1_000)
            case ..<1_000_000_000: return String(format: "%.1f Mbps", b / 1_000_000)
            default: return String(format: "%.2f Gbps", b / 1_000_000_000)
            }
        }
        return ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSec)), countStyle: .file) + "/s"
    }

    /// Compact speed for the menu bar, e.g. "850K", "1.2M", "12M".
    static func shortSpeed(_ bytesPerSec: Double, bits: Bool) -> String {
        let v = max(0, bytesPerSec) * (bits ? 8 : 1)
        switch v {
        case ..<1_000: return "0K"
        case ..<1_000_000: return "\(Int(v / 1_000))K"
        case ..<10_000_000: return String(format: "%.1fM", v / 1_000_000)
        case ..<1_000_000_000: return "\(Int(v / 1_000_000))M"
        default: return String(format: "%.1fG", v / 1_000_000_000)
        }
    }

    /// The unit picked in System Settings > General > Language & Region > Temperature.
    static var prefersFahrenheit: Bool {
        if let unit = UserDefaults.standard.string(forKey: "AppleTemperatureUnit") { return unit == "Fahrenheit" }
        return Locale.current.measurementSystem == .us
    }

    /// "41 °C", or "41°" for the menu bar.
    static func temperature(_ celsius: Double, unit: Bool = true, fahrenheit: Bool = prefersFahrenheit) -> String {
        let value = Int((fahrenheit ? celsius * 9 / 5 + 32 : celsius).rounded())
        return unit ? "\(value) °\(fahrenheit ? "F" : "C")" : "\(value)°"
    }

    /// "8.7 W", or "112 W" from 100 up.
    static func watts(_ w: Double) -> String {
        abs(w) >= 100 ? "\(Int(w.rounded())) W" : String(format: "%.1f W", w)
    }

    /// "Nov 2026" for 202611.
    static func month(_ yearMonth: Int) -> String {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let m = yearMonth % 100
        return (1...12).contains(m) ? "\(names[m - 1]) \(yearMonth / 100)" : "\(yearMonth)"
    }

    static func uptime(_ s: TimeInterval) -> String {
        let d = Int(s) / 86400, h = Int(s) % 86400 / 3600, m = Int(s) % 3600 / 60
        return d > 0 ? "\(d)d \(h)h" : "\(h)h \(m)m"
    }

    static func minutes(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

enum Calc {
    struct CPUUsage: Equatable {
        var total: Double, user: Double, system: Double
        var cores: [Double]
    }

    /// CPU usage in percent from two tick snapshots. Each core is [user, system, idle, nice].
    static func cpuUsage(prev: [[UInt32]], cur: [[UInt32]]) -> CPUUsage? {
        guard prev.count == cur.count, !cur.isEmpty else { return nil }
        var cores: [Double] = []
        var sumUser: UInt64 = 0, sumSys: UInt64 = 0, sumAll: UInt64 = 0
        for (c, p) in zip(cur, prev) {
            guard c.count >= 4, p.count >= 4 else { return nil }
            // &- handles the 32-bit tick counters wrapping around.
            let user = UInt64(c[0] &- p[0]) + UInt64(c[3] &- p[3])
            let sys = UInt64(c[1] &- p[1])
            let idle = UInt64(c[2] &- p[2])
            let all = user + sys + idle
            cores.append(all > 0 ? Double(user + sys) / Double(all) * 100 : 0)
            sumUser += user; sumSys += sys; sumAll += all
        }
        guard sumAll > 0 else { return nil }
        let user = Double(sumUser) / Double(sumAll) * 100
        let sys = Double(sumSys) / Double(sumAll) * 100
        return CPUUsage(total: user + sys, user: user, system: sys, cores: cores)
    }

    /// Bytes per second between two counter readings. A counter that went backwards
    /// (interface reset) gives 0 instead of a huge spike.
    static func rate(prev: UInt64, cur: UInt64, seconds: Double) -> Double {
        guard seconds > 0, cur >= prev else { return 0 }
        return Double(cur - prev) / seconds
    }

    /// Milliwatts from the battery's power report to watts; nil when missing or absurd.
    static func watts(milliwatts: Int64?) -> Double? {
        guard let milliwatts, abs(milliwatts) < 500_000 else { return nil }
        return Double(milliwatts) / 1000
    }

    /// Bytes moved between two readings of a counter. Zero when the counter went backwards
    /// (it restarts after a reboot or a reconnect) or the jump is too large to be real.
    static func transferred(prev: UInt64, cur: UInt64, limit: UInt64 = 1 << 40) -> UInt64 {
        guard cur >= prev, cur - prev <= limit else { return 0 }
        return cur - prev
    }

    static func batteryHealth(fullCapacity: Int?, designCapacity: Int?) -> Int? {
        guard let f = fullCapacity, let d = designCapacity, d > 0, f > 0 else { return nil }
        return min(100, Int((Double(f) / Double(d) * 100).rounded()))
    }

    static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

/// Decides when an alert should fire: only when a problem starts (not on every tick),
/// and not again for the same problem within `cooldown`.
struct AlertTracker {
    enum Kind: String, CaseIterable { case memory, disk, thermal }

    var cooldown: TimeInterval = 30 * 60
    private var active: Set<Kind> = []
    private var lastFired: [Kind: Date] = [:]

    mutating func evaluate(_ conditions: [Kind: Bool], now: Date = Date()) -> [Kind] {
        var fire: [Kind] = []
        for kind in Kind.allCases {
            let on = conditions[kind] ?? false
            if on, !active.contains(kind) {
                if let last = lastFired[kind], now.timeIntervalSince(last) < cooldown {
                    // still cooling down: stay quiet
                } else {
                    fire.append(kind)
                    lastFired[kind] = now
                }
            }
            if on { active.insert(kind) } else { active.remove(kind) }
        }
        return fire
    }
}
