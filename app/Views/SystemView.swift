import SwiftUI

struct SystemSection: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        let s = monitor.snapshot
        // Exactly one flexible column per card: no leftover space on wide windows.
        var cards: [(title: String, value: Double, center: String, sub: String?, color: Color,
                     processes: [SystemMonitor.ProcessUsage]?, note: String?)] = [
            ("CPU", s.cpuUsage, percent(s.cpuUsage), nil, .blue, s.cpuTop, nil),
        ]
        if let gpu = s.gpuUsage {
            cards.append(("GPU", gpu, percent(gpu), nil, .purple, s.gpuTop, nil))
        }
        cards.append(("内存", s.memoryUsedFraction, percent(s.memoryUsedFraction),
                      String(format: "%.1f / %.0f GB", s.memoryUsedGB, s.memoryTotalGB),
                      .green, s.memoryTop, nil))

        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "系统状态", icon: "cpu")

            LazyVGrid(columns: cards.map { _ in GridItem(.flexible(), spacing: 14) }, spacing: 14) {
                ForEach(cards, id: \.title) { card in
                    GaugeCard(title: card.title, value: card.value,
                              center: card.center, sub: card.sub, color: card.color,
                              processes: card.processes, note: card.note)
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
    var processes: [SystemMonitor.ProcessUsage]? = nil
    var note: String? = nil

    var body: some View {
        VStack(spacing: 0) {
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
            .frame(height: 196)
            .padding(.top, 16)

            // Top-3 process list (or an explanatory note) inside the tile.
            // Fixed height (3 rows) so all tiles stay the same height even
            // when a tile has no process data (GPU).
            VStack(spacing: 5) {
                if let processes, !processes.isEmpty {
                    ForEach(processes) { proc in
                        HStack(spacing: 6) {
                            Text(proc.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(-1)
                            Spacer(minLength: 6)
                            Text(proc.value)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.primary)
                                .fixedSize()
                        }
                    }
                } else if let note {
                    Spacer(minLength: 0)
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 70)
        }
        .padding(.top, 19)
        // The 25pt stroke overhangs the ring frame by 12.5pt; keep extra
        // bottom room so the ring never touches the tile edge.
        .padding(.bottom, 20)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
