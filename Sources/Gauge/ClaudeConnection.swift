import Foundation
import CryptoKit
import Security
import Darwin
import GaugeCore

/// The official CLI owns a separate login for every Gauge account. No refresh
/// token is copied from the user's normal Claude Code profile.
@MainActor
final class ClaudeConnection {
    private var process: Process?
    private var input: Pipe?
    private var completion: CheckedContinuation<Void, Error>?
    private var output = ""
    private var sentURL = false
    private var timeout: Task<Void, Never>?
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelled = false
    private var timedOut = false
    private let executableOverride: URL?
    init(executableOverride: URL? = nil) { self.executableOverride = executableOverride }

    nonisolated static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/claude").path,
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func environment(profile: URL?, refresh: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("ANTHROPIC_") && !$0.key.hasPrefix("CLAUDE_") && $0.key != "CLAUDECODE"
        }
        if let profile {
            environment["CLAUDE_CONFIG_DIR"] = profile.path
            environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = profile.path
        }
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["DISABLE_TELEMETRY"] = "1"
        environment["DISABLE_ERROR_REPORTING"] = "1"
        environment["NO_COLOR"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        for (key, value) in refresh { environment[key] = value }
        return environment
    }

    func login(profile: URL, refresh: [String: String] = [:], timeout seconds: Double = 300,
               onURL: @escaping (URL) -> Void = { _ in }) async throws {
        guard process == nil else { throw GaugeError.message("이미 Claude 로그인이 진행 중이에요.") }
        guard let executable = executableOverride ?? Self.executable() else {
            throw GaugeError.message("Claude Code를 찾지 못했어요. Claude Code를 설치하거나 아래의 토큰 연결을 이용해 주세요.")
        }
        try Task.checkCancellation()
        let child = Process(), pipe = Pipe(), stdinPipe = Pipe()
        child.executableURL = executable
        child.arguments = ["auth", "login", "--claudeai"]
        child.currentDirectoryURL = profile
        child.environment = Self.environment(profile: profile, refresh: refresh)
        child.standardInput = stdinPipe
        child.standardOutput = pipe
        child.standardError = pipe
        process = child; input = stdinPipe; output = ""; sentURL = false; cancelled = false; timedOut = false
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.receive(data, onURL: onURL) }
        }
        child.terminationHandler = { [weak self] child in
            pipe.fileHandleForReading.readabilityHandler = nil
            let trailing = pipe.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                self?.receive(trailing, onURL: onURL)
                self?.finished(status: child.terminationStatus)
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                do { try child.run() }
                catch { finished(status: -1); return }
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    guard let self, let process = self.process, process.isRunning else { return }
                    self.timedOut = true
                    self.terminate(process)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in await self?.cancel() }
        }
        try Task.checkCancellation()
    }

    private func receive(_ data: Data, onURL: (URL) -> Void) {
        guard process != nil, !cancelled else { return }
        // Login output can contain an OAuth URL, so keep it in memory only.
        output = String((output + String(decoding: data, as: UTF8.self)).suffix(32_768))
        guard !sentURL, let url = Self.authorizationURL(in: output) else { return }
        sentURL = true
        onURL(url)
    }

    static func authorizationURL(in output: String) -> URL? {
        let plain = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        let regex = try! NSRegularExpression(pattern: "https://[^\\s\\u0000-\\u001F<>]+")
        for match in regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let range = Range(match.range, in: plain), let url = URL(string: String(plain[range])),
                  ["claude.ai", "claude.com", "platform.claude.com"].contains(url.host),
                  url.path.hasSuffix("/oauth/authorize") else { continue }
            return url
        }
        return nil
    }

    func submit(code: String) throws {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r"), value.count < 4096,
              let input, process?.isRunning == true else { throw GaugeError.message("인증 코드를 확인해 주세요.") }
        try input.fileHandleForWriting.write(contentsOf: Data((value + "\n").utf8))
    }

    func cancel() async {
        cancelled = true
        guard let process, process.isRunning else { return }
        terminate(process)
        await withCheckedContinuation { cancelWaiters.append($0) }
    }

    private func terminate(_ process: Process) {
        process.terminate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func finished(status: Int32) {
        timeout?.cancel(); timeout = nil
        let failure = Self.loginFailure(in: output)
        process = nil; input = nil; output = ""
        let continuation = completion
        completion = nil
        if cancelled { continuation?.resume(throwing: CancellationError()) }
        else if timedOut { continuation?.resume(throwing: GaugeError.message("로그인 대기 시간이 지났어요. 다시 시도해 주세요.")) }
        else if status == 0 { continuation?.resume() }
        else { continuation?.resume(throwing: failure) }
        let waiters = cancelWaiters; cancelWaiters = []
        waiters.forEach { $0.resume() }
    }

    static func loginFailure(in output: String) -> Error {
        let output = output.lowercased()
        if output.contains("cloudflare") || output.contains("just a moment") {
            return GaugeError.message("Claude 로그인 서버의 보안 확인에 막혔어요. 브라우저에서 Claude가 열리는지 확인한 뒤 다시 시도해 주세요.")
        }
        if output.contains("keychain") || output.contains("failed to save") || output.contains("secure storage") {
            return GaugeError.message("브라우저 로그인 정보를 Mac에 저장하지 못했어요. 키체인 승인 창을 확인하고 다시 시도해 주세요. 기존 계정과 기록은 유지됩니다.")
        }
        if output.contains("403") {
            return GaugeError.message("Claude 로그인 서버가 요청을 거절했어요 (HTTP 403). 브라우저에서 계정 상태와 네트워크를 확인해 주세요.")
        }
        return GaugeError.message("Claude 로그인을 완료하지 못했어요. 브라우저 로그인 후 다시 시도해 주세요.")
    }
}

