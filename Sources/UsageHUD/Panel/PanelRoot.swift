import SwiftUI
import UsageCore

/// Panel root: two columns + settings footer. The limit field and the two
/// toggles write through HudSettings (persisted); limit flows straight into
/// the Claude column percent.
struct HUDPanelRoot: View {
    @Binding var snapshot: UsageSnapshot
    @Binding var settings: HudSettings
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                ClaudePanelColumn(snapshot: snapshot.claude, limitTokens: settings.fiveHourLimitTokens)
                Divider()
                CodexPanelColumn(snapshot: snapshot.codex)
            }
            Divider()
            settingsFooter
        }
        .padding(12)
        .frame(width: 360)
    }

    private var settingsFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("5h limit tokens").foregroundStyle(.secondary)
                Spacer()
                TextField("none", value: Binding(
                    get: { settings.fiveHourLimitTokens },
                    set: { settings.fiveHourLimitTokens = $0.map { max(0, Int($0)) } }
                ), format: .number.grouping(.never))
                .frame(width: 110)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
            }
            Toggle("include sidechain traffic", isOn: Binding(
                get: { settings.includeSidechains },
                set: { settings.includeSidechains = $0 }
            ))
            Toggle("launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.launchAtLogin = $0 }
            ))
            HStack {
                Spacer()
                Button("quit") { onQuit() }
            }
        }
    }
}
