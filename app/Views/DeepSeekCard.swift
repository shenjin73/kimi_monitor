import SwiftUI

/// The DeepSeek tile in the 「套餐用量」 row.
///
/// It shares the row with the Kimi quota cards, so it is only ~1/3 of the
/// window wide: the numbers are stacked as label/value rows rather than laid
/// out in a horizontal band, and every row is short enough to survive the
/// narrowest window.
///
/// The numbers come from the open platform when a web `userToken` is
/// configured; without one the tile falls back to local dsh session totals and
/// labels itself accordingly, so a missing token never reads as missing data.
struct DeepSeekUsageCard: View {
    @EnvironmentObject var monitor: DeepSeekMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let usage = monitor.usage {
                metrics(usage)
            } else {
                Text("正在读取…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            ForEach(errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        // Fill the grid row so this tile's background matches the quota cards'.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("DeepSeek充值余额")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            balanceValue
        }
    }

    @ViewBuilder
    private var balanceValue: some View {
        if let info = monitor.balance?.balance_infos?.first, let total = info.total {
            Text(money(total, symbol: info.symbol))
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(balanceColor(info))
                .help(balanceTooltip(info))
        } else if monitor.isRefreshing {
            ProgressView()
                .controlSize(.small)
        } else {
            Text("余额 -")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tertiary)
                .help(monitor.balanceError ?? "DeepSeek 余额加载中…")
        }
    }

    // MARK: - Metrics

    /// Label/value rows, so a long number can never push its neighbour out of
    /// the tile the way a horizontal band would.
    private func metrics(_ usage: DeepSeekUsage) -> some View {
        VStack(spacing: 4) {
            metric("累计token使用量", formatTokens(usage.totalTokens), help: tokenTooltip(usage))

            // Today is shown in both modes: the platform reports it directly,
            // the local fallback replays dsh's session logs for it.
            if let todayTokens = usage.todayTokens {
                let spend = usage.todayCost.map { " · " + money($0, symbol: usage.symbol) } ?? ""
                metric("今日token使用量", formatTokens(todayTokens) + spend, help: todayTooltip(usage))
            } else if let reason = usage.todayError {
                metric("今日token使用量", "—", help: reason)
            }

            if let requests = usage.requests {
                metric("请求", "\(requests)", help: "开放平台统计区间内的请求次数")
            }
        }
    }

    private func metric(_ label: String, _ value: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Text(value)
                .font(.caption.weight(.medium).monospacedDigit())
                .lineLimit(1)
        }
        .help(help)
    }

    private func tokenTooltip(_ usage: DeepSeekUsage) -> String {
        var lines = [
            "输入 \(usage.inputTokens.formatted())（缓存未命中）",
            "缓存命中 \(usage.cacheReadTokens.formatted())",
            "输出 \(usage.outputTokens.formatted())",
        ]
        if let since = usage.since {
            lines.append("累计区间 \(since) 起（平台保留期）")
        } else {
            lines.append("本机 dsh 会话投影缓存累计（含全部会话，不分模型）")
        }
        return lines.joined(separator: "\n")
    }

    private func todayTooltip(_ usage: DeepSeekUsage) -> String {
        usage.source == .platform
            ? "开放平台今日（GMT+8）的 token"
            : "本机全部 dsh 会话今天的 token 合计\n（回放会话日志按消息时间戳统计，本地时区）"
    }

    private var errors: [String] {
        var result: [String] = []
        if let error = monitor.balanceError { result.append("余额：\(error)") }
        if let error = monitor.platformError { result.append("平台数据：\(error)") }
        return result
    }

    // MARK: - Formatting

    private func money(_ value: Double, symbol: String) -> String {
        String(format: "%@%.2f", symbol, value)
    }

    private func amount(_ value: Double?, _ symbol: String) -> String {
        value.map { money($0, symbol: symbol) } ?? "-"
    }

    private func balanceColor(_ info: DeepSeekBalance.Info) -> Color {
        guard let total = info.total else { return .secondary }
        if monitor.balance?.is_available == false || total <= 1 { return .red }
        if total <= 5 { return .orange }
        return .primary
    }

    private func balanceTooltip(_ info: DeepSeekBalance.Info) -> String {
        "DeepSeek \(info.currency ?? "") 余额：总 \(amount(info.total, info.symbol))"
            + "，赠送 \(amount(info.granted, info.symbol))"
            + "，充值 \(amount(info.toppedUp, info.symbol))"
    }
}
