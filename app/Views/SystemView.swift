import SwiftUI

struct SystemSection: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        let s = monitor.snapshot
        // Exactly one flexible column per card: no leftover space on wide windows.
        var cards: [(title: String, value: Double, center: String, sub: String?, color: Color)] = [
            ("CPU", s.cpuUsage, percent(s.cpuUsage), nil, .blue),
        ]
        if let gpu = s.gpuUsage {
            cards.append(("GPU", gpu, percent(gpu), nil, .purple))
        }
        cards.append(("内存", s.memoryUsedFraction, percent(s.memoryUsedFraction),
                      String(format: "%.1f / %.0f GB", s.memoryUsedGB, s.memoryTotalGB), .green))

        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "系统状态", icon: "cpu")

            LazyVGrid(columns: cards.map { _ in GridItem(.flexible(), spacing: 14) }, spacing: 14) {
                ForEach(cards, id: \.title) { card in
                    GaugeCard(title: card.title, value: card.value,
                              center: card.center, sub: card.sub, color: card.color)
                }
            }
        }
    }

    private func percent(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }
}

private struct GaugeCard: View {
    let title: String
    let value: Double // 0...1
    let center: String
    var sub: String? = nil
    let color: Color

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                let lineWidth: CGFloat = 25 // fixed, does not scale with window size
                ZStack {
                    Circle()
                        .stroke(color.opacity(0.18), lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: min(max(value, 0), 1))
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: value)
                    VStack(spacing: 1) {
                        Text(center)
                            .font(.system(size: d * 0.17, weight: .semibold).monospacedDigit())
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        if let sub {
                            Text(sub)
                                .font(.system(size: d * 0.08).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: d * 0.75)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            // Fixed ring area: rings never grow past this, so they can't be
            // clipped by the window edge when the window is maximized.
            .frame(height: 200)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
