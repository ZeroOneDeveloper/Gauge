import XCTest
import Darwin
@testable import Gauge

@MainActor
final class LocalAuthTests: XCTestCase {
    private func fixture(_ body: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gauge-auth-test-\(UUID())")
        try LocalStorage.prepare(directory)
        let script = directory.appendingPathComponent("claude.sh")
        try ("#!/bin/sh\nset -e\nprintf '%s' $$ > child-pid\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (directory, script)
    }

    private func account(expired: Bool, email: String = "saved@example.com") -> LocalClaudeAccount {
        LocalClaudeAccount(accessToken: expired ? "expired-fixture" : "renewed-fixture", email: email, plan: "max", accountID: "fixture", expired: expired)
    }

    func testFreshAppInstancesReuseValidSavedCredentialsWithoutLaunchingLogin() async throws {
        let saved = account(expired: false)
        for _ in 0..<2 {
            let auth = ClaudeLocalAuth(executableOverride: URL(fileURLWithPath: "/not-an-installed-cli"), read: { saved })
            let restored = try await auth.account(expectedIdentity: "saved@example.com")
            XCTAssertEqual(restored.accessToken, "renewed-fixture")
        }
    }

    func testExpiredCredentialsAreRefreshedOnceInTheOriginalCLIProfile() async throws {
        let (directory, script) = try fixture(#"""
        [ -t 0 ] && [ -t 1 ] && [ -t 2 ]
        [ -z "${CLAUDE_CONFIG_DIR+x}" ]
        [ -z "${CLAUDE_SECURESTORAGE_CONFIG_DIR+x}" ]
        [ -z "${CLAUDE_CODE_OAUTH_REFRESH_TOKEN+x}" ]
        [ "$1 $2 $3" = '--safe-mode --strict-mcp-config --tools' ]
        [ "$4" = '' ]
        [ "$7" = '/usage' ]
        printf '%s\n' start >> launches
        /bin/sleep 0.1
        /usr/bin/touch renewed
        exec /bin/sleep 30
        """#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expired = account(expired: true), renewed = account(expired: false)
        let auth = ClaudeLocalAuth(executableOverride: script, directoryOverride: directory, timeout: 5, read: {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("renewed").path) ? renewed : expired
        })
        let first = Task { try await auth.account(expectedIdentity: "saved@example.com") }
        let second = Task { try await auth.account(expectedIdentity: "saved@example.com") }
        let results = try await [first.value, second.value]
        XCTAssertTrue(results.allSatisfy { !$0.expired && $0.accessToken == "renewed-fixture" })
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("launches"), encoding: .utf8), "start\n")
    }

    func testCredentialOwnerCannotChangeWhileRefreshing() async throws {
        let (directory, script) = try fixture("/usr/bin/touch renewed\nexec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: directory) }
        let expired = account(expired: true), other = account(expired: false, email: "different@example.com")
        let auth = ClaudeLocalAuth(executableOverride: script, directoryOverride: directory, timeout: 2, read: {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("renewed").path) ? other : expired
        })
        do { _ = try await auth.account(expectedIdentity: "saved@example.com"); XCTFail("Expected account change to fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("변경")) }
    }

    func testTimeoutAndShutdownStopOnlyTheOwnedProbe() async throws {
        let (directory, script) = try fixture("exec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: directory) }
        let expired = account(expired: true)
        let timeout = ClaudeLocalAuth(executableOverride: script, directoryOverride: directory, timeout: 0.05, read: { expired })
        do { _ = try await timeout.account(); XCTFail("Expected timeout") } catch { }
        let auth = ClaudeLocalAuth(executableOverride: script, directoryOverride: directory, read: { expired })
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("child-pid"))
        let pending = Task { try await auth.account() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("child-pid").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let child = Int32(try String(contentsOf: directory.appendingPathComponent("child-pid"), encoding: .utf8))!
        auth.stop()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<100 {
            if kill(child, 0) == -1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(kill(child, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
