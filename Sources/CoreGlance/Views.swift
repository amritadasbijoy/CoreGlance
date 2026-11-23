import SwiftUI

// MARK: Theme
//
// Design rules: neutral surfaces and text, one accent (the green of the app icon) used
// for the main chart only, and amber/red only when a value needs attention.
// Spacing sits on a 4-point grid.

enum Theme {
    /// A colour with separate light and dark values.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let accent = dynamic(light: 0x0A7F52, dark: 0x3DDC97)
    static let warning = dynamic(light: 0x946000, dark: 0xE8AE45)
    static let critical = dynamic(light: 0xBF352B, dark: 0xF26B5E)

    static let surface = Color.primary.opacity(0.05)    // cards
    static let hairline = Color.primary.opacity(0.08)   // card borders, chart grid
    static let track = Color.primary.opacity(0.10)      // empty part of a meter
    static let fill = Color.primary.opacity(0.40)       // neutral bars

    static let title = Font.system(size: 13, weight: .medium)
    static let label = Font.system(size: 11)
    static let value = Font.system(size: 12).monospacedDigit()
    static let figure = Font.system(size: 28, weight: .regular).monospacedDigit()

    /// nil while a percentage is in the normal range, so normal values stay neutral.
    static func alert(_ percent: Double, warnAt: Double = 85, criticalAt: Double = 95) -> Color? {
        percent >= criticalAt ? critical : percent >= warnAt ? warning : nil
    }
}

// MARK: Popup

