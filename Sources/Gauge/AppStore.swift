import AppKit
import Combine
import ServiceManagement
import UserNotifications
import GaugeCore

enum AppPage: String, CaseIterable, Identifiable {
    case overview, history, accounts, settings
    var id: String { rawValue }
    var title: String { switch self { case .overview: "대시보드"; case .history: "사용량 기록"; case .accounts: "계정 관리"; case .settings: "설정" } }
    var icon: String { switch self { case .overview: "square.grid.2x2"; case .history: "chart.xyaxis.line"; case .accounts: "person.crop.rectangle.stack"; case .settings: "slider.horizontal.3" } }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var state = PersistedState()
    @Published var page: AppPage = .overview
    @Published var providerFilter: Provider?
    @Published var showAddAccount = false
    @Published private(set) var isConnectingLocal = false
    @Published private(set) var refreshing: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var keychainAccessNeeded: Set<UUID> = []
    @Published private(set) var authorizingKeychain: Set<UUID> = []
    @Published var globalError: String?
    @Published var now = Date()
    var openMenuBar: (() -> Void)?
    private var pollTask: Task<Void, Never>?
    private var nextRefresh: [UUID: Date] = [:]
    private var failures: [UUID: Int] = [:]
    private var tracker = ThresholdTracker()
    private var sleeping = false
    private var storageHealthy = true
    private var observers: [NSObjectProtocol] = []
    private var reauthenticating: Set<UUID> = []
    private let saveState: (PersistedState) throws -> Void

    var accounts: [Account] {
        Provider.allCases.flatMap { provider in
            state.accounts.filter { $0.provider == provider }
        }
    }
    var snapshots: [String: UsageSnapshot] { state.snapshots }
    var history: [String: [HistorySample]] { state.history }
    var visibleAccounts: [Account] { accounts.filter { providerFilter == nil || $0.provider == providerFilter } }
    var pinnedAccount: Account? { accounts.first { $0.id == state.pinnedAccountID } ?? accounts.first }
    var pinnedProvider: Provider? { pinnedAccount?.provider }
    var combinedQuotas: [CombinedQuota] {
        guard let provider = pinnedProvider else { return [] }
        return ProviderQuota.combine(provider: provider, accounts: accounts, snapshots: snapshots, unavailable: Set(errors.keys), now: now)
    }
    var menuLabel: String {
        guard let provider = pinnedProvider else { return "Gauge" }
        guard let window = ProviderQuota.menuWindow(combinedQuotas) else { return "\(provider.title) · —" }
        return "\(provider.title) \(window.title) \(window.remainingLabel.replacingOccurrences(of: " ", with: "")) 남음"
    }
    var lastUpdated: Date? { accounts.compactMap { snapshots[$0.id.uuidString]?.fetchedAt }.max() }
    var isRefreshing: Bool { !refreshing.isEmpty }

