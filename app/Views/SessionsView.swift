import SwiftUI

struct SessionsSection: View {
    @EnvironmentObject var monitor: SessionMonitor

    // Same two-column flexible grid as the quota section, so tiles match
    // the quota cards in width and height.
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Kimi 会话", icon: "terminal")

            if monitor.entries.isEmpty {
                Text("没有活动会话 — 启动 Kimi CLI 会话后会显示在这里")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(monitor.entries) { entry in
                        SessionTile(entry: entry)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SessionTile: View {
    let entry: SessionMonitor.Entry
    @State private var breathing = false

    private var statusColor: Color {
        switch entry.effective {
        case .working: return .blue
        case .waitingUser: return .orange
        case .idle: return .green
        case .offline: return .gray
        }
    }

    /// 等待用户反馈时呼吸灯效果。
    private var isBreathing: Bool { entry.effective == .waitingUser }

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(statusColor)
                .frame(width: 56, height: 56)
                .shadow(color: statusColor.opacity(0.7), radius: breathing ? 14 : 8)
                .scaleEffect(breathing ? 1.25 : 1.0)
                .opacity(breathing ? 0.55 : 1.0)
                .animation(
                    isBreathing
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                    value: breathing
                )
                .onAppear { breathing = isBreathing }
                .onChange(of: isBreathing) { breathing = $0 }

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.effective.label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(statusColor)

                Text(updatedText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Text(cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            if let cwd = entry.state.cwd {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
                }
            }
            Button("复制 Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.state.session_id, forType: .string)
            }
        }
        .help(entry.state.session_title ?? entry.state.session_id)
    }

    private var cwd: String {
        let path = entry.state.cwd ?? ""
        return path.isEmpty ? "-" : abbreviateHome(path)
    }

    private var updatedText: String {
        guard let ts = entry.state.updated_at else { return "-" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: Date(timeIntervalSince1970: ts))
    }
}
