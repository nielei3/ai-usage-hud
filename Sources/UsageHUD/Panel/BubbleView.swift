import SwiftUI
import AppKit

enum UsageColor {
    static func forPercent(_ p: Double) -> Color {
        if p >= 90 { return Color(red: 0.68, green: 0.12, blue: 0.12) }
        if p >= 80 { return Color(red: 0.92, green: 0.72, blue: 0.0) }
        return Color(red: 0.22, green: 0.62, blue: 0.95)
    }
}

struct Metric {
    let percent: Double?
    let label: String
    let valueText: String?
    let resetLabel: String?
}

enum BrandIcon {
    static func load(name: String) -> NSImage? {
        let bundle = Bundle.main
        return bundle.image(forResource: name)
    }
}

struct BubbleView: View {
    let title: String
    let iconName: String
    let brandColor: Color
    let metrics: [Metric]
    var topBarPercent: Double? = nil
    var topBarLabel: String? = nil
    var topBarAmount: String? = nil
    var topBarSubAmount: String? = nil

    private static let diameter: CGFloat = 50

    private var primary: Metric? {
        metrics.first
    }

    private var primaryPercent: Double {
        min(max(primary?.percent ?? 0, 0), 100)
    }

    private var fillColor: Color {
        UsageColor.forPercent(primaryPercent)
    }

    private var hasData: Bool {
        primary?.percent != nil || primary?.valueText != nil
    }

    var body: some View {
        VStack(spacing: 4) {
            if let pct = topBarPercent {
                VStack(spacing: 1) {
                    if let subAmount = topBarSubAmount {
                        Text(subAmount)
                            .font(.system(size: 14, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(UsageColor.forPercent(pct))
                            .lineLimit(1)
                    }
                    if let label = topBarLabel {
                        HStack(spacing: 4) {
                            Text(label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(String(format: "%.1f%%", pct))
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(UsageColor.forPercent(pct))
                                .lineLimit(1)
                        }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(UsageColor.forPercent(pct))
                                .frame(width: geo.size.width * min(pct / 100, 1), height: 4)
                        }
                    }
                    .frame(height: 4)
                }
            }
            ZStack(alignment: .bottom) {
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: Self.diameter, height: Self.diameter)

                if primaryPercent > 0 {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [fillColor.opacity(0.25), fillColor.opacity(0.5)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: Self.diameter * primaryPercent / 100)
                        .animation(.easeInOut(duration: 0.5), value: primaryPercent)
                }
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(hasData ? fillColor.opacity(0.6) : brandColor.opacity(0.3), lineWidth: 2))
            .overlay {
                ZStack {
                    if let img = BrandIcon.load(name: iconName) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                        .opacity(0.85)
                        .offset(y: hasData ? -10 : 0)
                    }

                    Group {
                        if let p = primary?.percent {
                            HStack(alignment: .firstTextBaseline, spacing: 1) {
                                Text(String(format: "%.0f", p))
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                Text("%")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                        } else if let v = primary?.valueText {
                            Text(v)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.7)
                        } else {
                            Text("—")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .offset(y: hasData ? 8 : 0)
                }
            }
            .shadow(color: hasData ? fillColor.opacity(0.2) : .clear, radius: 6)

            VStack(spacing: 2) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { _, m in
                    metricLine(m)
                }
            }
        }
    }

    private func metricLine(_ m: Metric) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(m.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let pct = m.percent {
                    Text(String(format: "%.0f%%", pct))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(UsageColor.forPercent(pct))
                } else if let v = m.valueText {
                    Text(v)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            if let reset = m.resetLabel {
                Text(reset)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}
