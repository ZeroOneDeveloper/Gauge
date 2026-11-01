import SwiftUI
import AppKit
import GaugeCore

@main
struct GaugeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()
    var body: some Scene {
        Window("Gauge", id: "dashboard") {
            DashboardScene(delegate: delegate).environmentObject(store).preferredColorScheme(.light)
        }
        .defaultSize(width: 1140, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("계정 추가…") { store.showAddAccount = true }.keyboardShortcut("n")
                Button("사용량 새로고침") { Task { await store.refreshAll() } }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .appSettings) {
                Button("설정…") { store.page = .settings; NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut(",")
            }
        }
    }
}

private struct DashboardScene: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate
    var body: some View {
        DashboardView()
            .onAppear {
                delegate.configureMenuBar(store: store) {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: StatusBarController?
    func configureMenuBar(store: AppStore, openDashboard: @escaping () -> Void) {
        guard menuBar == nil else { return }
        menuBar = StatusBarController(store: store, openDashboard: openDashboard)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { ClaudeLocalAuth.shared.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.identifier?.rawValue == "dashboard" || $0.title == "Gauge" })?.makeKeyAndOrderFront(nil) }
        return true
    }
}
