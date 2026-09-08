import SwiftUI

// MARK: - Kimi sessions

struct KimiSessionsSection: View {
    @EnvironmentObject var monitor: SessionMonitor

    var body: some View {
        SessionsSection(
            title: "Kimi 会话",
            icon: "terminal",
            entries: monitor.entries.map { SessionEntry(from: $0) }
        )
    }
}

// MARK: - Claude sessions

struct ClaudeSessionsSection: View {
    @EnvironmentObject var monitor: ClaudeSessionMonitor
    @EnvironmentObject var tokens: ClaudeTokenMonitor

    var body: some View {
        let entries = monitor.entries.map { SessionEntry(from: $0) }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Claude 会话", icon: "sparkles")

                let columns = Array(repeating: GridItem(.flexible(), spacing: 14),
                                    count: min(entries.count, 4))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(entries) { entry in
                        SessionTile(entry: entry, tokenTally: tokens)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    var body: some View {
        if !entries.isEmpty {
            // Max 4 tiles per row; fewer tiles stretch to fill the width.
            let columns = Array(repeating: GridItem(.flexible(), spacing: 14),
                                count: min(entries.count, 4))
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: title, icon: icon)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(entries) { entry in
                        SessionTile(entry: entry)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Tile

private struct SessionTile: View {
    let entry: SessionEntry
    var tokenTally: ClaudeTokenMonitor? = nil
    @State private var breathing = false

    private var statusColor: Color {
        switch entry.effective {
        case .working:     return .blue
        case .waitingUser: return .orange
        case .idle:        return .green
        case .offline:     return .gray
        }
    }

    private var isBreathing: Bool { entry.effective == .waitingUser }

    var body: some View {
        HStack(spacing: 16) {
            // ── Status dot ──────────────────────────────────────
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

            // ── Left: status / time / cwd ────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.effective.label)
                    .font(.callout.weight(.semibold))
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

            Spacer(minLength: 8)

            // ── Right: token counts (Claude only) ───────────────
            if let t = tokenTally {
                tokenColumn(t)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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

    @ViewBuilder
    private func tokenColumn(_ t: ClaudeTokenMonitor) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            tokenRow(label: "今日", input: t.today.input, output: t.today.output)
            tokenRow(label: "近7天", input: t.week.input,  output: t.week.output)
        }
    }

    @ViewBuilder
    private func tokenRow(label: String, input: Int, output: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)

            HStack(spacing: 3) {
                Image(systemName: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(fmt(input))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 3) {
                Image(systemName: "arrow.up.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(fmt(output))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
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
