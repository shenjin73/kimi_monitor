import SwiftUI

// MARK: - Merged sessions
//
// One section for every CLI. A tile appears only while its session is working
// or waiting for the user — idle and offline sessions are not shown at all, and
// there are no per-tool sections left. The badge on each tile says which CLI
// the session belongs to.

struct SessionsSection: View {
    @EnvironmentObject var kimi: SessionMonitor
    @EnvironmentObject var claude: ClaudeSessionMonitor
    @EnvironmentObject var claudeTokens: ClaudeTokenMonitor
    @EnvironmentObject var dsh: DshSessionMonitor
    @EnvironmentObject var deepSeek: DeepSeekMonitor

    /// Every tracked session, whatever its state.
    private var allEntries: [SessionEntry] {
        var all = kimi.entries.map { SessionEntry(from: $0) }
        all += claude.entries.map { SessionEntry(from: $0) }
        all += dsh.entries.map { SessionEntry(from: $0) }
        return all
    }

    /// Everything worth looking at: working (blue) or waiting for the user
    /// (yellow), most attention-worthy first.
    private var entries: [SessionEntry] {
        allEntries
            .filter { $0.effective == .working || $0.effective == .waitingUser }
            .sorted {
                if $0.effective.rank != $1.effective.rank { return $0.effective.rank < $1.effective.rank }
                return ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0)
            }
    }

    var body: some View {
        let entries = self.entries
        let waiting = entries.filter { $0.effective == .waitingUser }.count
        let hidden = allEntries.count - entries.count

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "会话", icon: "rectangle.stack")
                Spacer()
                if waiting > 0 {
                    Text("🟠 \(waiting) 个在等你")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if entries.isEmpty {
                IdlePlaceholder(hidden: hidden)
            } else {
                // Max 4 tiles per row; fewer tiles stretch to fill the width.
                let columns = Array(repeating: GridItem(.flexible(), spacing: 14),
                                    count: min(entries.count, 4))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(entries) { entry in
                        SessionTile(entry: entry,
                                    tallies: tallies(for: entry),
                                    showsBalance: entry.kind == .dsh,
                                    balance: deepSeek.balance?.balance_infos?.first,
                                    balanceAvailable: deepSeek.balance?.is_available,
                                    balanceError: deepSeek.balanceError)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tallies(for entry: SessionEntry) -> [TokenTally] {
        switch entry.kind {
        case .kimi:
            return []
        case .claude:
            // Project-wide tallies: the same numbers on every Claude tile.
            return [
                TokenTally(label: "今日", input: claudeTokens.today.input, output: claudeTokens.today.output),
                TokenTally(label: "近7天", input: claudeTokens.week.input, output: claudeTokens.week.output),
            ]
        case .dsh:
            guard let tokens = entry.sessionTokens else { return [] }
            return [TokenTally(label: "本会话", input: tokens.input, output: tokens.output)]
        }
    }
}

// MARK: - Empty state

/// Shown when nothing is working or waiting, so the panel never silently
/// disappears — and so the hidden idle sessions are accounted for.
private struct IdlePlaceholder: View {
    let hidden: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.title3)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("无进行中的会话")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(hidden > 0 ? "\(hidden) 个空闲会话已隐藏" : "空闲会话不显示")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Shared model

enum SessionKind {
    case kimi
    case claude
    case dsh

    var label: String {
        switch self {
        case .kimi:   return "Kimi"
        case .claude: return "Claude"
        case .dsh:    return "DSH"
        }
    }

    var icon: String {
        switch self {
        case .kimi:   return "terminal"
        case .claude: return "sparkles"
        case .dsh:    return "hammer"
        }
    }

    /// Deliberately away from the status hues (blue/orange/green/gray) so the
    /// badge never reads as a state.
    var color: Color {
        switch self {
        case .kimi:   return .teal
        case .claude: return .purple
        case .dsh:    return .indigo
        }
    }
}

struct SessionEntry: Identifiable {
    let id: String
    let kind: SessionKind
    let effective: EffectiveStatus
    let sessionId: String
    let sessionTitle: String?
    let cwd: String?
    let updatedAt: Double?
    let event: String?
    /// Session-scoped token totals, when the source can provide them.
    let sessionTokens: (input: Int, output: Int)?

    init(from e: SessionMonitor.Entry) {
        id = e.state.session_id
        kind = .kimi
        effective = e.effective
        sessionId = e.state.session_id
        sessionTitle = e.state.session_title
        cwd = e.state.cwd
        updatedAt = e.state.updated_at
        event = e.state.event
        sessionTokens = nil
    }

    init(from e: ClaudeSessionMonitor.Entry) {
        id = e.state.session_id
        kind = .claude
        effective = e.effective
        sessionId = e.state.session_id
        sessionTitle = e.state.session_title
        cwd = e.state.cwd
        updatedAt = e.state.updated_at
        event = e.state.event
        sessionTokens = nil
    }

    init(from e: DshSessionMonitor.Entry) {
        id = e.sessionId
        kind = .dsh
        effective = e.effective
        sessionId = e.sessionId
        sessionTitle = e.title
        cwd = e.cwd
        updatedAt = e.updatedAt
        event = e.event
        sessionTokens = (e.inputTokens, e.outputTokens)
    }
}

/// One right-hand token row on a tile.
struct TokenTally {
    let label: String
    let input: Int
    let output: Int
}

// MARK: - Tile

private struct SessionTile: View {
    let entry: SessionEntry
    var tallies: [TokenTally] = []
    var showsBalance: Bool = false
    var balance: DeepSeekBalance.Info? = nil
    var balanceAvailable: Bool? = nil
    var balanceError: String? = nil
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

            // ── Left: tool badge / status / time / title / cwd ──
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ToolBadge(kind: entry.kind)
                    Text(entry.effective.label)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                Text(updatedText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                if let title = entry.sessionTitle, !title.isEmpty {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(cwdText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            // ── Right: per-tool numbers ─────────────────────────
            if !tallies.isEmpty || showsBalance {
                tokenColumn
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            if let cwd = entry.cwd, !cwd.isEmpty {
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

    private var tokenColumn: some View {
        VStack(alignment: .trailing, spacing: 5) {
            ForEach(Array(tallies.enumerated()), id: \.offset) { _, tally in
                tokenRow(label: tally.label, input: tally.input, output: tally.output)
            }
            if showsBalance { balanceRow() }
        }
    }

    @ViewBuilder
    private func tokenRow(label: String, input: Int, output: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)

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

    /// Compact account balance (the same account for every DSH tile, so the
    /// per-currency breakdown lives in the tooltip rather than on the tile).
    /// Loading and failure are distinct so a silent API error cannot look like
    /// a missing feature.
    private func balanceRow() -> some View {
        HStack(spacing: 6) {
            Text("余额")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)

            if let balance {
                Text(balance.total.map { String(format: "%@%.2f", balance.symbol, $0) } ?? "-")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(balanceColor(balance))
                if balanceAvailable == false {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            } else if balanceError != nil {
                Text("查询失败")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text("…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .help(balanceTooltip)
    }

    private var balanceTooltip: String {
        if let balance {
            return "DeepSeek \(balance.currency ?? "") 余额：总 \(amount(balance.total))，"
                + "赠送 \(amount(balance.granted))，充值 \(amount(balance.toppedUp))"
        }
        if let balanceError { return "DeepSeek 余额查询失败：\(balanceError)" }
        return "DeepSeek 余额加载中…"
    }

    private func amount(_ value: Double?) -> String {
        value.map { String(format: "%@%.2f", balance?.symbol ?? "", $0) } ?? "-"
    }

    private func balanceColor(_ info: DeepSeekBalance.Info) -> Color {
        guard let total = info.total else { return .secondary }
        if balanceAvailable == false || total <= 1 { return .red }
        if total <= 5 { return .orange }
        return .secondary
    }

    private func fmt(_ n: Int) -> String { formatTokens(n) }

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

// MARK: - Tool badge

private struct ToolBadge: View {
    let kind: SessionKind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.icon)
                .font(.caption2)
            Text(kind.label)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(kind.color)
        .background(kind.color.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(kind.color.opacity(0.35), lineWidth: 0.5))
    }
}
