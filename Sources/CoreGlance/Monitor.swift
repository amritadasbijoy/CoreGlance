import AppKit
import Combine
import UserNotifications

/// What the menu bar item shows. Kept separate from `Monitor` so the menu bar
/// only redraws when its own text changes.
@MainActor
final class BarModel: ObservableObject {
    @Published var image: NSImage?
    @Published var text = ""
}

/// Samples all sensors on one timer.
/// Fast metrics (CPU, RAM, GPU, network) every tick; slow ones (battery, disk) every 30 s;
/// processes only while the popup is open.
@MainActor
final class Monitor: ObservableObject {
    static let historyLength = 60

    /// Default values for every setting, shared with the @AppStorage properties in the views.
    static let defaults: [String: Any] = [
        "interval": 2.0, "showCPU": true, "showRAM": true, "showGPU": false, "showNet": false,
        "showTemp": false,
        "compactBar": true, "showProcesses": true, "showSensors": false, "speedBits": false, "alerts": false, "appearance": "system",
    ]

    // Not @Published on purpose: `sample()` sends one change notification per tick
    // (and only while the popup is open) instead of one per property.
    private(set) var cpu = Calc.CPUUsage(total: 0, user: 0, system: 0, cores: [])
    private(set) var cpuHistory: [Double] = []
    private(set) var memory: Sensors.Memory?
    private(set) var memHistory: [Double] = []
    private(set) var gpu: Double?
    private(set) var gpuHistory: [Double] = []
    private(set) var downSpeed: Double = 0   // bytes/s
    private(set) var upSpeed: Double = 0
    private(set) var downHistory: [Double] = []
    private(set) var battery: Sensors.Battery?
    private(set) var disk: (total: Int64, free: Int64)?
    private(set) var thermal: ProcessInfo.ThermalState = .nominal
    private(set) var loadAvg: [Double] = []
    private(set) var temperature: Double?   // hottest chip sensor, °C (optional feature)
    private(set) var fans: [Thermals.Fan] = []
    private(set) var usage = UsageLog()     // internet data used, per hour and per day
    var confirmingUsageReset = false { didSet { objectWillChange.send() } }

    struct ProcRow: Identifiable {
        let id: Int32       // pid
        let name: String
        let cpu: Double     // % of one core (can pass 100, like Activity Monitor)
        let memory: UInt64
    }
    private(set) var topByCPU: [ProcRow] = []
    private(set) var topByMemory: [ProcRow] = []

    let bar = BarModel()
    let chip = Sensors.sysctlString("machdep.cpu.brand_string") ?? "Unknown chip"
    /// Friendly name when the Mac reports one, otherwise Apple's model code (e.g. "Mac14,10").
    let model = Sensors.productName() ?? Sensors.sysctlString("hw.model") ?? "Mac"
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    /// true = performance core, per logical CPU. Empty if the Mac does not report core types.
    let performanceCores = Sensors.performanceCoreFlags()

    var popupOpen = false {
        didSet {
            guard popupOpen != oldValue else { return }
            prevProc = [:]
            if !popupOpen { confirmingUsageReset = false }
            if popupOpen {
                if wantsProcesses { sampleProcesses() }
                sampleThermals()
                battery = Sensors.battery()   // fresh power figures the moment the popup opens
                objectWillChange.send()
            }
        }
    }

    private let settings = UserDefaults.standard
    private var wantsProcesses: Bool { settings.bool(forKey: "showProcesses") }

    private var prevTicks: [[UInt32]]?
    private var prevNet: (rx: UInt64, tx: UInt64, time: Date)?
    private(set) var netInterface: String?   // interface carrying the internet connection
    private var lastInterfaceCheck = Date.distantPast
    private var prevProc: [Int32: UInt64] = [:]
    private var prevProcTime = Date()
    private var nameCache: [Int32: String] = [:]
    private var lastSlow = Date.distantPast
    private var lastBarKey = ""
    private var alerts = AlertTracker()
    private var timer: Timer?
    private var interval: Double = 0
    private var settingsObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?
    private var usageDirty = false
    private var lastUsageSave = Date()
    /// Snapshot runs are a second copy of the app; they must not write over the real log.
    private let usageWritable = ProcessInfo.processInfo.environment["COREGLANCE_SNAPSHOT"] == nil

