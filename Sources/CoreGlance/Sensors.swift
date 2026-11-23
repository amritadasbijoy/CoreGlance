import Foundation
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration

// Small, stateless readers built on public system APIs.
// Each returns nil when the data is not available, so the UI can say "n/a"
// instead of showing a made-up number.

enum Sensors {

    // MARK: CPU (raw tick counters; caller computes deltas)

    /// Per-core ticks: [user, system, idle, nice] for each core.
    static func cpuTicks() -> [[UInt32]]? {
        var numCPU: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &numCPU, &info, &count) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }
        let n = Int(CPU_STATE_MAX)
        return (0..<Int(numCPU)).map { core in
            (0..<n).map { UInt32(bitPattern: info[core * n + $0]) }
        }
    }

    // MARK: Memory

    struct Memory {
        var total: UInt64
        var used: UInt64        // app + wired + compressed (like Activity Monitor)
        var app: UInt64
        var wired: UInt64
        var compressed: UInt64
        var cached: UInt64
        var swapUsed: UInt64
        var pressure: Pressure
    }

    enum Pressure: String {
        case normal = "Normal", warning = "Warning", critical = "Critical", unknown = "Unknown"
    }

    static func memory() -> Memory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let ps = UInt64(pageSize)

        let app = (UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))) * ps
        let wired = UInt64(stats.wire_count) * ps
        let compressed = UInt64(stats.compressor_page_count) * ps
        let cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * ps

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        return Memory(total: ProcessInfo.processInfo.physicalMemory,
                      used: app + wired + compressed,
                      app: app, wired: wired, compressed: compressed, cached: cached,
                      swapUsed: swap.xsu_used,
                      pressure: memoryPressure())
    }

    /// Kernel's own memory pressure level (same source Activity Monitor uses).
    static func memoryPressure() -> Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unknown }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    // MARK: GPU (Apple Silicon exposes this in the IORegistry, no root needed)

    private static var gpuEntries: [io_object_t]?

    static func gpuUtilization() -> Double? {
        if gpuEntries == nil {
            var found: [io_object_t] = []
            var iter: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS {
                var entry = IOIteratorNext(iter)
                while entry != 0 { found.append(entry); entry = IOIteratorNext(iter) }   // kept for the app's lifetime
                IOObjectRelease(iter)
            }
            gpuEntries = found
        }
        var best: Double?
        for entry in gpuEntries ?? [] {
            if let perf = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let u = perf["Device Utilization %"] as? NSNumber {
                best = max(best ?? 0, u.doubleValue)
            }
        }
        return best
    }

    // MARK: CPU core types (efficiency / performance)

    /// true = performance core, indexed by logical CPU id. Empty when the Mac does not report it.
    static func performanceCoreFlags() -> [Bool] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [] }
        defer { IOObjectRelease(cpus) }
        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var byID: [Int: Bool] = [:]
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            let type = IORegistryEntryCreateCFProperty(entry, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data
            let id = IORegistryEntryCreateCFProperty(entry, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            if let first = type?.first, let id {
                byID[id.intValue] = first == UInt8(ascii: "P")
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        guard !byID.isEmpty, byID.keys.max() == byID.count - 1 else { return [] }
        return (0..<byID.count).map { byID[$0] ?? true }
    }

    // MARK: Battery

    struct Battery {
        var percent: Int
        var isCharging: Bool
        var onAC: Bool
        var cycles: Int?
        var designCapacity: Int?   // mAh
        var fullCapacity: Int?     // mAh, current max
        var condition: String?
        var minutesRemaining: Int?  // to empty, or to full while charging
        var adapterWatts: Int?
        var temperatureC: Double?
        var systemWatts: Double?    // what the Mac is using right now
        var chargerWatts: Double?  // what the charger is delivering right now
        var batteryWatts: Double?   // above zero: going into the battery; below: coming out
        var health: Int? { Calc.batteryHealth(fullCapacity: fullCapacity, designCapacity: designCapacity) }
    }

    static func battery() -> Battery? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        // Newer macOS versions keep some capacity keys only inside the nested "BatteryData" dictionary.
        let batteryData = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        func int(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue
            ?? (batteryData?[key] as? NSNumber)?.intValue
        }
        func bool(_ key: String) -> Bool {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool) ?? false
        }
        guard let cur = int("CurrentCapacity"), let max = int("MaxCapacity"), max > 0 else { return nil }

        // Battery condition text from the public power-source API ("Good", "Service Recommended", ...)
        var condition: String?
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                if let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                   let h = d[kIOPSBatteryHealthKey] as? String {
                    condition = h
                }
            }
        }

        let charging = bool("IsCharging")
        // 65535 means "still calculating"
        let minutes = int(charging ? "AvgTimeToFull" : "TimeRemaining").flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
        let watts = ((IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any])?[kIOPSPowerAdapterWattsKey] as? NSNumber)?.intValue
        // Reported in hundredths of a degree Celsius.
        let temp = int("Temperature").flatMap { $0 > 0 ? Double($0) / 100 : nil }

        // Live power figures. Undocumented, so every one of them is optional. Values are in
        // milliwatts; the battery figure is a signed number stored as an unsigned one.
        let telemetry = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        func power(_ key: String) -> Double? {
            Calc.watts(milliwatts: (telemetry?[key] as? NSNumber)?.int64Value)
        }

        return Battery(percent: Int((Double(cur) / Double(max) * 100).rounded()),
                       isCharging: charging,
                       onAC: bool("ExternalConnected"),
                       cycles: int("CycleCount"),
                       designCapacity: int("DesignCapacity"),
                       fullCapacity: int("AppleRawMaxCapacity") ?? (max > 100 ? max : nil),
                       condition: condition,
                       minutesRemaining: bool("ExternalConnected") && !charging ? nil : minutes,
                       adapterWatts: watts,
                       temperatureC: temp,
                       systemWatts: power("SystemLoad"),
                       chargerWatts: power("SystemPowerIn"),
                       batteryWatts: power("BatteryPower"))
    }

    // MARK: Disk

    static func disk() -> (total: Int64, free: Int64)? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                       .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity,
              let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return (Int64(total), free)
    }

    // MARK: Network

    /// The interface that carries the internet connection (the default route), e.g. "en0" for Wi-Fi
    /// or "utun4" for a full VPN. nil when the Mac is offline.
    static func internetInterface() -> String? {
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let info = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any],
               let name = info["PrimaryInterface"] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    /// Total bytes received and sent on one interface, or nil if it does not exist.
    /// Uses the 64-bit interface counters. The simpler getifaddrs() ones are 32-bit and wrap every 4 GB.
    static func networkBytes(interface: String) -> (rx: UInt64, tx: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

        var rx: UInt64 = 0, tx: UInt64 = 0
        var found = false
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                guard msgLen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    if if_indextoname(UInt32(h2.ifm_index), &name) != nil, String(cString: name) == interface {
                        rx += h2.ifm_data.ifi_ibytes
                        tx += h2.ifm_data.ifi_obytes
                        found = true
                    }
                }
                off += msgLen
            }
        }
        return found ? (rx, tx) : nil
    }

    // MARK: Processes

    struct ProcSample {
        let pid: Int32
        let cpuTimeNs: UInt64   // total user + system CPU time so far
        let memory: UInt64      // physical footprint (same as Activity Monitor "Memory")
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// Reads every process we are allowed to inspect. Processes owned by root
    /// (e.g. WindowServer) are skipped by macOS unless the app runs as root.
    static func processes() -> [ProcSample] {
        let cap = proc_listallpids(nil, 0)
        guard cap > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(cap) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard n > 0 else { return [] }

        var out: [ProcSample] = []
        out.reserveCapacity(Int(n))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard ok == 0 else { continue }
            // On Apple Silicon these times are in mach ticks; convert to nanoseconds.
            let ticks = info.ri_user_time + info.ri_system_time
            out.append(ProcSample(pid: pid,
                                  cpuTimeNs: ticks * timebase.numer / timebase.denom,
                                  memory: info.ri_phys_footprint))
        }
        return out
    }

    static func processName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            return (String(cString: buf) as NSString).lastPathComponent
        }
        var name = [CChar](repeating: 0, count: 64)
        proc_name(pid, &name, UInt32(name.count))
        let s = String(cString: name)
        return s.isEmpty ? "pid \(pid)" : s
    }

    // MARK: System info

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// The Mac's everyday name, e.g. "MacBook Pro (16-inch, 2023)". nil if the Mac does not report one.
    static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        // The value is a C string with a trailing zero byte.
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func loadAverage() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? l : []
    }
}
