import SwiftUI
import UsageCore

struct ClaudePanelColumn: View {
    let snapshot: UsageSnapshot.Claude
    let limitTokens: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude Code").font(.headline)
            usageRow("input", snapshot.todayUsage.inputTokens)
            usageRow("output", snapshot.todayUsage.outputTokens)
            usageRow("cache read", snapshot.todayUsage.cacheReadTokens)
            usageRow("cache creation", snapshot.todayUsage.cacheCreationTokens)
            blockRow
            sessionsRow
        }
    }

    private var blockRow: some View {
        HStack {
            Text("5h block (est)").foregroundStyle(.secondary)
            Spacer()
            if let limitTokens, limitTokens > 0, let pct = StatusBarDecision.blockPercent(blockUsage: snapshot.blockUsage, limitTokens: limitTokens) {
                Text(String(format: "%.0f%%", pct))
                    .monospacedDigit()
                ProgressView(value: pct, total: 100)
                    .frame(width: 72)
            } else {
                Text(abbreviate(snapshot.blockUsage.totalTokens))
            }
        }
    }

    private var sessionsRow: some View {
        HStack {
            Text("sessions").foregroundStyle(.secondary)
            Spacer()
            Text("\(snapshot.activeSessions)")
            if let last = snapshot.lastActivity {
                RelativeTimeText(date: last).foregroundStyle(.secondary)
            }
        }
    }

    private func usageRow(_ label: String, _ tokens: Int) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(abbreviate(tokens)).monospacedDigit()
        }
    }

    private func abbreviate(_ tokens: Int) -> String {
        StatusBarDecision.abbreviate(tokens)
    }
}

struct CodexPanelColumn: View {
    let snapshot: UsageSnapshot.Codex

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Codex").font(.headline)
            usageRow("input (incl cached)", snapshot.todayUsage.inputTokens)
            if snapshot.todayUsage.cachedInputTokens > 0 {
                usageRow("· cached", snapshot.todayUsage.cachedInputTokens)
            }
            usageRow("output (incl reasoning)", snapshot.todayUsage.outputTokens)
            usageRow("total", snapshot.todayUsage.totalTokens)
            ForEach(Array(snapshot.rateLimits.enumerated()), id: \.offset) { _, window in
                limitRow(window)
            }
            if snapshot.rateLimits.isEmpty {
                Text("rate limits —").foregroundStyle(.secondary)
            }
            sessionsRow
        }
    }

    private func limitRow(_ window: RateLimitWindow) -> some View {
        HStack {
            Text(window.windowName).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.0f%%", window.usedPercent)).monospacedDigit()
            HStack(spacing: 2) {
                RelativeTimeText(date: window.resetsAt)
                Text("reset")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var sessionsRow: some View {
        HStack {
            Text("sessions").foregroundStyle(.secondary)
            Spacer()
            Text("\(snapshot.activeSessions)")
            if let last = snapshot.lastActivity {
                RelativeTimeText(date: last).foregroundStyle(.secondary)
            }
        }
    }

    private func usageRow(_ label: String, _ tokens: Int) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(abbreviate(tokens)).monospacedDigit()
        }
    }

    private func abbreviate(_ tokens: Int) -> String {
        StatusBarDecision.abbreviate(tokens)
    }
}

struct RelativeTimeText: View {
    static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    let date: Date

    var body: some View {
        Text(Self.formatter.localizedString(for: date, relativeTo: Date()))
    }
}
