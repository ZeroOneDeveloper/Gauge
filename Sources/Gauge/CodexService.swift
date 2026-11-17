import Foundation
import AppKit
import GaugeCore

/// One stdio process with one isolated CODEX_HOME. Only auth/account RPCs are used.
@MainActor
final class CodexConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private(set) var loginID: String?
    private(set) var loginFailure: String?
    private var closed = false
    private let executableOverride: URL?

    init(executableOverride: URL? = nil) { self.executableOverride = executableOverride }

    static func executable() -> URL? {
        let defaults = UserDefaults.standard.string(forKey: "codexExecutable")
        let candidates: [String?] = [defaults,
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path]
        return candidates.compactMap { $0 }.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    func start(accountID: UUID, homeOverride: URL? = nil, useExistingAuth: Bool = false) async throws {
        guard let executable = executableOverride ?? Self.executable() else {
            throw GaugeError.message("Codex 실행 파일이 필요해요. Codex 앱 또는 CLI를 설치하거나 설정에서 실행 파일을 선택해 주세요.")
        }
        let home = try homeOverride ?? LocalStorage.profile(accountID)
        process.executableURL = executable
        process.arguments = ["app-server", "-c", "analytics.enabled=false"]
        if !useExistingAuth { process.arguments! += ["-c", "cli_auth_credentials_store=\"keyring\""] }
        var environment = ProcessInfo.processInfo.environment
        // GUI apps have a shorter PATH; keep known Node installations available for the npm CLI.
        let nodeBins = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node").path)) ?? []
        let paths = nodeBins.sorted().reversed().map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node/\($0)/bin").path }
        environment["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] + paths + [environment["PATH"] ?? ""]).joined(separator: ":")
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_HOME", "CODEX_CONFIG", "CODEX_ACCESS_TOKEN"] { environment.removeValue(forKey: key) }
        environment["CODEX_HOME"] = home.path
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = input
        process.standardOutput = output
        // Never log server output: it can contain login URLs and credentials.
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.failAll(GaugeError.message("Codex 연결이 종료되었어요. 실행 파일을 확인하고 다시 시도해 주세요.")) }
        }
        try process.run()
        _ = try await request("initialize", params: ["clientInfo": ["name": "gauge", "title": "Gauge", "version": GaugeVersion.current]])
        try send(["method": "initialized", "params": [:]])
    }

    private func send(_ object: [String: Any]) throws {
        guard !closed, process.isRunning else { throw GaugeError.message("Codex에 연결되어 있지 않아요.") }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> [String: Any] {
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do { try send(["id": id, "method": method, "params": params]) }
                catch { pending.removeValue(forKey: id)?.resume(throwing: error); return }
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.finish(id: id, result: .failure(GaugeError.message("Codex 응답 시간이 초과되었어요. 네트워크를 확인하고 다시 시도해 주세요.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, result: .failure(CancellationError())) }
        }
    }

    private func receive(_ data: Data) {
        guard !closed else { return }
        if data.isEmpty { failAll(GaugeError.message("Codex 연결이 닫혔어요.")); return }
        buffer.append(data)
        guard buffer.count < 8_000_000 else { close(); return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = json["id"] as? Int {
                if let error = json["error"] as? [String: Any] {
                    // Provider bodies are deliberately not surfaced (may contain private identifiers).
                    let code = error["code"] as? Int ?? 0
                    let message = (error["message"] as? String ?? "").lowercased()
                    let failure: Error
                    if message.contains("address already in use") || message.contains("port 1455") {
                        failure = GaugeError.message("Codex 로그인 포트(1455)가 사용 중이에요. 다른 Codex 로그인이 끝난 뒤 다시 시도해 주세요.")
                    } else if message.contains("429") || message.contains("too many requests") {
                        failure = GaugeError.rateLimited(120)
                    } else if message.contains("401") || message.contains("unauthorized") || message.contains("not logged in") {
                        failure = GaugeError.unauthorized
                    } else {
                        failure = GaugeError.message("Codex 요청이 거절되었어요 (\(code)). 로그인 상태와 Codex 버전을 확인해 주세요.")
                    }
                    finish(id: id, result: .failure(failure))
                } else { finish(id: id, result: .success(json["result"] as? [String: Any] ?? [:])) }
            } else if json["method"] as? String == "account/login/completed", let params = json["params"] as? [String: Any], params["success"] as? Bool == false {
                loginFailure = "Codex 로그인을 완료하지 못했어요. 로그인 창을 다시 열어 시도해 주세요."
            }
        }
    }
    private func finish(id: Int, result: Result<[String: Any], Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func failAll(_ error: Error) {
        for id in Array(pending.keys) { finish(id: id, result: .failure(error)) }
    }
    func login() async throws -> URL {
        let result = try await request("account/login/start", params: ["type": "chatgpt"])
        loginID = result["loginId"] as? String
        guard let text = result["authUrl"] as? String, let url = URL(string: text),
              url.scheme == "https", let host = url.host,
              host == "auth.openai.com" || host == "chatgpt.com" else { throw GaugeError.unsupported }
        return url
    }
    func account() async throws -> (email: String?, plan: String?)? {
        let result = try await request("account/read", params: ["refreshToken": false])
        guard let account = result["account"] as? [String: Any] else { return nil }
        guard account["type"] as? String == "chatgpt" else { throw GaugeError.message("API 키 계정 대신 ChatGPT 구독 계정으로 로그인해 주세요.") }
        return (account["email"] as? String, account["planType"] as? String)
    }
    func usage() async throws -> UsageSnapshot {
        try UsageParser.codex(await request("account/rateLimits/read"))
    }
    func logout() async throws { _ = try await request("account/logout") }
    func cancelLogin() async {
        if let loginID { _ = try? await request("account/login/cancel", params: ["loginId": loginID], timeout: 5) }
    }
    func close() {
        guard !closed else { return }
        closed = true
        output.fileHandleForReading.readabilityHandler = nil
        failAll(CancellationError())
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
