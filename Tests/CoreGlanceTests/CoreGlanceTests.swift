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
}
