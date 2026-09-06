import SwiftUI

struct SystemSection: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        let s = monitor.snapshot
        // Exactly one flexible column per card: no leftover space on wide windows.
        var cards: [(title: String, value: Double, center: String, sub: String?, color: Color,
                     processes: [SystemMonitor.ProcessUsage]?)] = [
            ("CPU", s.cpuUsage, percent(s.cpuUsage), freqText(s.cpuFreqMHz), .blue, s.cpuTop),
        ]
        if let gpu = s.gpuUsage {
            cards.append(("GPU", gpu, percent(gpu), freqText(s.gpuFreqMHz), .purple, s.gpuTop))
        }
        cards.append(("内存", s.memoryUsedFraction, percent(s.memoryUsedFraction),
                      String(format: "%.1f / %.0f GB", s.memoryUsedGB, s.memoryTotalGB),
                      .green, s.memoryTop))

        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "系统状态", icon: "cpu")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cards.count + 1),
                      spacing: 12) {
                ForEach(cards, id: \.title) { card in
                    GaugeCard(title: card.title, value: card.value,
                              center: card.center, sub: card.sub, color: card.color,
                              processes: card.processes)
                }
                FanTempCard(snapshot: s)
            }
        }
    }

    private func percent(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }

    private func freqText(_ mhz: Int?) -> String? {
        guard let mhz, mhz > 0 else { return nil }
        return mhz >= 1000 ? String(format: "%.1f GHz", Double(mhz) / 1000)
                           : "\(mhz) MHz"
    }
}

private struct GaugeCard: View {
    let title: String
    let value: Double // 0...1
    let center: String
    var sub: String? = nil
    let color: Color
    var processes: [SystemMonitor.ProcessUsage]? = nil

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
                            .font(.system(size: d * 0.19, weight: .semibold).monospacedDigit())
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        if let sub {
                            Text(sub)
                                .font(.system(size: d * 0.09).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: d * 0.75)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            // Fixed ring area keeps every tile identical and the page scroll-free.
            .frame(height: 150)
            .padding(.top, 10)

            // Top-3 process list inside the tile. Fixed height (3 rows) so all
            // tiles stay the same height even when a tile has no data.
            VStack(spacing: 4) {
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
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 66)
        }
        .padding(.top, 14)
        // The 25pt stroke overhangs the ring frame by 12.5pt; keep extra
        // bottom room so the ring never touches the tile edge.
        .padding(.bottom, 18)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Fan RPM + temperature tile (same footprint as the gauge tiles).
/// The ring shows fan 0 RPM against the 5500 RPM max.
private struct FanTempCard: View {
    let snapshot: SystemMonitor.Snapshot

    private let maxRPM: Double = 5500

    var body: some View {
        VStack(spacing: 0) {
            Text("风扇 / 温度")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                let lineWidth: CGFloat = 25
                ZStack {
                    Circle()
                        .stroke(Color.orange.opacity(0.18), lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: fanFraction)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: fanFraction)
                    VStack(spacing: 1) {
                        Text(fanCenter)
                            .font(.system(size: d * 0.19, weight: .semibold).monospacedDigit())
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text("RPM")
                            .font(.system(size: d * 0.09))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: d * 0.75)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: 150)
            .padding(.top, 10)

            VStack(spacing: 4) {
                sensorRow("CPU 温度", value: temp(snapshot.cpuTempC))
                sensorRow("GPU 温度", value: temp(snapshot.gpuTempC))
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 66)
        }
        .padding(.top, 14)
        .padding(.bottom, 18)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Average RPM across all fans (shown in the ring center and used for
    /// the ring fraction).
    private var avgFanRPM: Double? {
        guard let f0 = snapshot.fanRPM else { return nil }
        if let f1 = snapshot.fan2RPM { return (f0 + f1) / 2 }
        return f0
    }

    private var fanFraction: Double {
        guard let rpm = avgFanRPM else { return 0 }
        return min(max(rpm / maxRPM, 0), 1)
    }

    private var fanCenter: String {
        avgFanRPM.map { "\(Int($0))" } ?? "无风扇"
    }

    private func temp(_ v: Double?) -> String {
        v.map { String(format: "%.1f °C", $0) } ?? "-"
    }

    private func sensorRow(_ label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()
        }
    }
}
