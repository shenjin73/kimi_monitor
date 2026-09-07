import SwiftUI

// MARK: - Kimi sessions

struct KimiSessionsSection: View {
    @EnvironmentObject var monitor: SessionMonitor

    var body: some View {
        SessionsSection(
            title: "Kimi 会话",
            icon: "terminal",
            entries: monitor.entries.map { SessionEntry(from: $0) },
            emptyHint: "没有活动会话 — 启动 Kimi CLI 会话后会显示在这里"
        )
    }
}

// MARK: - Claude sessions

struct ClaudeSessionsSection: View {
    @EnvironmentObject var monitor: ClaudeSessionMonitor

    var body: some View {
        SessionsSection(
            title: "Claude 会话",
            icon: "sparkles",
            entries: monitor.entries.map { SessionEntry(from: $0) },
            emptyHint: "没有活动会话 — 安装 Claude CLI hook 后会显示在这里"
        )
    }
}

// MARK: - Shared model

struct SessionEntry: Identifiable {
    let id: String
    let effective: EffectiveStatus
    let sessionId: String
    let sessionTitle: String?
    let cwd: String?
    let updatedAt: Double?
    let event: String?

    init(from e: SessionMonitor.Entry) {
        id = e.state.session_id
        effective = e.effective
        sessionId = e.state.session_id
        sessionTitle = e.state.session_title
        cwd = e.state.cwd
        updatedAt = e.state.updated_at
        event = e.state.event
    }

    init(from e: ClaudeSessionMonitor.Entry) {
        id = e.state.session_id
        effective = e.effective
        sessionId = e.state.session_id
        sessionTitle = e.state.session_title
        cwd = e.state.cwd
        updatedAt = e.state.updated_at
        event = e.state.event
    }
}

// MARK: - Generic section

private struct SessionsSection: View {
    let title: String
    let icon: String
    let entries: [SessionEntry]
    let emptyHint: String

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, icon: icon)

            if entries.isEmpty {
                Text(emptyHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(entries) { entry in
                        SessionTile(entry: entry)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tile

private struct SessionTile: View {
    let entry: SessionEntry
    @State private var breathing = false

    private var statusColor: Color {
        switch entry.effective {
        case .working: return .blue
        case .waitingUser: return .orange
        case .idle: return .green
        case .offline: return .gray
        }
    }

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
                .onChange(of: isBreathing) { _, new in breathing = new }

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.effective.label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(statusColor)

                Text(updatedText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Text(cwdText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            if let cwd = entry.cwd {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
                }
            }
            Button("复制 Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.sessionId, forType: .string)
            }
        }
        .help(entry.sessionTitle ?? entry.sessionId)
    }

    private var cwdText: String {
        let path = entry.cwd ?? ""
        return path.isEmpty ? "-" : abbreviateHome(path)
    }

    private var updatedText: String {
        guard let ts = entry.updatedAt else { return "-" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: Date(timeIntervalSince1970: ts))
    }
}
