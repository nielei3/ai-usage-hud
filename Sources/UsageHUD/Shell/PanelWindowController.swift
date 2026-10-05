import AppKit
import SwiftUI
import UsageCore

/// The NSPanel itself: non-activating, floating (status-bar level), can-join-all-spaces,
/// full-screen auxiliary. Anchored 4pt under the status item; Esc/outside-click close.
@MainActor
final class PanelWindowController: NSObject, NSWindowDelegate {
    private let engine: UsageEngine
    private let store: HudStore
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(engine: UsageEngine, store: HudStore) {
        self.engine = engine
        self.store = store
    }

    func start() {
        Task { [engine] in
            await engine.start()
        }
    }

    func stop() {
        // No engine.stop() — engine lifetime == process lifetime
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        self.localMonitor = nil
        self.globalMonitor = nil
    }

    func toggle(anchor: NSStatusBarButton?) {
        if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel(anchor: anchor)
        }
    }

    private func showPanel(anchor: NSStatusBarButton?) {
        let content = HUDPanelRoot(
            snapshot: Binding(get: { [weak self] in self?.store.snapshot ?? UsageSnapshot() }, set: { _ in }),
            settings: Binding(
                get: { [weak self] in self?.store.settings ?? HudSettings() },
                set: { [weak self] value in self?.store.settings = value }
            ),
            onQuit: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingView(rootView: content)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.nonactivatingPanel, .utilityWindow, .titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.delegate = self
        panel.contentView = hosting

        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.state = .active
        visual.blendingMode = .behindWindow
        hosting.superview?.addSubview(visual, positioned: .below, relativeTo: hosting)
        visual.frame = hosting.bounds
        visual.autoresizingMask = [.width, .height]

        if let anchor, anchor.window != nil {
            let anchorRect = anchor.convert(anchor.bounds, to: nil)
            let x = anchorRect.midX - panel.frame.width / 2
            let y = anchor.window!.frame.minY - panel.frame.height - 4
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }

        panel.orderFrontRegardless()
        self.panel = panel
        installMonitors()
    }

    func closePanel() {
        panel?.orderOut(nil)
        panel = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        self.localMonitor = nil
        self.globalMonitor = nil
    }

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.closePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.closePanel()
                return nil
            }
            return event
        }
    }

    func windowWillClose(_ notification: Notification) {
        closePanel()
    }

}
