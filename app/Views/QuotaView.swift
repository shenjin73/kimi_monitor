import SwiftUI

struct QuotaSection: View {
    @EnvironmentObject var monitor: QuotaMonitor

    private var cards: [(title: String, quota: UsageResponse.Quota)] {
        guard let usage = monitor.usage else { return [] }
        var result: [(String, UsageResponse.Quota)] = (usage.limits ?? []).compactMap { entry in
            entry.detail.map { (entry.windowLabel, $0) }
        }
        if let weekly = usage.usage {
            result.append(("每周配额", weekly))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "套餐用量", icon: "gauge.with.dots.needle.67percent")
                Spacer()
                if let updated = monitor.lastUpdated {
                    Text("更新于 \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("立即刷新")
            }

            if !cards.isEmpty {
                // One flexible column per card: fills the width, no empty columns.
                LazyVGrid(columns: cards.map { _ in GridItem(.flexible(), spacing: 14) }, spacing: 14) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                        QuotaCard(title: card.title, quota: card.quota)
                    }
                }
                if let error = monitor.lastError {
                    Label("上次刷新失败: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if let error = monitor.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }
}

private struct QuotaCard: View {
    let title: String
    let quota: UsageResponse.Quota

    private var fraction: Double { quota.usedFraction }

    private var color: Color {
        fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
            }
            ProgressBar(value: fraction, color: color)
            HStack {
                Spacer()
                if let reset = parseISO8601(quota.resetTime) {
                    Text("重置: \(relativeTime(reset))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Rounded bar 18pt thick.
private struct ProgressBar: View {
    let value: Double // 0...1
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
                    .animation(.easeInOut(duration: 0.3), value: value)
            }
        }
        .frame(height: 18)
    }
}
