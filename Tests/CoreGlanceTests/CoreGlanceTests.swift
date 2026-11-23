import XCTest
@testable import CoreGlance

final class CalcTests: XCTestCase {
    func testCPUUsage() {
        // core 0: 50 busy of 100 ticks; core 1: fully idle
        let prev: [[UInt32]] = [[100, 50, 1000, 0], [10, 10, 500, 0]]
        let cur: [[UInt32]] = [[130, 60, 1050, 10], [10, 10, 600, 0]]
        let u = Calc.cpuUsage(prev: prev, cur: cur)!
        XCTAssertEqual(u.cores[0], 50, accuracy: 0.001)
        XCTAssertEqual(u.cores[1], 0, accuracy: 0.001)
        XCTAssertEqual(u.total, 25, accuracy: 0.001)       // 50 busy of 200 ticks
        XCTAssertEqual(u.user, 20, accuracy: 0.001)        // user 30 + nice 10
        XCTAssertEqual(u.system, 5, accuracy: 0.001)
    }

    func testCPUUsageHandlesCounterWrap() {
        let prev: [[UInt32]] = [[UInt32.max - 4, 0, 0, 0]]
        let cur: [[UInt32]] = [[5, 0, 10, 0]]              // user wrapped: +10 ticks
        XCTAssertEqual(Calc.cpuUsage(prev: prev, cur: cur)!.total, 50, accuracy: 0.001)
    }

    func testCPUUsageRejectsBadInput() {
        XCTAssertNil(Calc.cpuUsage(prev: [[1, 1, 1, 1]], cur: [[1, 1, 1, 1], [1, 1, 1, 1]]))  // core count changed
        XCTAssertNil(Calc.cpuUsage(prev: [[1, 1, 1, 1]], cur: [[1, 1, 1, 1]]))                // no time passed
        XCTAssertNil(Calc.cpuUsage(prev: [], cur: []))
    }

    func testRate() {
        XCTAssertEqual(Calc.rate(prev: 1_000, cur: 3_000, seconds: 2), 1_000)
        XCTAssertEqual(Calc.rate(prev: 3_000, cur: 1_000, seconds: 2), 0)   // counter reset
        XCTAssertEqual(Calc.rate(prev: 0, cur: 100, seconds: 0), 0)
        // Above 4 GB: would have overflowed the old 32-bit counters.
        XCTAssertEqual(Calc.rate(prev: 5_000_000_000, cur: 6_000_000_000, seconds: 1), 1_000_000_000)
    }

    func testBatteryHealth() {
        XCTAssertEqual(Calc.batteryHealth(fullCapacity: 7893, designCapacity: 8694), 91)
        XCTAssertEqual(Calc.batteryHealth(fullCapacity: 9000, designCapacity: 8694), 100)  // capped
        XCTAssertNil(Calc.batteryHealth(fullCapacity: nil, designCapacity: 8694))
        XCTAssertNil(Calc.batteryHealth(fullCapacity: 100, designCapacity: 0))
    }

    func testAverage() {
        XCTAssertEqual(Calc.average([10, 20, 30]), 20)
        XCTAssertEqual(Calc.average([]), 0)
    }
}

final class FmtTests: XCTestCase {
    func testShortSpeedBytes() {
        XCTAssertEqual(Fmt.shortSpeed(0, bits: false), "0K")
        XCTAssertEqual(Fmt.shortSpeed(850_000, bits: false), "850K")
        XCTAssertEqual(Fmt.shortSpeed(1_200_000, bits: false), "1.2M")
        XCTAssertEqual(Fmt.shortSpeed(12_000_000, bits: false), "12M")
        XCTAssertEqual(Fmt.shortSpeed(-5, bits: false), "0K")
    }

    func testShortSpeedBits() {
        XCTAssertEqual(Fmt.shortSpeed(125_000, bits: true), "1.0M")        // 1 Mbps
        XCTAssertEqual(Fmt.shortSpeed(12_500_000, bits: true), "100M")
        XCTAssertEqual(Fmt.shortSpeed(250_000_000, bits: true), "2.0G")
    }

    func testSpeedBits() {
        XCTAssertEqual(Fmt.speed(125_000, bits: true), "1.0 Mbps")
        XCTAssertEqual(Fmt.speed(1_250, bits: true), "10 Kbps")
    }

    func testUptimeAndMinutes() {
        XCTAssertEqual(Fmt.uptime(3 * 3600 + 25 * 60), "3h 25m")
        XCTAssertEqual(Fmt.uptime(2 * 86400 + 5 * 3600), "2d 5h")
        XCTAssertEqual(Fmt.minutes(45), "45m")
        XCTAssertEqual(Fmt.minutes(135), "2h 15m")
    }
}

final class AlertTrackerTests: XCTestCase {
    func testFiresOnceWhenProblemStarts() {
        var t = AlertTracker()
        let now = Date()
        XCTAssertEqual(t.evaluate([.disk: true], now: now), [.disk])
        XCTAssertEqual(t.evaluate([.disk: true], now: now.addingTimeInterval(60)), [])   // still low: no repeat
    }

