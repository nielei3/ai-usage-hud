import AppKit
import ServiceManagement
import UsageCore

@main
struct UsageHUDApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: PanelWindowController?
    private var watcher: FSEventsWatcher?
    private let settingsStore = UserDefaultsSettingsStore()
    private var quotaTimer: DispatchSourceTimer?
    private let quotaQueue = DispatchQueue(label: "usage-hud.quota", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let locations = DataLocations.resolve()
        let engine = UsageEngine(
            feed: .init(
                claudeRoot: locations.claudeRoot,
                codexRoot: locations.codexRoot,
                claudeUsageCache: locations.claudeUsageCache
            ),
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

        startQuotaTimer(engine: engine)

        // FSEvents → tailPulse, 60s sweep → rescanAll.
        let watcher = FSEventsWatcher(roots: [locations.claudeRoot, locations.codexRoot]) { [weak engine] paths in
            Task { [weak engine] in
                guard let engine else { return }
                let rootPaths = Set([locations.claudeRoot.path, locations.codexRoot.path])
                let isSweep = paths.contains { rootPaths.contains($0.path) }
                if isSweep {
                    await engine.rescanAll()
                } else {
                    await engine.tailPulse(changed: paths)
                }
            }
        }
        watcher.start()
        self.watcher = watcher
        controller.start()
        panelController?.showPanel(anchor: nil)
    }

    private func startQuotaTimer(engine: UsageEngine) {
        let timer = DispatchSource.makeTimerSource(queue: quotaQueue)
        quotaTimer = timer
        timer.schedule(deadline: .now(), repeating: 120)
        timer.setEventHandler { [weak engine] in
            let claude = ClaudeUsageFetcher.fetch()
            let codex = CodexUsageFetcher.fetch()
            let snapshot = QuotaSnapshot(claude: claude, codex: codex)
            Task { [weak engine] in
                await engine?.setQuota(snapshot)
                await engine?.tailPulse(changed: [])
            }
        }
        timer.resume()
    }

    @objc private func togglePanel(_ sender: Any?) {
        panelController?.toggle(anchor: statusItem?.button)
    }

    func applicationWillTerminate(_ notification: Notification) {
        quotaTimer?.cancel()
        watcher?.stop()
        panelController?.stop()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}
