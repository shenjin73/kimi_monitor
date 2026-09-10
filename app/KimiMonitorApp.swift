import SwiftUI

@main
struct KimiMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    @StateObject private var sessions = SessionMonitor.shared
    @StateObject private var claudeSessions = ClaudeSessionMonitor.shared
    @StateObject private var claudeTokens = ClaudeTokenMonitor.shared
    @StateObject private var dshSessions = DshSessionMonitor.shared
    @StateObject private var quota = QuotaMonitor.shared
    @StateObject private var deepSeek = DeepSeekMonitor.shared
    @StateObject private var system = SystemMonitor.shared

    var body: some Scene {
        WindowGroup("Kimi Monitor", id: "main") {
            MainView()
                .environmentObject(sessions)
                .environmentObject(claudeSessions)
                .environmentObject(claudeTokens)
                .environmentObject(dshSessions)
                .environmentObject(quota)
                .environmentObject(deepSeek)
                .environmentObject(system)
                .onAppear {
                    sessions.start()
                    claudeSessions.start()
                    claudeTokens.start()
                    dshSessions.start()
                    quota.start()
                    deepSeek.start()
                    system.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                    openWindow(id: "main")
                }
        }
        .defaultSize(width: 860, height: 700)
    }
}
