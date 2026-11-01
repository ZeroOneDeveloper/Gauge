import Foundation
import Darwin
import GaugeCore

/// Restore the original CLI-owned session without copying its refresh token.
/// Normal Claude Code startup performs its own locked credential refresh. The
/// probe never answers prompts or sends an inference request.
@MainActor
final class ClaudeLocalAuth {
    static let shared = ClaudeLocalAuth()
    private let read: () throws -> LocalClaudeAccount
    private let executableOverride: URL?
    private let directoryOverride: URL?
    private let timeout: TimeInterval
    private var active: Task<LocalClaudeAccount, Error>?
    private var activeID: UUID?
    private var probe: ClaudeAuthProbe?

    init(executableOverride: URL? = nil, directoryOverride: URL? = nil, timeout: TimeInterval = 45,
         read: @escaping () throws -> LocalClaudeAccount = { try LocalAccounts.claude(expirationLeeway: 60) }) {
        self.executableOverride = executableOverride
        self.directoryOverride = directoryOverride
        self.timeout = timeout
        self.read = read
    }

    func account(expectedIdentity: String? = nil) async throws -> LocalClaudeAccount {
        let current = try read()
        try LocalAccounts.assertIdentity(expected: expectedIdentity, actual: current.email)
        guard current.expired else { return current }
        let task: Task<LocalClaudeAccount, Error>
        let id: UUID
        if let active, let activeID {
            task = active; id = activeID
        } else {
            guard let executable = executableOverride ?? ClaudeConnection.executable() else {
                throw GaugeError.message("Claude Code를 찾지 못해 로그인을 자동 갱신하지 못했어요. Claude Code를 설치한 뒤 새로고침해 주세요.")
            }
            let directory = directoryOverride ?? LocalStorage.root.appendingPathComponent("ClaudeAuthProbe", isDirectory: true)
            try LocalStorage.prepare(directory)
            let probe = ClaudeAuthProbe()
            self.probe = probe
            id = UUID()
            task = Task { @MainActor [read, timeout] in
                defer { probe.stop() }
                try probe.start(executable: executable, directory: directory)
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    try Task.checkCancellation()
                    probe.drain()
                    let updated = try read()
                    try LocalAccounts.assertIdentity(expected: current.email, actual: updated.email)
                    if !updated.expired { return updated }
                    guard probe.isRunning else { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                throw GaugeError.message("Claude Code 로그인을 자동 갱신하지 못했어요. 네트워크를 확인하고 새로고침해 주세요. 계속되면 Claude Code에서 다시 로그인해 주세요.")
            }
            active = task; activeID = id
        }
        defer {
            if activeID == id { active = nil; activeID = nil; probe = nil }
        }
        let result = try await task.value
        try Task.checkCancellation()
        try LocalAccounts.assertIdentity(expected: expectedIdentity, actual: result.email)
        return result
    }

    func stop() {
        active?.cancel()
        probe?.stop()
        active = nil; activeID = nil; probe = nil
    }
}

@MainActor
private final class ClaudeAuthProbe {
    private var pid: pid_t = 0
    private var master: Int32 = -1
    private var reaped = false

    func start(executable: URL, directory: URL) throws {
        var slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw GaugeError.message("Claude 인증 갱신을 준비하지 못했어요.") }
        defer { close(slave) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_adddup2(&actions, slave, descriptor)
        }
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addclose(&actions, slave)
        directory.path.withCString { _ = posix_spawn_file_actions_addchdir_np(&actions, $0) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let arguments = [executable.path, "--safe-mode", "--strict-mcp-config", "--tools", "", "--settings",
                         #"{"disableAllHooks":true,"remoteControlAtStartup":false}"#, "/usage"]
        var environment = ClaudeConnection.environment(profile: nil)
        environment["TERM"] = "xterm-256color"
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        let status = executable.path.withCString { path in
            argv.withUnsafeBufferPointer { arguments in
                envp.withUnsafeBufferPointer { environment in
                    posix_spawn(&pid, path, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
                }
            }
        }
        guard status == 0 else {
            close(master); master = -1; pid = 0
            throw GaugeError.message("Claude Code를 실행하지 못해 로그인을 자동 갱신하지 못했어요.")
        }
    }

    func drain() {
        guard master >= 0 else { return }
        // Discard all terminal output, which may contain private account data.
        var bytes = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<16 {
            if Darwin.read(master, &bytes, bytes.count) <= 0 { break }
        }
    }

    var isRunning: Bool {
        guard pid > 0, !reaped else { return false }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) { reaped = true; return false }
        return true
    }

    func stop() {
        if master >= 0 { close(master); master = -1 }
        guard pid > 0 else { return }
        let child = pid, alreadyReaped = reaped
        pid = 0
        // This process group was created solely for this probe. No other Claude
        // session is interrupted, including the user's open terminal sessions.
        kill(-child, SIGTERM)
        guard !alreadyReaped else { return }
        Task.detached(priority: .utility) {
            var status: Int32 = 0
            for _ in 0..<40 {
                let result = waitpid(child, &status, WNOHANG)
                if result == child || result == -1 { return }
                usleep(50_000)
            }
            kill(-child, SIGKILL)
            _ = waitpid(child, &status, 0)
        }
    }
}
