import AppKit
import SwiftUI

/// Keeps the menu-bar status item alongside the main window.
/// Left-click shows the classic session dropdown; "打开主窗口" opens the window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatusItem()
        }
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let entries = allEntries()
        if entries.isEmpty {
            button.title = "◦ 无会话"
        } else {
            let dot = entries.map(\.effective).min(by: { $0.rank < $1.rank })?.dot ?? "⚪"
            button.title = "\(dot) \(entries.count)"
        }
        button.toolTip = "Kimi Monitor: \(entries.count) 个工作中的会话（Kimi / Claude / DSH）"
        rebuildMenu(entries)
    }

    /// Only sessions that are working or waiting for the user — the same rule
    /// the dashboard uses. Idle and offline sessions never reach the menu.
    private func allEntries() -> [MenuEntry] {
        func keep(_ status: EffectiveStatus) -> Bool {
            status == .working || status == .waitingUser
        }
        var entries: [MenuEntry] = SessionMonitor.shared.entries
            .filter { keep($0.effective) }
            .map { MenuEntry(kind: .kimi, effective: $0.effective,
                             title: $0.state.session_title, fallback: $0.state.session_id) }
        entries += ClaudeSessionMonitor.shared.entries
            .filter { keep($0.effective) }
            .map { MenuEntry(kind: .claude, effective: $0.effective,
                             title: $0.state.session_title, fallback: $0.state.session_id) }
        entries += DshSessionMonitor.shared.entries
            .filter { keep($0.effective) }
            .map { MenuEntry(kind: .dsh, effective: $0.effective,
                             title: $0.title, fallback: $0.sessionId) }
        return entries.sorted {
            if $0.effective.rank != $1.effective.rank { return $0.effective.rank < $1.effective.rank }
            return $0.displayTitle < $1.displayTitle
        }
    }

    private func rebuildMenu(_ entries: [MenuEntry]) {
        let menu = NSMenu()

        let open = NSMenuItem(title: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        if entries.isEmpty {
            let empty = NSMenuItem(title: "没有工作中的会话", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in entries {
                let item = NSMenuItem(
                    title: "\(entry.effective.dot) \(entry.kind.label) · \(entry.displayTitle) — \(entry.effective.label)",
                    action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Kimi Monitor", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Bring an existing window forward, or ask SwiftUI to open one.
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Kimi Monitor" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("kimi_monitor.openMainWindow")
}

/// One row of the menu-bar dropdown, normalized across session kinds.
private struct MenuEntry {
    let kind: SessionKind
    let effective: EffectiveStatus
    let title: String?
    let fallback: String

    var displayTitle: String {
        guard let title, !title.isEmpty else { return fallback }
        return title
    }
}
