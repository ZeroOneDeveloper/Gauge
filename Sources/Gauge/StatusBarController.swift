import AppKit
import SwiftUI
import Combine

/// Own the status item explicitly so it can also be opened from the dashboard.
/// Its lifetime belongs to the app delegate and is independent of dashboard windows.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let store: AppStore
    private let openDashboard: () -> Void
    private var observation: AnyCancellable?

    init(store: AppStore, openDashboard: @escaping () -> Void) {
        self.store = store
        self.openDashboard = openDashboard
        super.init()

        statusItem.autosaveName = "Gauge.usage"
        statusItem.isVisible = true
        if let button = statusItem.button {
            let icon = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Gauge")
            icon?.isTemplate = true
            button.image = icon
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityIdentifier("gauge-usage-menu")
            button.setAccessibilityLabel("Gauge 사용량 메뉴")
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView:
            MenuPopover(dashboardAction: { [weak self] in self?.showDashboard() })
                .environmentObject(store)
                .preferredColorScheme(.light)
        )
        store.openMenuBar = { [weak self] in self?.showPopover() }
        observation = store.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before published values are updated.
            DispatchQueue.main.async { self?.updateLabel() }
        }
        updateLabel()
    }

    private func updateLabel() {
        guard let button = statusItem.button else { return }
        let hasAccounts = !store.accounts.isEmpty
        statusItem.length = hasAccounts ? NSStatusItem.variableLength : NSStatusItem.squareLength
        button.title = hasAccounts ? " " + store.menuLabel : ""
        button.toolTip = hasAccounts
            ? "Gauge · \(store.pinnedProvider?.title ?? "계정") 전체 잔여 한도 · 계정당 100% 기준 · 클릭하여 기간별 합계 확인"
            : "Gauge · 클릭하여 Claude·Codex 계정 연결"
        let rowsHeight = store.accounts.reduce(CGFloat(32)) { total, account in
            total + 105 + CGFloat(store.snapshots[account.id.uuidString]?.windows.count ?? 1) * 32
        } + CGFloat(max(0, store.accounts.count - 1)) * 16
        let summaryHeight = CGFloat(115 + store.combinedQuotas.count * 55)
        let desiredHeight: CGFloat = hasAccounts ? 200 + min(580, rowsHeight + summaryHeight) : 280
        let screenHeight = button.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 800
        let size = NSSize(width: 400, height: min(desiredHeight, max(280, screenHeight - 30)))
        if popover.contentSize != size { popover.contentSize = size }
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        guard !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showDashboard() {
        popover.performClose(nil)
        openDashboard()
    }
}