    func testCooldownStopsFlapping() {
        var t = AlertTracker()
        let now = Date()
        XCTAssertEqual(t.evaluate([.memory: true], now: now), [.memory])
        XCTAssertEqual(t.evaluate([.memory: false], now: now.addingTimeInterval(10)), [])
        XCTAssertEqual(t.evaluate([.memory: true], now: now.addingTimeInterval(20)), [])          // within 30 min
        XCTAssertEqual(t.evaluate([.memory: false], now: now.addingTimeInterval(30)), [])
        XCTAssertEqual(t.evaluate([.memory: true], now: now.addingTimeInterval(31 * 60)), [.memory])
    }

    func testKindsAreIndependent() {
        var t = AlertTracker()
        XCTAssertEqual(Set(t.evaluate([.memory: true, .thermal: true])), [.memory, .thermal])
        XCTAssertEqual(t.evaluate([.memory: true, .thermal: true, .disk: true]), [.disk])
    }
}

/// These read the real machine, so they only check that values are sane.
final class SensorTests: XCTestCase {
    func testCPUTicks() {
        let ticks = Sensors.cpuTicks()
        XCTAssertNotNil(ticks)
        XCTAssertEqual(ticks?.count, ProcessInfo.processInfo.processorCount)
        XCTAssertTrue(ticks?.allSatisfy { $0.count == 4 } ?? false)
    }

    func testMemory() throws {
        let m = try XCTUnwrap(Sensors.memory())
        XCTAssertEqual(m.total, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(m.used, 0)
        XCTAssertLessThanOrEqual(m.used, m.total)
    }

    func testDisk() throws {
        let d = try XCTUnwrap(Sensors.disk())
        XCTAssertGreaterThan(d.total, 0)
        XCTAssertLessThanOrEqual(d.free, d.total)
    }

    func testNetworkCountersNeverGoBackwards() throws {
        // A machine with no network (some CI runners) has no internet interface: nothing to check.
        guard let name = Sensors.internetInterface() else { return }
        let a = try XCTUnwrap(Sensors.networkBytes(interface: name))
        let b = try XCTUnwrap(Sensors.networkBytes(interface: name))
        XCTAssertGreaterThanOrEqual(b.rx, a.rx)
        XCTAssertGreaterThanOrEqual(b.tx, a.tx)
    }

    func testUnknownInterfaceGivesNil() {
        XCTAssertNil(Sensors.networkBytes(interface: "nosuch99"))
    }

    func testLoopbackIsNeverTheInternetInterface() {
        XCTAssertNotEqual(Sensors.internetInterface(), "lo0")
    }

    func testOptionalSensorsDoNotCrash() {
        // Any of these may be unavailable (desktop Mac, virtual machine, CI runner).
        _ = Sensors.gpuUtilization()
        _ = Sensors.battery()
        let flags = Sensors.performanceCoreFlags()
        XCTAssertTrue(flags.isEmpty || flags.count == ProcessInfo.processInfo.processorCount)
    }

    func testProductNameIsCleanWhenPresent() {
        // Not every Mac (or CI runner) reports one, but when it does it must be plain text.
        if let name = Sensors.productName() {
            XCTAssertFalse(name.isEmpty)
            XCTAssertFalse(name.contains("\0"))
        }
    }

    func testProcessesIncludeThisOne() {
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(Sensors.processes().contains { $0.pid == me })
        XCTAssertFalse(Sensors.processName(me).isEmpty)
    }

    // MARK: Internet usage

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2   // Monday
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testTransferred() {
        XCTAssertEqual(Calc.transferred(prev: 100, cur: 350), 250)
        XCTAssertEqual(Calc.transferred(prev: 350, cur: 100), 0)          // counter restarted
        XCTAssertEqual(Calc.transferred(prev: 0, cur: 1 << 50), 0)        // too large to be real
    }

    func testUsageTotals() {
        var log = UsageLog()
        let now = date(2026, 11, 25)                                      // a Wednesday
        log.add(down: 100, up: 10, at: now, calendar: utc)
        log.add(down: 50, up: 5, at: now, calendar: utc)                  // same hour, same day
        log.add(down: 1000, up: 0, at: date(2026, 11, 23), calendar: utc) // Monday, same week
        log.add(down: 7, up: 0, at: date(2026, 11, 22), calendar: utc)    // Sunday, the week before
        log.add(down: 3, up: 0, at: date(2026, 10, 30), calendar: utc)    // last month
        log.add(down: 9, up: 0, at: date(2025, 12, 31), calendar: utc)    // last year

        XCTAssertEqual(log.today(now: now, calendar: utc), .init(down: 150, up: 15))
        XCTAssertEqual(log.thisWeek(now: now, calendar: utc).down, 1150)
        XCTAssertEqual(log.thisMonth(now: now, calendar: utc).down, 1157)
        XCTAssertEqual(log.thisYear(now: now, calendar: utc).down, 1160)
        XCTAssertEqual(log.months().map(\.yearMonth), [202611, 202610, 202512])
        XCTAssertEqual(log.months().first?.amount.down, 1157)
    }

    func testUsageSeries() {
        var log = UsageLog()
        let now = date(2026, 11, 25, 12)
        log.add(down: 5, up: 0, at: now, calendar: utc)
        log.add(down: 7, up: 0, at: date(2026, 11, 25, 9), calendar: utc)
        log.add(down: 11, up: 0, at: date(2026, 11, 20), calendar: utc)

        let hours = log.lastHours(24, now: now)
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours[23].down, 5)
        XCTAssertEqual(hours[20].down, 7)
        let days = log.lastDays(30, now: now, calendar: utc)
        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(days[29].down, 12)
        XCTAssertEqual(days[24].down, 11)
    }

