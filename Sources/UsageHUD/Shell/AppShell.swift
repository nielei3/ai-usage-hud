import AppKit
import ServiceManagement
import UsageCore

@main
struct UsageHUDApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: PanelWindowController?
    private var watcher: FSEventsWatcher?
    private let settingsStore = UserDefaultsSettingsStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let locations = DataLocations.resolve()
        let engine = UsageEngine(
            feed: .init(claudeRoot: locations.claudeRoot, codexRoot: locations.codexRoot),
            clock: SystemClock()
        )
        let store = HudStore(engine: engine, settingsStore: settingsStore)
        let controller = PanelWindowController(engine: engine, store: store)
        self.panelController = controller

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        self.statusItem = item

        // Sink → store (main actor) → SwiftUI redraw + status-bar title.
        store.onSettingsChange { settings in
            if #available(macOS 13.0, *) {
                if settings.launchAtLogin {
                    try? SMAppService.mainApp.register()
                } else {
                    try? SMAppService.mainApp.unregister()
                }
            }
        }

        let button = item.button
        Task { [engine] in
            await engine.setSink { snapshot in
                Task { @MainActor in
                    store.ingest(snapshot)
                    button?.title = StatusBarRenderer.text(
                        for: snapshot, limitTokens: store.settings.fiveHourLimitTokens
                    )
                }
            }
            await engine.setIncludeSidechains(store.settings.includeSidechains)
            await engine.start()
        }

        // FSEvents → tailPulse (or rescanAll per Regime), 60s sweep → rescanAll.
        let watcher = FSEventsWatcher(roots: [locations.claudeRoot, locations.codexRoot]) { [weak engine] paths in
            Task { [weak engine] in
                guard let engine else { return }
                if await engine.regime.regime == .incrementalTail {
                    await engine.tailPulse(changed: paths)
                } else {
                    await engine.rescanAll()
                }
            }
        }
        watcher.start()
        self.watcher = watcher
        controller.start()
    }

    @objc private func togglePanel(_ sender: Any?) {
        panelController?.toggle(anchor: statusItem?.button)
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        panelController?.stop()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}
