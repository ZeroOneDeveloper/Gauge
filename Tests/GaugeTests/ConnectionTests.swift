import XCTest
@testable import Gauge
import GaugeCore

@MainActor
final class ConnectionTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gauge-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testRealCodexProtocolUsesSeparateSignedOutProfiles() async throws {
        guard CodexConnection.executable() != nil else { throw XCTSkip("Codex not installed") }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstHome = directory.appendingPathComponent("first")
        let secondHome = directory.appendingPathComponent("second")
        try LocalStorage.prepare(firstHome)
        try LocalStorage.prepare(secondHome)
        let first = CodexConnection(), second = CodexConnection()
        defer { first.close(); second.close() }
        try await first.start(accountID: UUID(), homeOverride: firstHome)
        try await second.start(accountID: UUID(), homeOverride: secondHome)
        let firstAccount = try await first.account()
        let secondAccount = try await second.account()
        XCTAssertNil(firstAccount)
        XCTAssertNil(secondAccount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstHome.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondHome.appendingPathComponent("auth.json").path))
    }

    func testUnansweredRequestTimesOutAndCloseFinishesPendingRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.sh")
        let fixture = #"""
        #!/bin/sh
        while IFS= read -r request; do
          case "$request" in
            *'"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
          esac
        done
        """#
        try fixture.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = CodexConnection(executableOverride: script)
        defer { client.close() }
        try await client.start(accountID: UUID(), homeOverride: directory)
        let began = Date()
        do {
            _ = try await client.request("ignored", timeout: 0.05)
            XCTFail("Expected timeout")
        } catch { XCTAssertLessThan(Date().timeIntervalSince(began), 2) }
        let pending = Task { try await client.request("ignored", timeout: 30) }
        await Task.yield()
        client.close()
        do { _ = try await pending.value; XCTFail("Expected closed request to fail") } catch { }
    }

    func testClaudeCredentialInputExtractsOnlySessionKey() throws {
        let (secret, kind) = try ClaudeService.normalize("Cookie: other=hidden; sessionKey=sk-ant-session-fixture; third=ignored")
        XCTAssertEqual(secret, "sk-ant-session-fixture")
        XCTAssertEqual(kind, .claudeSession)
        let oauth = try ClaudeService.normalize(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-fixture","refreshToken":"do-not-copy"}}"#)
        XCTAssertEqual(oauth.0, "sk-ant-oat-fixture")
        XCTAssertEqual(oauth.1, .claudeOAuth)
        XCTAssertThrowsError(try ClaudeService.normalize("sk-ant-api03-fixture"))
        XCTAssertThrowsError(try ClaudeService.normalize("sk-ant-token\r\nAuthorization: hidden"))
    }

    func testLocalAccountSwitchCannotReplaceAnotherAccountsUsage() throws {
        XCTAssertNoThrow(try LocalAccounts.assertIdentity(expected: "personal@example.com", actual: "PERSONAL@example.com"))
        XCTAssertThrowsError(try LocalAccounts.assertIdentity(expected: "personal@example.com", actual: "work@example.com"))
        XCTAssertThrowsError(try LocalAccounts.assertIdentity(expected: "personal@example.com", actual: nil))
        XCTAssertTrue(ConnectionKind.claudeLocal.isLocal)
        XCTAssertTrue(ConnectionKind.claudeLocal.usesClaudeOAuth)
        XCTAssertTrue(ConnectionKind.codexLocal.isLocal)
        XCTAssertFalse(ConnectionKind.codex.isLocal)
        XCTAssertTrue(ConnectionKind.claudeCode.usesClaudeOAuth)
        XCTAssertFalse(ConnectionKind.claudeCode.isLocal)
    }

    func testClaudeBrowserLoginIsIsolatedAndAcceptsManualCallbackCode() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("login.sh")
        let fixture = #"""
        #!/bin/sh
        [ -d "$CLAUDE_CONFIG_DIR" ] || exit 2
        [ "$CLAUDE_SECURESTORAGE_CONFIG_DIR" = "$CLAUDE_CONFIG_DIR" ] || exit 3
        [ "$1 $2 $3" = 'auth login --claudeai' ] || exit 4
        printf '%s\n' 'If the browser did not open, visit: https://claude.com/cai/oauth/authorize?state=fixture'
        IFS= read -r code
        [ "$code" = 'fixture-code#fixture-state' ] || exit 5
        """#
        try fixture.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = ClaudeConnection(executableOverride: script)
        var authorizationURL: URL?
        let task = Task { try await client.login(profile: directory, timeout: 5) { authorizationURL = $0 } }
        for _ in 0..<100 {
            if authorizationURL != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(authorizationURL?.host, "claude.com")
        XCTAssertThrowsError(try client.submit(code: "bad\ncode"))
        try client.submit(code: "fixture-code#fixture-state")
        try await task.value
    }

    func testCancellingClaudeLoginStopsTheOwnedProcess() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("cancel.sh")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = ClaudeConnection(executableOverride: script)
        let task = Task { try await client.login(profile: directory) }
        try await Task.sleep(for: .milliseconds(30))
        let started = Date()
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await client.cancel()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testClaudeLoginTimeoutFinishesAndRejectsUntrustedAuthorizationLinks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("timeout.sh")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = ClaudeConnection(executableOverride: script)
        let started = Date()
        do {
            try await client.login(profile: directory, timeout: 0.05)
            XCTFail("Expected login timeout")
        } catch { XCTAssertLessThan(Date().timeIntervalSince(started), 3) }
        XCTAssertNil(ClaudeConnection.authorizationURL(in: "https://claude.com.attacker.invalid/cai/oauth/authorize?state=fixture"))
        XCTAssertNil(ClaudeConnection.authorizationURL(in: "https://claude.ai/settings/usage"))
        let environment = ClaudeConnection.environment(profile: directory)
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], directory.path)
        XCTAssertNil(environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNotEqual(ClaudeProfile.service(for: directory), "Claude Code-credentials")
        XCTAssertNotEqual(ClaudeProfile.service(for: directory), ClaudeProfile.service(for: directory.appendingPathComponent("other")))
    }
}