struct PopupView: View {
    @ObservedObject var monitor: Monitor
    @AppStorage("showSettings") private var showSettings = false
    @AppStorage("showProcesses") private var showProcesses = true
    @AppStorage("showSensors") private var showSensors = false
    @AppStorage("procSortByMemory") private var procSortByMemory = false
    @AppStorage("speedBits") private var speedBits = false
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showSettings {
                // Settings are their own page, so the popup never grows taller than the screen.
                HStack {
                    Button { showSettings = false } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Text("Settings").font(Theme.title)
                    Spacer()
                    Label("Back", systemImage: "chevron.left").hidden()   // keeps the title centred
                }
                .padding(.bottom, 4)
                SettingsView()
            } else {
                header.padding(.bottom, 4)
                cpuCard
                memoryCard
                gpuCard
                if showSensors { sensorsCard }
                HStack(spacing: 8) {
                    networkCard
                    diskCard
                }
                .fixedSize(horizontal: false, vertical: true)
                batteryCard
                if showProcesses { processCard }
            }
            footer.padding(.top, 4)
            AboutLine()   // developer credit, on every page
        }
        .padding(16)
        .frame(width: 340)
        // macOS does not shrink a menu bar popup when its content gets shorter (for example
        // going from the main page to settings), which leaves blank bands. Measure the
        // content and size the window to it.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { PopupWindow.fit(height: geo.size.height) }
                .onChange(of: geo.size.height) { _, height in PopupWindow.fit(height: height) }
        })
        // The popup is this app's only window. While it is closed the monitor skips
        // the process scan and does not refresh these views at all.
        .onAppear { monitor.popupOpen = true; PopupAppearance.apply(appearance) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            monitor.popupOpen = true
            PopupAppearance.apply(appearance)
        }
        .onChange(of: appearance) { _, new in PopupAppearance.apply(new) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            monitor.popupOpen = false
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.chip).font(.system(size: 15, weight: .medium))
                Text("\(monitor.model) · up \(Fmt.uptime(ProcessInfo.processInfo.systemUptime))")
                    .font(Theme.label).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer()
            ThermalStatus(state: monitor.thermal).fixedSize()
        }
    }

    // The one large chart on the screen.
    private var cpuCard: some View {
        let cpu = monitor.cpu
        let flags = monitor.performanceCores.count == cpu.cores.count ? monitor.performanceCores : []
        return Card {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("CPU").font(Theme.title)
                    Text("\(Int(cpu.total))%").font(Theme.figure)
                        .foregroundStyle(Theme.alert(cpu.total) ?? .primary)
                }
                Spacer()
                HStack(spacing: 16) {
                    Stat("User", "\(Int(cpu.user))%", alignment: .trailing)
                    Stat("System", "\(Int(cpu.system))%", alignment: .trailing)
                    if monitor.loadAvg.count == 3 {
                        Stat("Load", String(format: "%.1f", monitor.loadAvg[0]), alignment: .trailing)
                    }
                }
                .fixedSize()
                .padding(.bottom, 4)
            }
            Sparkline(values: monitor.cpuHistory, maxValue: 100, color: Theme.accent, grid: true)
                .frame(height: 56)
            if flags.contains(false), flags.contains(true) {
                // Efficiency cores first, a gap, then performance cores.
                let e = cpu.cores.indices.filter { !flags[$0] }.map { cpu.cores[$0] }
                let p = cpu.cores.indices.filter { flags[$0] }.map { cpu.cores[$0] }
                CoreBars(values: e + p, gapAfter: e.count)
                HStack {
                    Text("Efficiency \(Int(Calc.average(e)))%")
                    Spacer()
                    Text("Performance \(Int(Calc.average(p)))%")
                }
                .font(Theme.label.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                CoreBars(values: cpu.cores)
            }
        }
    }

    private var memoryCard: some View {
        let m = monitor.memory
        let total = Double(max(m?.total ?? 1, 1))
        let pct = m.map { Double($0.used) / total * 100 } ?? 0
        return Card {
            HStack {
                Text("Memory").font(Theme.title)
                Spacer()
                if let m {
                    StatusDot(color: pressureColor(m.pressure))
                    Text("Pressure \(m.pressure.rawValue.lowercased())")
                        .font(Theme.label).foregroundStyle(.secondary)
                }
            }
            if let m {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Fmt.bytes(m.used)) of \(Fmt.bytes(m.total))").font(Theme.value)
                    Spacer()
                    Text("\(Int(pct))%").font(Theme.value).foregroundStyle(.secondary)
                }
                // What the used memory is made of, darkest first.
                SegmentBar(segments: [
                    (Double(m.app) / total, Color.primary.opacity(0.62)),
                    (Double(m.wired) / total, Color.primary.opacity(0.38)),
                    (Double(m.compressed) / total, Color.primary.opacity(0.20)),
                ])
                HStack(spacing: 8) {
                    Stat("App", Fmt.bytes(m.app), swatch: Color.primary.opacity(0.62))
                    Stat("Wired", Fmt.bytes(m.wired), swatch: Color.primary.opacity(0.38))
                    Stat("Compressed", Fmt.bytes(m.compressed), swatch: Color.primary.opacity(0.20))
                    Stat("Swap", Fmt.bytes(m.swapUsed))
                }
            } else {
                Text("Not available").font(Theme.label).foregroundStyle(.secondary)
            }
        }
    }

    private var gpuCard: some View {
        Card {
            HStack(spacing: 12) {
                Text("GPU").font(Theme.title)
                if let gpu = monitor.gpu {
                    Sparkline(values: monitor.gpuHistory, maxValue: 100, color: Theme.fill).frame(height: 20)
                    Text("\(Int(gpu))%").font(Theme.value)
                        .foregroundStyle(Theme.alert(gpu) ?? .primary)
                        .frame(minWidth: 36, alignment: .trailing)
                } else {
                    Spacer()
                    Text("Not reported by this Mac").font(Theme.label).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var networkCard: some View {
        Card(fillHeight: true) {
            HStack {
                Text("Network").font(Theme.title)
                Spacer()
                Text(monitor.netInterface == nil ? "Offline" : "Internet")
                    .font(Theme.label).foregroundStyle(.secondary)
                    .help(monitor.netInterface.map { "Measured on \($0), the interface that carries your internet connection" }
                          ?? "No internet connection")
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(Fmt.speed(monitor.downSpeed, bits: speedBits)).font(Theme.value)
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.up").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(Fmt.speed(monitor.upSpeed, bits: speedBits)).font(Theme.value)
            }
            Sparkline(values: monitor.downHistory, maxValue: nil, color: Theme.fill).frame(height: 20)
        }
    }

    private var diskCard: some View {
        let d = monitor.disk
        let total = Double(max(d?.total ?? 1, 1))
        let usedPct = d.map { Double($0.total - $0.free) / total * 100 } ?? 0
        // Judge by free space, not by percentage alone: 8% of a large disk is still a lot.
        let alert: Color? = d.map { $0.free < 10_000_000_000 ? Theme.critical : $0.free < 25_000_000_000 ? Theme.warning : nil } ?? nil
        return Card(fillHeight: true) {
            HStack {
                Text("Disk").font(Theme.title)
                Spacer()
                if d != nil { Text("\(Int(usedPct))%").font(Theme.value).foregroundStyle(alert ?? .secondary) }
            }
            if let d {
                Text("\(Fmt.disk(d.free)) free").font(Theme.value)
                Text("of \(Fmt.disk(d.total))").font(Theme.label).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Meter(fraction: usedPct / 100, color: alert ?? Theme.fill)
            } else {
                Text("Not available").font(Theme.label).foregroundStyle(.secondary)
            }
        }
    }

    // Optional: exact chip temperature and fan speeds.
    private var sensorsCard: some View {
        Card {
            HStack {
                Text("Temperature").font(Theme.title)
                Spacer()
                Text(monitor.temperature.map { Fmt.temperature($0) } ?? "Not available")
                    .font(Theme.value).foregroundStyle(monitor.temperature == nil ? .secondary : .primary)
            }
            if monitor.fans.isEmpty {
                Text("No fan speed reported").font(Theme.label).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 16) {
                    ForEach(Array(monitor.fans.enumerated()), id: \.offset) { index, fan in
                        VStack(alignment: .leading, spacing: 4) {
                            Stat(monitor.fans.count == 1 ? "Fan" : "Fan \(index + 1)", "\(Int(fan.rpm)) rpm")
                            if fan.max > 0 { Meter(fraction: fan.rpm / fan.max, color: Theme.fill) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var batteryCard: some View {
        if let b = monitor.battery {
            let alert: Color? = b.isCharging || b.onAC ? nil : (b.percent <= 10 ? Theme.critical : b.percent <= 20 ? Theme.warning : nil)
            Card {
                HStack {
                    Text("Battery").font(Theme.title)
                    Spacer()
                    Text(b.isCharging ? "Charging" : (b.onAC ? "Plugged in" : "On battery"))
                        .font(Theme.label).foregroundStyle(.secondary)
                    Text("\(b.percent)%").font(Theme.value).foregroundStyle(alert ?? .primary)
                }
                Meter(fraction: Double(b.percent) / 100, color: alert ?? Theme.fill)
                HStack(spacing: 8) {
                    Stat("Health", b.health.map { "\($0)%" } ?? "–")
                    Stat("Cycles", b.cycles.map(String.init) ?? "–")
                    if let minutes = b.minutesRemaining {
                        Stat(b.isCharging ? "Full in" : "Time left", Fmt.minutes(minutes))
                    } else if let f = b.fullCapacity {
                        Stat("Capacity", "\(f) mAh")
                    }
                    if b.onAC, let w = b.adapterWatts {
                        Stat("Charger", "\(w) W")
                    } else if let t = b.temperatureC {
                        Stat("Temperature", Fmt.temperature(t))
                    }
                }
            }
        }
    }

    private var processCard: some View {
        let rows = procSortByMemory ? monitor.topByMemory : monitor.topByCPU
        return Card {
            HStack {
                Text("Top processes").font(Theme.title)
                Spacer()
                Segmented(options: [(false, "CPU"), (true, "Memory")], selection: $procSortByMemory)
                    .frame(width: 120)
            }
            if rows.isEmpty {
                Text("Measuring").font(Theme.label).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(rows) { p in
                        HStack(spacing: 8) {
                            Text(p.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(String(format: "%.1f%%", p.cpu))
                                .foregroundStyle(procSortByMemory ? .secondary : .primary)
                                .frame(width: 52, alignment: .trailing)
                            Text(Fmt.bytes(p.memory))
                                .foregroundStyle(procSortByMemory ? .primary : .secondary)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .font(Theme.value)
                        .help("Process ID \(p.id)")
                    }
                }
            }
            Text("Shows your own apps, not system processes")
                .font(Theme.label).foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack {
            Button { showSettings.toggle() } label: {
                Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Spacer()
            Text("CoreGlance \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .font(Theme.label).foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
    }

    private func pressureColor(_ p: Sensors.Pressure) -> Color {
        switch p {
        case .normal: return Theme.accent
        case .warning: return Theme.warning
        case .critical: return Theme.critical
        case .unknown: return Theme.fill
        }
    }
}

@MainActor
enum PopupWindow {
    /// Resizes the popup window to the content height, keeping its top edge under the menu bar.
    static func fit(height: CGFloat) {
        guard height > 50 else { return }
        // Run after the current layout pass, when the window exists and has its position.
        DispatchQueue.main.async {
            for window in NSApp.windows where !window.className.contains("StatusBar") {
                var frame = window.frame
                guard abs(frame.height - height) > 0.5 else { continue }
                frame.origin.y += frame.height - height
                frame.size.height = height
                window.setFrame(frame, display: true)
            }
        }
    }
}

/// Applies the Light / Dark / System choice to the popup window itself.
/// SwiftUI's `preferredColorScheme` has no effect inside a menu bar popup, and changing
/// the whole app's appearance would also recolour the menu bar item.
@MainActor
enum PopupAppearance {
    static func apply(_ choice: String) {
        let appearance: NSAppearance? = switch choice {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil   // follow the system
        }
        // Every window of this app except the menu bar item itself (i.e. the popup).
        for window in NSApp.windows where !window.className.contains("StatusBar") {
            window.appearance = appearance
        }
    }
}

// MARK: Settings page

struct SettingsView: View {
    @AppStorage("interval") private var interval: Double = 2
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("showCPU") private var showCPU = true
    @AppStorage("showRAM") private var showRAM = true
    @AppStorage("showGPU") private var showGPU = false
    @AppStorage("showNet") private var showNet = false
    @AppStorage("showTemp") private var showTemp = false
    @AppStorage("showSensors") private var showSensors = false
    @AppStorage("compactBar") private var compactBar = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showProcesses") private var showProcesses = true
    @AppStorage("speedBits") private var speedBits = false
    @AppStorage("alerts") private var alerts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("General")
            Card {
                SettingRow("Refresh every") {
                    Segmented(options: [(1.0, "1 s"), (2.0, "2 s"), (5.0, "5 s"), (10.0, "10 s")], selection: $interval)
                        .frame(width: 176)
                }
                Divider().opacity(0.5)
                SettingRow("Appearance") {
                    Segmented(options: [("system", "Auto"), ("light", "Light"), ("dark", "Dark")], selection: $appearance)
                        .frame(width: 176)
                }
            }

            SectionLabel("Menu bar shows")
            Card {
                HStack(spacing: 4) {
                    Chip("CPU", isOn: $showCPU)
                    Chip("RAM", isOn: $showRAM)
                    Chip("GPU", isOn: $showGPU)
                    Chip("Net", isOn: $showNet)
                    Chip("Temp", isOn: $showTemp)
                }
                Divider().opacity(0.5)
                SwitchRow("Compact two-line layout", isOn: $compactBar)
            }

            SectionLabel("Options")
            Card {
                SwitchRow("Top processes", isOn: $showProcesses)
                Divider().opacity(0.5)
                SwitchRow("Temperature and fan speed", isOn: $showSensors)
                Divider().opacity(0.5)
                SwitchRow("Network speed in bits", isOn: $speedBits)
                Divider().opacity(0.5)
                SwitchRow("Alerts for memory, disk and heat", isOn: $alerts)
                    .onChange(of: alerts) { _, on in if on { Notifier.requestPermission() } }
                Divider().opacity(0.5)
                SwitchRow("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if on != LaunchAtLogin.isOn { LaunchAtLogin.set(on) }
                    }
            }
        }
        .font(.system(size: 12))
        .tint(Theme.accent)   // switches use the app's green, not the system blue
        .onAppear { launchAtLogin = LaunchAtLogin.isOn }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Theme.label).foregroundStyle(.secondary)
            .padding(.leading, 4).padding(.top, 4)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control
    init(_ title: String, @ViewBuilder control: () -> Control) { self.title = title; self.control = control() }
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            control
        }
        .frame(minHeight: 24)
    }
}

struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; self._isOn = isOn }
    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .frame(minHeight: 24)
    }
}

/// A quiet segmented control drawn to match the cards (the system one looks heavy in a popup).
struct Segmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let selected = options[i].value == selection
                Button { selection = options[i].value } label: {
                    Text(options[i].title)
                        .font(.system(size: 11, weight: selected ? .medium : .regular).monospacedDigit())
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .background(selected ? Color.primary.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.track, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// An on/off choice shown as a small tag.
struct Chip: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; self._isOn = isOn }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark" : "plus")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.accent : Color.secondary)
                Text(title).font(.system(size: 11, weight: isOn ? .medium : .regular))
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(isOn ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isOn ? Color.clear : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: Building blocks

struct Card<Content: View>: View {
    var fillHeight = false   // for cards that sit side by side and should match heights
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
    }
}

struct Stat: View {
    let label: String, value: String
    var alignment: HorizontalAlignment = .leading
    var swatch: Color? = nil

    init(_ label: String, _ value: String, alignment: HorizontalAlignment = .leading, swatch: Color? = nil) {
        self.label = label; self.value = value; self.alignment = alignment; self.swatch = swatch
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 4) {
                if let swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 6, height: 6) }
                Text(label).font(Theme.label).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(value).font(Theme.value).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: alignment == .leading ? .infinity : nil, alignment: .leading)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 6, height: 6) }
}

/// Thin horizontal meter.
struct Meter: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

/// One bar split into parts; the remainder is left empty.
struct SegmentBar: View {
    let segments: [(fraction: Double, color: Color)]
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle().fill(segments[i].color)
                        .frame(width: max(0, geo.size.width * min(max(segments[i].fraction, 0), 1)))
                }
                Spacer(minLength: 0)
            }
            .background(Theme.track)
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}

/// Plain Path line chart: cheaper than Swift Charts for a tiny live graph.
struct Sparkline: View {
    let values: [Double]
    let maxValue: Double?
    let color: Color
    var grid = false

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue ?? (values.max() ?? 1), 1)
            let step = geo.size.width / CGFloat(max(Monitor.historyLength - 1, 1))
            let offset = CGFloat(Monitor.historyLength - values.count) * step
            let points = values.enumerated().map { i, v in
                CGPoint(x: offset + CGFloat(i) * step,
                        y: 1 + (geo.size.height - 2) * (1 - CGFloat(min(v, top) / top)))
            }
            ZStack {
                if grid {
                    Path { p in
                        for line in [0.0, 0.5, 1.0] {
                            let y = 0.5 + (geo.size.height - 1) * line
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                    }
                    .stroke(Theme.hairline, lineWidth: 1)
                }
                if let first = points.first, let last = points.last, points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: first.x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                    }
                    .fill(color.opacity(grid ? 0.12 : 0.18))
                    Path { p in p.addLines(points) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

struct CoreBars: View {
    let values: [Double]
    var gapAfter: Int? = nil   // extra space after this many bars (between core groups)

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(values.indices, id: \.self) { i in
                if i == gapAfter { Color.clear.frame(width: 8, height: 1) }
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.track)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.alert(values[i]) ?? Theme.fill)
                        .frame(height: max(2, 16 * min(values[i], 100) / 100))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 16)
        .help("Usage of each CPU core")
    }
}

/// Developer credit and links, taken from `AppInfo`.
struct AboutLine: View {
    var body: some View {
        let links = AppInfo.websites.map { ($0.title, $0.url) }
            + (AppInfo.sourceURL.isEmpty ? [] : [("Source code", AppInfo.sourceURL)])
        if !AppInfo.developerName.isEmpty || !links.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !AppInfo.developerName.isEmpty {
                    Text("Developed by \(AppInfo.developerName)").font(Theme.label).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    ForEach(links, id: \.1) { title, url in
                        if let u = URL(string: url) {
                            // A plain button with solid text: the default link colour is hard to read here.
                            Button { NSWorkspace.shared.open(u) } label: {
                                HStack(spacing: 4) {
                                    Text(title)
                                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .font(Theme.label)
                                .lineLimit(1).fixedSize()
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
                            }
                            .buttonStyle(.plain)
                            .help(url)
                        }
                    }
                }
            }
        }
    }
}

/// The signature detail: a status dot that is green while all is well and changes colour only on trouble.
struct ThermalStatus: View {
    let state: ProcessInfo.ThermalState
    var body: some View {
        let (text, color): (String, Color) = switch state {
        case .nominal: ("Cool", Theme.accent)
        case .fair: ("Warm", Theme.warning)
        case .serious: ("Hot", Theme.critical)
        case .critical: ("Too hot", Theme.critical)
        @unknown default: ("Unknown", Theme.fill)
        }
        HStack(spacing: 6) {
            StatusDot(color: color)
            Text(text).font(Theme.label).foregroundStyle(.secondary)
        }
        .help("Thermal state reported by macOS")
    }
}