    init() {
        settings.register(defaults: Self.defaults)
        usage = UsageStore.load()
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveUsage(force: true) }
        }
        applySettings()
        // Any settings change (refresh interval, menu bar options, ...) takes effect at once.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: settings, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applySettings() }
        }
    }

    private func applySettings() {
        let wanted = min(max(settings.double(forKey: "interval"), 1), 60)
        if wanted != interval {
            interval = wanted
            start()
        } else {
            updateBar()
            if popupOpen { objectWillChange.send() }
        }
    }

    private func start() {
        timer?.invalidate()
        sample()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        t.tolerance = interval * 0.2   // lets macOS batch wakeups -> less battery use
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func push(_ v: Double, _ arr: inout [Double]) {
        arr.append(v)
        if arr.count > Self.historyLength { arr.removeFirst(arr.count - Self.historyLength) }
    }

    func sample() {
        if popupOpen { objectWillChange.send() }

        if let ticks = Sensors.cpuTicks() {
            if let prev = prevTicks, let usage = Calc.cpuUsage(prev: prev, cur: ticks) {
                cpu = usage
                push(usage.total, &cpuHistory)
            }
            prevTicks = ticks
        }

        if let m = Sensors.memory() {
            memory = m
            push(Double(m.used) / Double(max(m.total, 1)) * 100, &memHistory)
        }

        gpu = Sensors.gpuUtilization()
        if let g = gpu { push(g, &gpuHistory) }

        sampleNetwork()
        thermal = ProcessInfo.processInfo.thermalState
        sampleThermals()

        if popupOpen {
            loadAvg = Sensors.loadAverage()
            if wantsProcesses { sampleProcesses() }
        }

        // Battery and disk change slowly; refresh them at once when the popup is open.
        if Date().timeIntervalSince(lastSlow) >= (popupOpen ? 10 : 30) {
            lastSlow = Date()
            battery = Sensors.battery()
            disk = Sensors.disk()
            checkAlerts()
        }

        updateBar()
    }

    private func sampleNetwork() {
        let now = Date()
        // Which interface is the internet connection can change (Wi-Fi to Ethernet, VPN on or off),
        // so look it up again every few seconds.
        if now.timeIntervalSince(lastInterfaceCheck) >= 5 {
            lastInterfaceCheck = now
            let current = Sensors.internetInterface()
            if current != netInterface {
                netInterface = current
                prevNet = nil   // counters of different interfaces cannot be compared
            }
        }
        guard let name = netInterface, let n = Sensors.networkBytes(interface: name) else {
            // Offline: show zero instead of the last measured speed.
            downSpeed = 0; upSpeed = 0; prevNet = nil
            push(0, &downHistory)
            return
        }
        if let p = prevNet {
            let dt = now.timeIntervalSince(p.time)
            downSpeed = Calc.rate(prev: p.rx, cur: n.rx, seconds: dt)
            upSpeed = Calc.rate(prev: p.tx, cur: n.tx, seconds: dt)
            push(downSpeed, &downHistory)
            let down = Calc.transferred(prev: p.rx, cur: n.rx), up = Calc.transferred(prev: p.tx, cur: n.tx)
            if down > 0 || up > 0 {
                usage.add(down: down, up: up, at: now)
                usageDirty = true
            }
        }
        prevNet = (n.rx, n.tx, now)
        saveUsage()
    }

    /// Writes the usage log at most once a minute, and only when it changed.
    private func saveUsage(force: Bool = false) {
        guard usageWritable, usageDirty, force || Date().timeIntervalSince(lastUsageSave) >= 60 else { return }
        usage.prune()
        UsageStore.save(usage)
        usageDirty = false
        lastUsageSave = Date()
    }

    func resetUsage() {
        usage = UsageLog()
        usageDirty = true
        confirmingUsageReset = false
        saveUsage(force: true)
    }

    /// Exact temperature and fan speeds: read only when something is showing them.
    private func sampleThermals() {
        let inPopup = popupOpen && settings.bool(forKey: "showSensors")
        if inPopup || settings.bool(forKey: "showTemp") { temperature = Thermals.chipTemperature() }
        if inPopup { fans = Thermals.fans() }
    }

    private func sampleProcesses() {
        let now = Date()
        let samples = Sensors.processes()
        let elapsedNs = now.timeIntervalSince(prevProcTime) * 1e9
        let first = prevProc.isEmpty

        var rows: [ProcRow] = []
        rows.reserveCapacity(samples.count)
        var alive = Set<Int32>()
        for s in samples {
            alive.insert(s.pid)
            var cpu = 0.0
            if let old = prevProc[s.pid] {
                if s.cpuTimeNs >= old {
                    if !first, elapsedNs > 0 { cpu = Double(s.cpuTimeNs - old) / elapsedNs * 100 }
                } else {
                    nameCache[s.pid] = nil   // CPU time went down: the pid was reused by a new process
                }
            }
            let name = nameCache[s.pid] ?? {
                let n = Sensors.processName(s.pid)
                nameCache[s.pid] = n
                return n
            }()
            rows.append(ProcRow(id: s.pid, name: name, cpu: cpu, memory: s.memory))
        }

        prevProc = Dictionary(samples.map { ($0.pid, $0.cpuTimeNs) }, uniquingKeysWith: { a, _ in a })
        prevProcTime = now
        nameCache = nameCache.filter { alive.contains($0.key) }   // forget exited processes

        topByMemory = Array(rows.sorted { $0.memory > $1.memory }.prefix(6))
        // First pass has no CPU delta yet; keep the old list until we have real numbers.
        if !first { topByCPU = Array(rows.sorted { $0.cpu > $1.cpu }.prefix(6)) }
    }

    // MARK: Menu bar

    private func updateBar() {
        let bits = settings.bool(forKey: "speedBits")
        var cells: [(String, String)] = []
        if settings.bool(forKey: "showCPU") { cells.append(("CPU", "\(Int(cpu.total))%")) }
        if settings.bool(forKey: "showRAM") {
            let pct = memory.map { Int(Double($0.used) / Double(max($0.total, 1)) * 100) } ?? 0
            cells.append(("RAM", "\(pct)%"))
        }
        if settings.bool(forKey: "showGPU") { cells.append(("GPU", gpu.map { "\(Int($0))%" } ?? "–")) }
        if settings.bool(forKey: "showTemp") {
            cells.append(("TEMP", temperature.map { Fmt.temperature($0, unit: false) } ?? "–"))
        }
        if settings.bool(forKey: "showNet") {
            cells.append(("↓" + Fmt.shortSpeed(downSpeed, bits: bits), "↑" + Fmt.shortSpeed(upSpeed, bits: bits)))
        }

        let compact = settings.bool(forKey: "compactBar")
        let text = cells.map { "\($0.0) \($0.1)" }.joined(separator: "  ")
        let key = (compact ? "c|" : "t|") + text
        guard key != lastBarKey else { return }   // nothing visible changed: skip the redraw
        lastBarKey = key
        bar.text = text
        bar.image = compact && !cells.isEmpty ? MenuBarImage.render(cells) : nil
    }

    // MARK: Alerts

    private func checkAlerts() {
        guard settings.bool(forKey: "alerts") else { return }
        let fired = alerts.evaluate([
            .memory: memory?.pressure == .critical,
            .disk: disk.map { $0.free < 10_000_000_000 } ?? false,
            .thermal: thermal == .serious || thermal == .critical,
        ])
        for kind in fired {
            switch kind {
            case .memory:
                Notifier.post("Memory pressure is critical", "Your Mac is running out of memory. Closing some apps will help.")
            case .disk:
                Notifier.post("Disk space is low", "Less than 10 GB is free on your startup disk.")
            case .thermal:
                Notifier.post("Your Mac is running hot", "macOS is slowing things down to cool off.")
            }
        }
    }
}

/// Draws the two-line menu bar layout with AppKit text drawing (much cheaper than rendering a SwiftUI view).
/// The result is a template image, so macOS colours it for light and dark menu bars.
enum MenuBarImage {
    private static let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
        .foregroundColor: NSColor.black,
    ]

    static func render(_ cells: [(String, String)]) -> NSImage {
        let gap: CGFloat = 5, minWidth: CGFloat = 24, height: CGFloat = 22
        func width(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: attrs).width) }
        // A minimum column width stops the bar from jumping around as numbers change.
        let widths = cells.map { max(minWidth, width($0.0), width($0.1)) }
        let total = widths.reduce(0, +) + gap * CGFloat(max(cells.count - 1, 0))

        let image = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (cell, w) in zip(cells, widths) {
                for (s, y) in [(cell.0, CGFloat(11)), (cell.1, CGFloat(1))] {
                    (s as NSString).draw(at: NSPoint(x: x + (w - width(s)) / 2, y: y), withAttributes: attrs)
                }
                x += w + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum Notifier {
    /// Notifications need a real app bundle; skip quietly when run as a bare binary (e.g. in tests).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
