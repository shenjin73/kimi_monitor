import SwiftUI

struct QuotaSection: View {
    @EnvironmentObject var monitor: QuotaMonitor
    @EnvironmentObject var deepSeek: DeepSeekMonitor

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

    /// Section-level "updated at": the most recent of the two monitors.
    private var lastUpdated: Date? {
        [monitor.lastUpdated, deepSeek.lastUpdated].compactMap { $0 }.max()
    }

    /// One row of tiles: the Kimi quota cards followed by the DeepSeek account
    /// tile, all sharing the width equally (3 cards → 1/3 each). When a quota
    /// card is missing — first load, or the fetch failed — the DeepSeek tile
    /// gets the whole row instead of being squeezed.
    private var columns: [GridItem] {
        let count = min(max(cards.count + 1, 1), 3)
        return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "套餐用量", icon: "gauge.with.dots.needle.67percent")
                Spacer()
                if let updated = lastUpdated {
                    Text("更新于 \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    Task {
                        // One button refreshes every number in this section.
                        async let quota: Void = monitor.refresh()
                        async let deepseek: Void = deepSeek.refresh()
                        _ = await (quota, deepseek)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("立即刷新")
            }

            LazyVGrid(columns: columns, spacing: 14) {
                if cards.isEmpty {
                    quotaPlaceholder
                } else {
                    ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                        QuotaCard(title: card.title, quota: card.quota)
                    }
                }
                DeepSeekUsageCard()
            }

            if let error = monitor.lastError, !cards.isEmpty {
                Label("上次刷新失败: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Stands in for the quota cards while they are loading or unavailable.
    @ViewBuilder
    private var quotaPlaceholder: some View {
        if let error = monitor.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, minHeight: 80)
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 80)
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
            Bar3D(value: fraction, color: color)
            // The tile stretches to the row height set by the taller DeepSeek
            // tile, so the countdown is pinned to the bottom instead of
            // leaving a gap under it.
            Spacer(minLength: 0)
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
        // Fill the grid row so all tiles in it share one height and their
        // backgrounds line up, even though the DeepSeek tile is taller.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 3D Bar

struct Bar3D: View {
    let value: Double  // 0…1
    let color: Color

    private let barHeight: CGFloat = 20
    private let radius: CGFloat = 10   // = barHeight / 2

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let clamped = min(max(value, 0), 1)
            // Minimum visible width when value > 0: enough for a rounded cap
            let filled: CGFloat = clamped > 0 ? max(w * clamped, radius * 2) : 0

            ZStack(alignment: .leading) {
                // ── Track ──────────────────────────────────────────
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.10), color.opacity(0.22)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.black.opacity(0.22), Color.clear],
                            startPoint: .top, endPoint: .center
                        ),
                        lineWidth: 1.5
                    )

                // ── Filled bar — clipped to exact width ───────────
                if filled > 0 {
                    ZStack(alignment: .leading) {
                        // Base gradient
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [color.opacity(0.65), color, color.opacity(0.80)],
                                    startPoint: .bottom, endPoint: .top
                                )
                            )
                        // Top-gloss strip
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.42), Color.clear],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .frame(height: barHeight * 0.45)
                            .frame(maxHeight: .infinity, alignment: .top)
                        // Right-cap specular dot
                        RadialGradient(
                            colors: [Color.white.opacity(0.50), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: barHeight * 0.7
                        )
                        .frame(width: barHeight * 1.4, height: barHeight)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    // Clip the whole filled block to a rounded rect of exactly `filled` width
                    .frame(width: filled, height: barHeight)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                    .animation(.easeInOut(duration: 0.35), value: value)
                }

                // ── Outer rim highlight ───────────────────────────
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.20), Color.clear],
                            startPoint: .top, endPoint: .center
                        ),
                        lineWidth: 1
                    )
            }
            .frame(height: barHeight)
            .shadow(color: color.opacity(0.30), radius: 3, x: 0, y: 2)
        }
        .frame(height: barHeight)
    }
}
