import Foundation

public struct HudSettings: Sendable, Equatable {
    public var includeSidechains: Bool
    public var fiveHourLimitTokens: Int?
    public var launchAtLogin: Bool

    public init(includeSidechains: Bool = true, fiveHourLimitTokens: Int? = nil, launchAtLogin: Bool = false) {
        self.includeSidechains = includeSidechains
        self.fiveHourLimitTokens = fiveHourLimitTokens
        self.launchAtLogin = launchAtLogin
    }
}

public protocol SettingsStore: Sendable {
    func load() -> HudSettings
    func save(_ settings: HudSettings)
}

/// UserDefaults is documented thread-safe; boxed non-Sendable behind an
/// @unchecked Sendable shell — the struct stays Sendable for the protocol.
public struct UserDefaultsSettingsStore: SettingsStore {
    private final class Box: @unchecked Sendable {
        let defaults: UserDefaults
        init(_ defaults: UserDefaults) { self.defaults = defaults }
    }

    private let box: Box

    public init(defaults: UserDefaults = .standard) {
        self.box = Box(defaults)
    }

    public func load() -> HudSettings {
        var settings = HudSettings()
        if box.defaults.object(forKey: "includeSidechains") != nil {
            settings.includeSidechains = box.defaults.bool(forKey: "includeSidechains")
        }
        if box.defaults.object(forKey: "fiveHourLimitTokens") != nil {
            settings.fiveHourLimitTokens = box.defaults.integer(forKey: "fiveHourLimitTokens")
        }
        settings.launchAtLogin = box.defaults.bool(forKey: "launchAtLogin")
        return settings
    }

    public func save(_ settings: HudSettings) {
        box.defaults.set(settings.includeSidechains, forKey: "includeSidechains")
        if let cap = settings.fiveHourLimitTokens {
            box.defaults.set(cap, forKey: "fiveHourLimitTokens")
        } else {
            box.defaults.removeObject(forKey: "fiveHourLimitTokens")
        }
        box.defaults.set(settings.launchAtLogin, forKey: "launchAtLogin")
    }
}
