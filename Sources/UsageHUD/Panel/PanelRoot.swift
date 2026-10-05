import SwiftUI
import UsageCore

struct HUDPanelRoot: View {
    @Binding var snapshot: UsageSnapshot
    @Binding var settings: HudSettings
    let onQuit: () -> Void

    var body: some View {
        ExpandablePanel(
            snapshot: snapshot,
            settings: $settings,
            onQuit: onQuit
        )
    }
}

private final class PanelState: ObservableObject {
    @Published var expanded = false
}

private struct ExpandablePanel: View {
    let snapshot: UsageSnapshot
    @Binding var settings: HudSettings
    let onQuit: () -> Void

    @StateObject private var state = PanelState()

    private var claude5hPercent: Double? { snapshot.claude.fiveHourPercent }
    private var claudeWeeklyPercent: Double? { snapshot.claude.weeklyPercent }
    private var codexWeeklyPercent: Double? { snapshot.codex.rateLimits.first?.usedPercent }
    private var codexResetDate: Date? { snapshot.codex.rateLimits.first?.resetsAt }

    private var claudeCreditPercent: Double? {
        guard let limit = snapshot.claude.creditLimitUsd, limit > 0,
              let used = snapshot.claude.creditUsedUsd else { return nil }
        return min(max(used / limit * 100, 0), 100)
    }

    private var claudeHasCredit: Bool {
        guard let limit = snapshot.claude.creditLimitUsd, limit > 0 else { return false }
        return true
    }

    private var claudeCreditAmount: String? {
        guard let used = snapshot.claude.creditUsedUsd else { return nil }
        return String(format: "$%.2f", used)
    }

    private var claudeMetrics: [Metric] {
        let metric5h: Metric
        let pct = claude5hPercent ?? 0
        let reset = snapshot.claude.fiveHourResetsAt.map { CountdownTime.format(from: $0) }
        metric5h = Metric(percent: pct, label: "5h", valueText: nil, resetLabel: reset)

        let metricWeekly: Metric
        if let wpct = claudeWeeklyPercent {
            let wreset = snapshot.claude.weeklyResetsAt.map { CountdownTime.format(from: $0) }
            metricWeekly = Metric(percent: wpct, label: "weekly", valueText: nil, resetLabel: wreset)
        } else {
            metricWeekly = Metric(percent: nil, label: "weekly", valueText: nil, resetLabel: nil)
        }

        return [metric5h, metricWeekly]
    }

    private var codexCreditPercent: Double? {
        guard let used = snapshot.codex.creditBalance,
              let limit = snapshot.codex.creditLimit, limit > 0 else { return nil }
        return min(max(used / limit * 100, 0), 100)
    }

    private var codexHasCredit: Bool {
        guard let limit = snapshot.codex.creditLimit, limit > 0 else { return false }
        return true
    }

    private var codexCreditAmount: String? {
        guard let used = snapshot.codex.creditBalance else { return nil }
        return String(format: "%.0f", used)
    }

    private var codexMetrics: [Metric] {
        let pct = codexWeeklyPercent
        let reset = codexResetDate.map { CountdownTime.format(from: $0) }
        return [Metric(percent: pct, label: "weekly", valueText: nil, resetLabel: reset)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                BubbleView(
                    title: "Claude Code",
                    iconName: "claude-icon",
                    brandColor: Color(red: 0.85, green: 0.55, blue: 0.25),
                    metrics: claudeMetrics,
                    topBarPercent: claudeHasCredit ? claudeCreditPercent : nil,
                    topBarLabel: "credits",
                    topBarSubAmount: claudeHasCredit ? claudeCreditAmount : nil
                )
                .frame(width: 80)
                Spacer()
                BubbleView(
                    title: "Codex",
                    iconName: "codex-icon",
                    brandColor: Color(red: 0.25, green: 0.75, blue: 0.55),
                    metrics: codexMetrics,
                    topBarPercent: codexHasCredit ? codexCreditPercent : nil,
                    topBarLabel: "credits",
                    topBarSubAmount: codexHasCredit ? codexCreditAmount : nil
                )
                .frame(width: 80)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                state.expanded.toggle()
            }
            if state.expanded {
                Divider()
                detailSection
                Divider()
                settingsFooter
            }
        }
        .padding(10)
        .frame(width: 220)
        .animation(.easeInOut(duration: 0.25), value: state.expanded)
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClaudeDetail(snapshot: snapshot.claude)
            Divider()
            CodexDetail(snapshot: snapshot.codex)
        }
    }

    private var settingsFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
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

private struct ClaudeDetail: View {
    let snapshot: UsageSnapshot.Claude

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude Code").font(.caption).foregroundStyle(.secondary)
            row("today input", snapshot.todayUsage.inputTokens)
            row("today output", snapshot.todayUsage.outputTokens)
            row("today cache read", snapshot.todayUsage.cacheReadTokens)
            row("today cache write", snapshot.todayUsage.cacheCreationTokens)
            HStack {
                Text("5h block total").foregroundStyle(.secondary)
                Spacer()
                Text(abbreviate(snapshot.blockUsage.totalTokens)).monospacedDigit()
            }
            HStack {
                Text("weekly total").foregroundStyle(.secondary)
                Spacer()
                Text(abbreviate(snapshot.weeklyUsage.totalTokens)).monospacedDigit()
            }
            if let reset = snapshot.fiveHourResetsAt {
                HStack {
                    Text("5h resets").foregroundStyle(.secondary)
                    Spacer()
                    Text(ShortTime.format(reset)).monospacedDigit()
                }
            }
            if let reset = snapshot.weeklyResetsAt {
                HStack {
                    Text("weekly resets").foregroundStyle(.secondary)
                    Spacer()
                    Text(ShortTime.format(reset)).monospacedDigit()
                }
            }
            HStack {
                Text("sessions").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(snapshot.activeSessions)").font(.caption).monospacedDigit()
                if let last = snapshot.lastActivity {
                    RelativeTimeText(date: last).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ label: String, _ tokens: Int) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(abbreviate(tokens)).font(.caption).monospacedDigit()
        }
    }

    private func abbreviate(_ tokens: Int) -> String { StatusBarDecision.abbreviate(tokens) }
}

private struct CodexDetail: View {
    let snapshot: UsageSnapshot.Codex

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Codex").font(.caption).foregroundStyle(.secondary)
            row("today input (incl cached)", snapshot.todayUsage.inputTokens)
            if snapshot.todayUsage.cachedInputTokens > 0 {
                row("· cached", snapshot.todayUsage.cachedInputTokens)
            }
            row("today output (incl reasoning)", snapshot.todayUsage.outputTokens)
            row("today total", snapshot.todayUsage.totalTokens)
            ForEach(Array(snapshot.rateLimits.enumerated()), id: \.offset) { _, window in
                HStack {
                    Text("\(window.windowName) limit").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", window.usedPercent))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(UsageColor.forPercent(window.usedPercent))
                    RelativeTimeText(date: window.resetsAt).font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("sessions").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(snapshot.activeSessions)").font(.caption).monospacedDigit()
                if let last = snapshot.lastActivity {
                    RelativeTimeText(date: last).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ label: String, _ tokens: Int) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(abbreviate(tokens)).font(.caption).monospacedDigit()
        }
    }

    private func abbreviate(_ tokens: Int) -> String { StatusBarDecision.abbreviate(tokens) }
}

enum ShortTime {
    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f.string(from: date)
    }
}

enum CountdownTime {
    static func format(from date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "reset now" }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 {
            return "reset in \(hours)h\(minutes)m"
        }
        return "reset in \(minutes)m"
    }
}
