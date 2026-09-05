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
        let monitor = SessionMonitor.shared
        guard let button = statusItem.button else { return }
        if monitor.entries.isEmpty {
            button.title = "◦ Kimi"
        } else {
            let dot = monitor.aggregate?.dot ?? "⚪"
            button.title = "\(dot) \(monitor.entries.count)"
        }
        button.toolTip = "Kimi Monitor: \(monitor.entries.count) 个会话"
        rebuildMenu(monitor.entries)
    }

    private func rebuildMenu(_ entries: [SessionMonitor.Entry]) {
        let menu = NSMenu()

        let open = NSMenuItem(title: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        if entries.isEmpty {
            let empty = NSMenuItem(title: "没有活动会话", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in entries {
                let title = entry.state.session_title?.isEmpty == false
                    ? entry.state.session_title! : entry.state.session_id
                let item = NSMenuItem(
                    title: "\(entry.effective.dot) \(title) — \(entry.effective.label)",
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
