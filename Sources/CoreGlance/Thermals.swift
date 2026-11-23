import Foundation
import IOKit

// macOS has no public API for exact temperatures or fan speeds. This file reads them through
// two undocumented interfaces: the HID sensor services (temperature) and the SMC (fans).
// That is why the feature is optional and off by default, and why every reading can be nil.

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

enum Thermals {
    struct Fan: Equatable {
        let rpm: Double
        let max: Double   // 0 when the Mac does not report it
    }

    // MARK: Temperature

    private static let temperatureEvent: Int64 = 15   // kIOHIDEventTypeTemperature
    private static var hidClient: AnyObject?
    private static var chipSensors: [AnyObject]?

    /// Sensors that sit on the chip itself ("PMU tdie3" on newer chips, "pACC MTR Temp Sensor2" on M1).
    static func isChipSensor(_ name: String) -> Bool {
        name.contains("tdie") || name.contains("ACC MTR Temp")
    }

    /// Hottest chip sensor in °C, or nil when this Mac does not expose any.
    static func chipTemperature() -> Double? {
        if chipSensors == nil {
            var found: [AnyObject] = []
            if let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() {
                // Usage page 0xff00, usage 5 = Apple's temperature sensors.
                _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
                let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
                found = services.filter {
                    let name = IOHIDServiceClientCopyProperty($0, "Product" as CFString)?.takeRetainedValue() as? String
                    return name.map(isChipSensor) ?? false
                }
                hidClient = client   // kept, with the sensors, for the app's lifetime
            }
            chipSensors = found
        }
        var best: Double?
        for sensor in chipSensors ?? [] {
            guard let event = IOHIDServiceClientCopyEvent(sensor, temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let value = IOHIDEventGetFloatValue(event, Int32(temperatureEvent << 16))
            if value > 0, value < 150 { best = max(best ?? 0, value) }   // ignore sensors that report nonsense
        }
        return best
    }

    // MARK: Fans (SMC)

    /// The 80-byte request/reply block of the AppleSMC driver.
    struct SMCData {
        var key: UInt32 = 0
        var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var limits: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)   // the driver's struct is padded here
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private static var smc: io_connect_t?    // 0 = could not open
    private static var fanMax: [Double]?     // one entry per fan

    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private static func smcCall(_ input: inout SMCData) -> SMCData? {
        if smc == nil {
            var connection: io_connect_t = 0
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
            if service != 0 {
                if IOServiceOpen(service, mach_task_self_, 0, &connection) != kIOReturnSuccess { connection = 0 }
                IOObjectRelease(service)
            }
            smc = connection
        }
        guard let connection = smc, connection != 0 else { return nil }
        var output = SMCData()
        var size = MemoryLayout<SMCData>.size
        let status = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCData>.size, &output, &size)
        return status == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    /// Reads one SMC key: its type code and raw bytes.
    private static func smcRead(_ key: String) -> (type: UInt32, bytes: [UInt8])? {
        var ask = SMCData()
        ask.key = code(key)
        ask.command = 9   // read key info
        guard let info = smcCall(&ask), info.dataSize > 0, info.dataSize <= 32 else { return nil }
        var read = SMCData()
        read.key = code(key)
        read.dataSize = info.dataSize
        read.command = 5   // read bytes
        guard let reply = smcCall(&read) else { return nil }
        return (info.dataType, withUnsafeBytes(of: reply.bytes) { Array($0.prefix(Int(info.dataSize))) })
    }

    private static func smcFloat(_ key: String) -> Double? {
        guard let value = smcRead(key), value.type == code("flt "), value.bytes.count == 4 else { return nil }
        let number = value.bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        return number.isFinite && number >= 0 ? Double(number) : nil
    }

    /// Current speed of every fan. Empty on Macs without fans, or when the SMC cannot be read.
    static func fans() -> [Fan] {
        if fanMax == nil {
            let count = min(Int(smcRead("FNum")?.bytes.first ?? 0), 8)
            fanMax = (0..<count).map { smcFloat("F\($0)Mx") ?? 0 }
        }
        return (fanMax ?? []).enumerated().compactMap { index, max in
            smcFloat("F\(index)Ac").map { Fan(rpm: $0, max: max) }
        }
    }
}