    init(initialState: PersistedState? = nil, automaticallyRefresh: Bool = true,
         saveState: @escaping (PersistedState) throws -> Void = LocalStorage.save) {
        self.saveState = saveState
        do { state = try initialState ?? LocalStorage.load() }
        catch {
            storageHealthy = false
            globalError = "저장된 계정 정보를 열지 못했어요. 기존 파일을 보호하기 위해 저장을 중단했습니다. \(error.localizedDescription)"
        }
        guard automaticallyRefresh else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.nextRefresh.removeAll() }
        })
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.now = Date()
                if !self.sleeping {
                    for account in self.state.accounts {
                        if Task.isCancelled { return }
                        if self.nextRefresh[account.id, default: .distantPast] <= Date() {
                            await self.refresh(account)
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                    }
                }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    private func commit(_ newState: PersistedState) throws {
        guard storageHealthy else { throw GaugeError.message("기존 데이터 파일을 읽을 수 없어 저장이 중단되어 있어요.") }
        try saveState(newState)
        state = newState
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        for account in state.accounts {
            // Manual refresh respects rate limiting and transient-error backoff too.
            guard failures[account.id, default: 0] == 0 || nextRefresh[account.id, default: .distantPast] <= Date() else { continue }
            await refresh(account)
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
    func refresh(_ account: Account) async {
        guard !sleeping, state.accounts.contains(where: { $0.id == account.id }), !refreshing.contains(account.id), !reauthenticating.contains(account.id) else { return }
        refreshing.insert(account.id)
        defer { refreshing.remove(account.id) }
        do {
            let snapshot: UsageSnapshot
            if account.provider == .claude {
                let secret: String
                if account.kind == .claudeLocal {
                    let local = try await ClaudeLocalAuth.shared.account(expectedIdentity: account.identity)
                    secret = local.accessToken
                } else if account.kind == .claudeCode {
                    let local = try await ClaudeProfile.account(account.id)
                    if let email = local.email { try LocalAccounts.assertIdentity(expected: account.identity, actual: email) }
                    secret = local.accessToken
                } else { secret = try CredentialVault.read(account.id) }
                snapshot = try await ClaudeService.shared.usage(account: account, secret: secret)
            } else {
                let connection = CodexConnection()
                defer { connection.close() }
                let local = account.kind == .codexLocal
                try await connection.start(accountID: account.id, homeOverride: local ? LocalAccounts.codexHome : nil, useExistingAuth: local)
                guard let info = try await connection.account() else { throw GaugeError.unauthorized }
                if local { try LocalAccounts.assertIdentity(expected: account.identity, actual: info.email) }
                snapshot = try await connection.usage()
            }
            guard state.accounts.contains(where: { $0.id == account.id }) else { return }
            try record(snapshot, account: account)
            failures[account.id] = 0
            errors.removeValue(forKey: account.id)
            keychainAccessNeeded.remove(account.id)
            nextRefresh[account.id] = Date().addingTimeInterval(Double(state.refreshInterval))
            await notify(account: account, snapshot: snapshot)
        } catch is CancellationError { return }
        catch {
            guard state.accounts.contains(where: { $0.id == account.id }) else { return }
            if case GaugeError.keychainBusy = error {
                // Another account's explicit authorization is holding the
                // process-wide UI policy. This account has not lost access.
                nextRefresh[account.id] = Date().addingTimeInterval(2)
                return
            }
            errors[account.id] = error.localizedDescription
            if case GaugeError.keychainAccessRequired = error {
                if account.kind == .claudeLocal {
                    errors[account.id] = "Claude Code와 공유한 로그인에 접근할 수 없어요. 계정 관리의 ‘로그인 연결 복구’로 전용 로그인을 연결해 주세요. 기존 기록은 유지됩니다."
                } else { keychainAccessNeeded.insert(account.id) }
            }
            failures[account.id, default: 0] += 1
            var retryAfter: Int?
            if case GaugeError.rateLimited(let delay) = error { retryAfter = delay }
            if case GaugeError.unauthorized = error { retryAfter = 3600 }
            nextRefresh[account.id] = Date().addingTimeInterval(RefreshPolicy.delay(failures: failures[account.id]!, interval: state.refreshInterval, retryAfter: retryAfter))
        }
    }

    func authorizeKeychain(_ account: Account) async {
        guard !refreshing.contains(account.id), !authorizingKeychain.contains(account.id) else { return }
        authorizingKeychain.insert(account.id)
        defer { authorizingKeychain.remove(account.id) }
        do {
            try await Task.detached {
                if account.kind == .claudeLocal {
                    _ = try LocalAccounts.claude(allowInteraction: true)
                } else if account.kind == .claudeCode {
                    try ClaudeProfile.authorize(account.id)
                } else if account.provider == .claude {
                    _ = try CredentialVault.read(account.id, allowInteraction: true)
                }
            }.value
            keychainAccessNeeded.remove(account.id)
            await refresh(account)
        } catch { errors[account.id] = error.localizedDescription }
    }

    func beginReauthentication(_ account: Account) throws {
        guard !refreshing.contains(account.id) else { throw GaugeError.message("갱신이 끝난 뒤 다시 로그인해 주세요.") }
        reauthenticating.insert(account.id)
    }
    func endReauthentication(_ account: Account) { reauthenticating.remove(account.id) }

    func finishReauthentication(_ original: Account, replacement: Account, snapshot: UsageSnapshot) throws {
        try LocalAccounts.assertIdentity(expected: original.identity, actual: replacement.identity)
        guard replacement.id == original.id, replacement.provider == original.provider,
              let index = state.accounts.firstIndex(where: { $0.id == original.id }) else { throw GaugeError.unsupported }
        var updated = state
        var account = replacement
        account.name = original.name
        account.createdAt = original.createdAt
        updated.accounts[index] = account
        updated.snapshots[account.id.uuidString] = snapshot
        updated.history[account.id.uuidString, default: []].append(HistorySample(date: snapshot.fetchedAt, windows: snapshot.windows))
        try commit(updated)
        errors.removeValue(forKey: account.id)
        keychainAccessNeeded.remove(account.id)
        failures.removeValue(forKey: account.id)
        nextRefresh[account.id] = Date().addingTimeInterval(Double(state.refreshInterval))
    }

    private func record(_ snapshot: UsageSnapshot, account: Account) throws {
        var updated = state
        let key = account.id.uuidString
        updated.snapshots[key] = snapshot
        if let plan = snapshot.plan, let index = updated.accounts.firstIndex(where: { $0.id == account.id }) { updated.accounts[index].plan = plan }
        var samples = updated.history[key, default: []].filter { $0.date > Date().addingTimeInterval(-30 * 86400) }
        if samples.last.map({ snapshot.fetchedAt.timeIntervalSince($0.date) >= 300 }) ?? true {
            samples.append(HistorySample(date: snapshot.fetchedAt, windows: snapshot.windows))
        }
        updated.history[key] = Array(samples.suffix(8640))
        try commit(updated)
        now = Date()
    }

    func saveClaude(name: String, secret: String, kind: ConnectionKind, organization: ClaudeOrganization?) async throws {
        let identity = await ClaudeService.shared.identity(secret: secret, kind: kind)
        let account = Account(provider: .claude, name: name, identity: identity,
                              organizationID: organization?.id, organizationName: organization?.name, kind: kind)
        let snapshot = try await ClaudeService.shared.usage(account: account, secret: secret)
        try Task.checkCancellation()
        try CredentialVault.write(secret, for: account.id)
        do { try add(account, snapshot: snapshot) }
        catch { try? CredentialVault.delete(account.id); throw error }
    }

    func add(_ account: Account, snapshot: UsageSnapshot) throws {
        if let identity = account.identity, !identity.isEmpty,
           state.accounts.contains(where: {
               $0.provider == account.provider && $0.identity?.caseInsensitiveCompare(identity) == .orderedSame &&
               ($0.organizationID == account.organizationID || $0.organizationID == nil || account.organizationID == nil)
           }) {
            throw GaugeError.message("이미 연결된 \(account.provider.title) 계정입니다. 계정 관리에서 확인해 주세요.")
        }
        var updated = state
        updated.accounts.append(account)
        if updated.pinnedAccountID == nil { updated.pinnedAccountID = account.id }
        updated.snapshots[account.id.uuidString] = snapshot
        updated.history[account.id.uuidString] = [HistorySample(date: snapshot.fetchedAt, windows: snapshot.windows)]
        try commit(updated)
        nextRefresh[account.id] = Date().addingTimeInterval(Double(state.refreshInterval))
    }

    func rename(_ account: Account, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = state.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        var updated = state; updated.accounts[index].name = String(trimmed.prefix(40))
        do { try commit(updated) } catch { globalError = error.localizedDescription }
    }
    func pin(_ account: Account) {
        var updated = state; updated.pinnedAccountID = account.id
        do { try commit(updated) } catch { globalError = error.localizedDescription }
    }
    func pin(_ provider: Provider) {
        if let account = accounts.first(where: { $0.provider == provider }) { pin(account) }
    }
    func remove(_ account: Account) async throws {
        guard !refreshing.contains(account.id) else { throw GaugeError.message("갱신이 끝난 뒤 다시 삭제해 주세요.") }
        if account.kind.isLocal {
            // Unlink only. The user's original CLI login must remain available.
        } else if account.kind == .claudeCode { try ClaudeProfile.remove(account.id) }
        else if account.provider == .claude { try CredentialVault.delete(account.id) }
        else {
            let connection = CodexConnection()
            defer { connection.close() }
            try await connection.start(accountID: account.id)
            try await connection.logout()
            let directory = try LocalStorage.profile(account.id)
            try FileManager.default.removeItem(at: directory)
        }
        var updated = state
        updated.accounts.removeAll { $0.id == account.id }
        updated.snapshots.removeValue(forKey: account.id.uuidString)
        updated.history.removeValue(forKey: account.id.uuidString)
        if updated.pinnedAccountID == account.id {
            updated.pinnedAccountID = updated.accounts.first(where: { $0.provider == account.provider })?.id ?? updated.accounts.first?.id
        }
        try commit(updated)
        errors.removeValue(forKey: account.id)
        failures.removeValue(forKey: account.id)
        nextRefresh.removeValue(forKey: account.id)
    }
    func setRefreshInterval(_ interval: Int) {
        var updated = state; updated.refreshInterval = max(60, interval)
        do { try commit(updated) } catch { globalError = error.localizedDescription }
    }
    func setNotifications(_ enabled: Bool) async {
        do {
            var updated = state
            if enabled {
                updated.notificationsEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                if !updated.notificationsEnabled { globalError = "macOS 설정 → 알림 → Gauge에서 알림을 허용해 주세요." }
            } else { updated.notificationsEnabled = false }
            try commit(updated)
        } catch { globalError = error.localizedDescription }
    }

    func connectLocalAccounts() async {
        guard !isConnectingLocal else { return }
        isConnectingLocal = true
        globalError = nil
        defer { isConnectingLocal = false }
        var problems: [String] = []
        do {
            let connection = CodexConnection()
            defer { connection.close() }
            let id = UUID()
            try await connection.start(accountID: id, homeOverride: LocalAccounts.codexHome, useExistingAuth: true)
            guard let info = try await connection.account() else { throw GaugeError.message("이 Mac의 Codex에 로그인해 주세요.") }
            let snapshot = try await connection.usage()
            if let existing = accounts.first(where: { $0.kind == .codexLocal && $0.identity == info.email }) {
                try record(snapshot, account: existing)
                errors.removeValue(forKey: existing.id)
            } else {
                try add(Account(id: id, provider: .codex, name: "내 Codex", identity: info.email, plan: info.plan, kind: .codexLocal), snapshot: snapshot)
            }
        } catch { problems.append("Codex: " + error.localizedDescription) }
        do {
            // The user directly requested a new local connection; automatic
            // refreshes continue to use the noninteractive path.
            _ = try await Task.detached { try LocalAccounts.claude(allowInteraction: true) }.value
            let local = try await ClaudeLocalAuth.shared.account()
            let identity = await ClaudeService.shared.identity(secret: local.accessToken, kind: .claudeLocal) ?? local.email
            try LocalAccounts.assertIdentity(expected: local.email, actual: identity)
            let account = Account(provider: .claude, name: "내 Claude", identity: identity, plan: local.plan, kind: .claudeLocal)
            let snapshot = try await ClaudeService.shared.usage(account: account, secret: local.accessToken)
            if let existing = accounts.first(where: { $0.kind == .claudeLocal && $0.identity == identity }) {
                try record(snapshot, account: existing)
                errors.removeValue(forKey: existing.id)
            } else { try add(account, snapshot: snapshot) }
        } catch { problems.append("Claude: " + error.localizedDescription) }
        if !problems.isEmpty { globalError = problems.joined(separator: "\n") }
    }

    private func notify(account: Account, snapshot: UsageSnapshot) async {
        guard state.notificationsEnabled else { return }
        for window in tracker.crossings(accountID: account.id, snapshot: snapshot) {
            let content = UNMutableNotificationContent()
            content.title = "\(account.name) · \(window.title) 사용량"
            content.body = "\(Int(window.usedPercent))% 사용했어요. \(UsageFormatting.countdown(to: window.resetsAt)) 초기화됩니다."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "\(account.id).\(window.id).\(window.resetsAt?.timeIntervalSince1970 ?? 0)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
