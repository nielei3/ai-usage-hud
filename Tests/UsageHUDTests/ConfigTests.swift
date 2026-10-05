import Foundation
import Testing

@testable import UsageCore

@Suite struct DataLocationsTests {
    @Test func envOverridesBeatHomeDefaults() {
        let locations = DataLocations.resolve(environment: [
            "USAGE_HUD_CLAUDE_DIR": "/tmp/fx/claude",
            "USAGE_HUD_CODEX_DIR": "/tmp/fx/codex",
        ])
        #expect(locations.claudeRoot.path == "/tmp/fx/claude")
        #expect(locations.codexRoot.path == "/tmp/fx/codex")
    }

    @Test func missingEnvFallsBackToHomeDefaults() {
        let locations = DataLocations.resolve(environment: [:])
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(locations.claudeRoot == home.appendingPathComponent(".claude/projects", isDirectory: true))
        #expect(locations.codexRoot == home.appendingPathComponent(".codex/sessions", isDirectory: true))
    }
}

@Suite struct HudSettingsStoreTests {
    private func suite(_ name: String) -> UserDefaults {
        let s = UserDefaults(suiteName: name)!
        s.removePersistentDomain(forName: name)
        return s
    }

    @Test func roundTripSidechainToggleAndTokenCap() {
        let d = suite("usage-hud-test-rt")
        let store = UserDefaultsSettingsStore(defaults: d)
        store.save(HudSettings(includeSidechains: false, fiveHourLimitTokens: 120_000))
        let loaded = store.load()
        #expect(loaded.includeSidechains == false)
        #expect(loaded.fiveHourLimitTokens == 120_000)
    }

    @Test func defaultsWhenNothingSaved() {
        let d = suite("usage-hud-test-empty")
        let loaded = UserDefaultsSettingsStore(defaults: d).load()
        #expect(loaded.includeSidechains == true)
        #expect(loaded.fiveHourLimitTokens == nil)
    }

    @Test func clearingCapPersistsAsNil() {
        let d = suite("usage-hud-test-clear")
        let store = UserDefaultsSettingsStore(defaults: d)
        store.save(HudSettings(includeSidechains: true, fiveHourLimitTokens: 90_000))
        store.save(HudSettings(includeSidechains: true, fiveHourLimitTokens: nil))
        #expect(store.load().fiveHourLimitTokens == nil)
    }
}