    func testUsagePruneAndRoundTrip() throws {
        var log = UsageLog()
        let now = date(2026, 11, 25)
        log.add(down: 1, up: 1, at: now, calendar: utc)
        log.add(down: 2, up: 2, at: date(2026, 11, 20), calendar: utc)    // older than 48 hours
        log.add(down: 3, up: 3, at: date(2025, 1, 1), calendar: utc)      // older than 400 days
        log.prune(now: now, calendar: utc)

        XCTAssertEqual(log.hours.count, 1)
        XCTAssertEqual(Set(log.days.keys), [20261125, 20261120])
        let copy = try JSONDecoder().decode(UsageLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(copy.days, log.days)
        XCTAssertEqual(copy.hours, log.hours)
    }

    func testUsageFormatting() {
        XCTAssertEqual(Fmt.month(202611), "Nov 2026")
        XCTAssertEqual(Fmt.data(2_500_000_000), "2.5 GB")
    }

    // MARK: Updates

    func testVersionComparison() {
        XCTAssertTrue(Calc.isNewer("1.0.7", than: "1.0.6"))
        XCTAssertTrue(Calc.isNewer("1.0.10", than: "1.0.9"))      // numbers, not text
        XCTAssertTrue(Calc.isNewer("1.1", than: "1.0.9"))
        XCTAssertFalse(Calc.isNewer("1.0.6", than: "1.0.6"))
        XCTAssertFalse(Calc.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Calc.isNewer("1.0.5", than: "1.0.6"))
        XCTAssertFalse(Calc.isNewer("2.0.0", than: "0.0.0-dev"))  // development build: never offer
        XCTAssertFalse(Calc.isNewer("latest", than: "1.0.6"))
    }

    func testReleaseVersionFromGitHubAnswer() {
        XCTAssertEqual(Calc.releaseVersion(fromJSON: Data(#"{"tag_name":"v1.0.7","name":"x"}"#.utf8)), "1.0.7")
        XCTAssertNil(Calc.releaseVersion(fromJSON: Data(#"{"message":"Not Found"}"#.utf8)))
        XCTAssertNil(Calc.releaseVersion(fromJSON: Data(#"{"tag_name":"nightly"}"#.utf8)))
        XCTAssertNil(Calc.releaseVersion(fromJSON: Data("not json".utf8)))
    }

    // MARK: Battery power

    func testWatts() {
        XCTAssertEqual(Calc.watts(milliwatts: 11343), 11.343)
        // A discharging battery reports a negative number stored as an unsigned one.
        XCTAssertEqual(Calc.watts(milliwatts: Int64(bitPattern: 18446744073709542877)), -8.739)
        XCTAssertNil(Calc.watts(milliwatts: nil))
        XCTAssertNil(Calc.watts(milliwatts: 9_000_000))
        XCTAssertEqual(Fmt.watts(8.739), "8.7 W")
        XCTAssertEqual(Fmt.watts(112.4), "112 W")
    }

    // MARK: Temperature and fans

    func testTemperatureFormatting() {
        XCTAssertEqual(Fmt.temperature(40.6, fahrenheit: false), "41 °C")
        XCTAssertEqual(Fmt.temperature(100, fahrenheit: true), "212 °F")
        XCTAssertEqual(Fmt.temperature(40.6, unit: false, fahrenheit: false), "41°")
    }

    func testChipSensorNames() {
        XCTAssertTrue(Thermals.isChipSensor("PMU tdie3"))
        XCTAssertTrue(Thermals.isChipSensor("pACC MTR Temp Sensor2"))
        XCTAssertFalse(Thermals.isChipSensor("PMU tcal"))
        XCTAssertFalse(Thermals.isChipSensor("gas gauge battery"))
        XCTAssertFalse(Thermals.isChipSensor("NAND CH0 temp"))
    }

    func testSMCBlockHasTheDriverLayout() {
        XCTAssertEqual(MemoryLayout<Thermals.SMCData>.size, 80)
        XCTAssertEqual(MemoryLayout<Thermals.SMCData>.offset(of: \.dataSize), 28)
        XCTAssertEqual(MemoryLayout<Thermals.SMCData>.offset(of: \.command), 42)
        XCTAssertEqual(MemoryLayout<Thermals.SMCData>.offset(of: \.bytes), 48)
    }

    func testThermalReadingsAreSaneWhenPresent() {
        if let t = Thermals.chipTemperature() { XCTAssertTrue((1..<150).contains(t)) }
        for fan in Thermals.fans() { XCTAssertTrue(fan.rpm >= 0 && fan.rpm < 20_000) }
    }
}
