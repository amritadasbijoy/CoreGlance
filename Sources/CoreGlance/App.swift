import SwiftUI
import ServiceManagement

@main
struct CoreGlanceApp: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            PopupView(monitor: monitor)
        } label: {
            MenuBarLabel(bar: monitor.bar)
                .task { await DebugSnapshot.runIfRequested(monitor) }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var bar: BarModel

    var body: some View {
        if let image = bar.image {
            Image(nsImage: image).accessibilityLabel(bar.text)
        } else if bar.text.isEmpty {
            Image(systemName: "waveform.path.ecg").accessibilityLabel("CoreGlance")
        } else {
            Text(bar.text).monospacedDigit()
        }
    }
}

/// Development aid: `COREGLANCE_SNAPSHOT=/path/out.png` draws the popup to a PNG a few seconds
/// after launch, so the interface can be checked without clicking the menu bar.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(_ monitor: Monitor) async {
        guard let path = ProcessInfo.processInfo.environment["COREGLANCE_SNAPSHOT"] else { return }
        monitor.popupOpen = true
        try? await Task.sleep(for: .seconds(6))
        let view = PopupView(monitor: monitor)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, ProcessInfo.processInfo.environment["COREGLANCE_SNAPSHOT_LIGHT"] != nil ? .light : .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        if ProcessInfo.processInfo.environment["COREGLANCE_SNAPSHOT_OPEN"] != nil {
            // Also open the real popup and report which appearance its window ended up with.
            func button(in view: NSView?) -> NSStatusBarButton? {
                guard let view else { return nil }
                if let b = view as? NSStatusBarButton { return b }
                return view.subviews.lazy.compactMap { button(in: $0) }.first
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.lazy.compactMap { button(in: $0.contentView) }.first?.performClick(nil)
            try? await Task.sleep(for: .seconds(1.5))
            for window in NSApp.windows where !window.className.contains("StatusBar") {
                NSLog("CoreGlance debug: popup appearance = %@", window.effectiveAppearance.name.rawValue)
            }
        }
        NSApp.terminate(nil)
    }
}

enum LaunchAtLogin {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("CoreGlance: launch at login change failed: \(error.localizedDescription)")
        }
    }
}