enum ClaudeProfile {
    static func service(for profile: URL) -> String {
        let path = profile.path.precomposedStringWithCanonicalMapping
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        return "Claude Code-credentials-\(hash)"
    }

    private static func query(_ profile: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(for: profile)]
    }

    private struct Document {
        var root: [String: Any]
        let keychain: Bool
    }
    @MainActor private static var pending: [UUID: Document] = [:]
    @MainActor private static var refreshes: [UUID: Task<LocalClaudeAccount, Error>] = [:]
    @MainActor static func resetPending(_ id: UUID) { pending.removeValue(forKey: id) }

    private static func document(_ profile: URL, allowInteraction: Bool = false) throws -> Document {
        let stored = try KeychainAccess.read(service: service(for: profile), allowInteraction: allowInteraction)
        let data = try stored ?? Data(contentsOf: profile.appendingPathComponent(".credentials.json"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["claudeAiOauth"] is [String: Any] else {
            throw GaugeError.unauthorized
        }
        return Document(root: root, keychain: stored != nil)
    }

    private static func save(_ document: Document, profile: URL, allowInteraction: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: document.root)
        if document.keychain {
            try KeychainAccess.update(data, service: service(for: profile), allowInteraction: allowInteraction)
        } else {
            let file = profile.appendingPathComponent(".credentials.json")
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    static func authorize(_ id: UUID, allowInteraction: Bool = true) throws {
        let profile = try LocalStorage.claudeProfile(id)
        let stored = try document(profile, allowInteraction: allowInteraction)
        try save(stored, profile: profile, allowInteraction: allowInteraction)
    }

    // Reauthentication uses a clean CLI profile. Only a verified login is copied
    // into the account's existing storage, which preserves its ID and history.
    static func install(from stagingID: UUID, to accountID: UUID, expectedIdentity: String?) throws {
        guard stagingID != accountID else { throw GaugeError.unsupported }
        let source = try LocalStorage.claudeProfile(stagingID)
        let target = try LocalStorage.claudeProfile(accountID)
        let stored = try document(source)
        let metadata = try Data(contentsOf: source.appendingPathComponent(".claude.json"))
        try installDocument(stored.root, metadata: metadata, profile: target, expectedIdentity: expectedIdentity) { data, service in
            do { try KeychainAccess.store(data, service: service) }
            catch GaugeError.keychainAccessRequired { try KeychainAccess.store(data, service: service, allowInteraction: true) }
        }
    }

    static func installDocument(_ root: [String: Any], metadata: Data, profile: URL, expectedIdentity: String?,
                                store: (Data, String) throws -> Void) throws {
        guard let parsed = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let identity = parsed["oauthAccount"] as? [String: Any],
              let email = identity["emailAddress"] as? String, !email.isEmpty,
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty else { throw GaugeError.unauthorized }
        try LocalAccounts.assertIdentity(expected: expectedIdentity, actual: email)
        let data = try JSONSerialization.data(withJSONObject: root)
        try store(data, service(for: profile))
        let file = profile.appendingPathComponent(".claude.json")
        try metadata.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    @MainActor static func account(_ id: UUID) async throws -> LocalClaudeAccount {
        if let active = refreshes[id] { return try await active.value }
        let task = Task { @MainActor in try await loadAccount(id) }
        refreshes[id] = task
        defer { refreshes.removeValue(forKey: id) }
        return try await task.value
    }

    @MainActor private static func loadAccount(_ id: UUID) async throws -> LocalClaudeAccount {
        let profile = try LocalStorage.claudeProfile(id)
        var stored = try pending[id] ?? document(profile)
        if pending[id] != nil { try save(stored, profile: profile); pending.removeValue(forKey: id) }
        guard var oauth = stored.root["claudeAiOauth"] as? [String: Any] else { throw GaugeError.unauthorized }
        if let expiry = (oauth["expiresAt"] as? NSNumber)?.doubleValue, expiry / 1000 <= Date().timeIntervalSince1970 + 60 {
            // Check write access before rotating a refresh token, so a locked or
            // unauthorized Keychain cannot strand a newly issued credential.
            try save(stored, profile: profile)
            oauth = try await ClaudeOAuthRefresh.shared.refresh(oauth)
            stored.root["claudeAiOauth"] = oauth
            pending[id] = stored
            try save(stored, profile: profile)
            pending.removeValue(forKey: id)
        }
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { throw GaugeError.unauthorized }
        let metadata = (try? Data(contentsOf: profile.appendingPathComponent(".claude.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let identity = metadata?["oauthAccount"] as? [String: Any]
        return LocalClaudeAccount(accessToken: token, email: identity?["emailAddress"] as? String,
                                  plan: oauth["subscriptionType"] as? String, accountID: identity?["accountUuid"] as? String, expired: false)
    }

    static func remove(_ id: UUID, allowInteraction: Bool = true) throws {
        let profile = try LocalStorage.claudeProfile(id)
        let status = try KeychainAccess.withInteractionPolicy(allowInteraction: allowInteraction) {
            SecItemDelete(query(profile) as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GaugeError.message("Claude 전용 로그인 정보를 키체인에서 삭제하지 못했어요.")
        }
        try FileManager.default.removeItem(at: profile)
    }
}
