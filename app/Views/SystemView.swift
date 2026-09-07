import SwiftUI

struct SystemSection: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        let s = monitor.snapshot
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

// MARK: - Ring

/// A single-colour ring gauge with a tubular 3-D feel. The lighting runs
/// *across* the stroke width (inner edge shaded, outer edge lit) so the arc
/// reads as one continuous rounded tube instead of two stacked colours.
struct Ring3D: View {
    let value: Double   // 0…1
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let clamped = min(max(value, 0), 1)

            ZStack {
                // ── Track — flat light single colour ──────────────
                Circle()
                    .stroke(color.opacity(0.16), lineWidth: lineWidth)

                // ── Filled arc — tubular ──────────────────────────
                if clamped > 0 {
                    let arc = Circle()
                        .trim(from: 0, to: clamped)
                        .rotation(.degrees(-90))

                    // Solid base
                    arc.stroke(color,
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                    // Inner-edge shade: darker band on the inner half of the tube
                    arc.stroke(Color.black.opacity(0.28),
                               style: StrokeStyle(lineWidth: lineWidth * 0.5, lineCap: .round))
                        .padding(lineWidth * 0.25)
                        .blur(radius: lineWidth * 0.14)

                    // Outer-edge highlight: bright band on the outer half
                    arc.stroke(Color.white.opacity(0.50),
                               style: StrokeStyle(lineWidth: lineWidth * 0.30, lineCap: .round))
                        .padding(-lineWidth * 0.27)
                        .blur(radius: lineWidth * 0.1)
                }
            }
            // Keep highlight/shade inside the ring band so nothing spills.
            .frame(width: size, height: size)
            .mask(
                Circle().stroke(Color.black, lineWidth: lineWidth + 1)
            )
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.30), radius: 5, x: 0, y: 3)
            .animation(.easeInOut(duration: 0.3), value: value)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Gauge card

private struct GaugeCard: View {
    let title: String
    let value: Double
    let center: String
    var sub: String? = nil
    let color: Color
    var processes: [SystemMonitor.ProcessUsage]? = nil

    private let lineWidth: CGFloat = 25

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                ZStack {
                    Ring3D(value: value, color: color, lineWidth: lineWidth)

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
            .frame(height: 150)
            .padding(.top, 10)

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
        .padding(.bottom, 18)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Fan / Temp card

private struct FanTempCard: View {
    let snapshot: SystemMonitor.Snapshot

    private let maxRPM: Double = 5500
    private let lineWidth: CGFloat = 25

    var body: some View {
        VStack(spacing: 0) {
            Text("风扇 / 温度")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                ZStack {
                    Ring3D(value: fanFraction, color: .orange, lineWidth: lineWidth)

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
