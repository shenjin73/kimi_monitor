import SwiftUI

@main
struct KimiMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    @StateObject private var sessions = SessionMonitor.shared
    @StateObject private var quota = QuotaMonitor.shared
    @StateObject private var system = SystemMonitor.shared

    var body: some Scene {
        WindowGroup("Kimi Monitor", id: "main") {
            MainView()
                .environmentObject(sessions)
                .environmentObject(quota)
                .environmentObject(system)
                .onAppear {
                    sessions.start()
                    quota.start()
                    system.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                    openWindow(id: "main")
                }
        }
        .defaultSize(width: 800, height: 540)
    }
}
