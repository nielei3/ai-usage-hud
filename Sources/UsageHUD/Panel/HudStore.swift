import Foundation
import Observation
import UsageCore

/// The single main-actor holder of UI state. @Observable so a fresh
/// snapshot or a settings write redraws the panel directly.
@MainActor
@Observable
public final class HudStore {
    public private(set) var snapshot: UsageSnapshot = UsageSnapshot()
    public var settings: HudSettings {
        didSet {
            settingsStore.save(settings)
            Task { await engine.setIncludeSidechains(settings.includeSidechains) }
            onSettingsChanged?(settings)
        }
    }

    private let engine: UsageEngine
    private let settingsStore: SettingsStore
    private var onSettingsChanged: ((HudSettings) -> Void)?

    public init(engine: UsageEngine, settingsStore: SettingsStore) {
        self.engine = engine
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
    }

    /// The engine sink lands here — swapping the snapshot redraws subscribers.
    public func ingest(_ snapshot: UsageSnapshot) {
        self.snapshot = snapshot
    }

    /// Launch-at-login ownership hook; fires immediately so the persisted
    /// setting applies without waiting for an edit.
    public func onSettingsChange(_ handler: @escaping (HudSettings) -> Void) {
        onSettingsChanged = handler
        handler(settings)
    }
}
