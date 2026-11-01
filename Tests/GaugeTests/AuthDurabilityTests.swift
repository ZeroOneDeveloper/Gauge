import XCTest
import Security
import LocalAuthentication
import GaugeCore
@testable import Gauge

@MainActor
final class AuthDurabilityTests: XCTestCase {
    func testConcurrentAuthorizationIsBusyRatherThanARevokedGrant() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let authorization = Task.detached {
            try KeychainAccess.withInteractionPolicy(allowInteraction: true) {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        guard entered.wait(timeout: .now() + 2) == .success else {
            release.signal()
            try await authorization.value
            return XCTFail("Authorization did not enter the protected operation")
        }
        XCTAssertThrowsError(try KeychainAccess.withInteractionPolicy(allowInteraction: false) { () }) { error in
            guard case GaugeError.keychainBusy = error else { return XCTFail("Waiting for another account is not a permission failure") }
        }
        release.signal()
        try await authorization.value
        XCTAssertNoThrow(try KeychainAccess.withInteractionPolicy(allowInteraction: false) { () })
    }

    func testBackgroundKeychainReadsDisableBothModernAndLegacyPrompting() throws {
        let query = KeychainAccess.query(service: "fixture")
        XCTAssertTrue((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        XCTAssertNil(KeychainAccess.query(service: "fixture", allowInteraction: true)[kSecUseAuthenticationContext as String])
        var before: DarwinBoolean = false
        SecKeychainGetUserInteractionAllowed(&before)
        try KeychainAccess.withInteractionPolicy(allowInteraction: false) {
            var during: DarwinBoolean = true
            SecKeychainGetUserInteractionAllowed(&during)
            XCTAssertFalse(during.boolValue)
        }
        var after: DarwinBoolean = false
        SecKeychainGetUserInteractionAllowed(&after)
        XCTAssertEqual(before.boolValue, after.boolValue)
    }

    func testSessionRefreshDoesNotRequestOneYearSetupToken() throws {
        let request = try ClaudeOAuthRefresh.request(for: ["refreshToken": "fixture-refresh", "scopes": ["user:profile", "user:inference"]])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(body["scope"] as? String, "user:profile user:inference")
        XCTAssertNil(body["expires_in"])
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "platform.claude.com")
    }

    func testRefreshKeepsProfileMetadataAndPersistsRotatedCredentials() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let source: [String: Any] = ["refreshToken": "old-fixture", "scopes": ["user:profile"], "subscriptionType": "max", "clientId": "fixture-client"]
        let renewed = try ClaudeOAuthRefresh.updated(source, response: ["access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600, "scope": "user:profile user:inference"], now: now)
        XCTAssertEqual(renewed["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual(renewed["expiresAt"] as? Double, 4_600_000)
        XCTAssertEqual(renewed["subscriptionType"] as? String, "max")
        XCTAssertEqual(renewed["clientId"] as? String, "fixture-client")
        XCTAssertEqual(renewed["scopes"] as? [String], ["user:profile", "user:inference"])
        let unchangedRefresh = try ClaudeOAuthRefresh.updated(source, response: ["access_token": "new-access", "expires_in": 3600])
        XCTAssertEqual(unchangedRefresh["refreshToken"] as? String, "old-fixture")
        XCTAssertThrowsError(try ClaudeOAuthRefresh.updated(source, response: ["access_token": "new-access", "expires_in": true]))
        XCTAssertThrowsError(try ClaudeOAuthRefresh.updated(source, response: ["access_token": "", "expires_in": 3600]))
    }

    func testReauthenticationPreservesAccountIdentityPinAndHistory() throws {
        let old = Account(provider: .claude, name: "Saved account", identity: "saved@example.com", kind: .claudeCode, createdAt: Date(timeIntervalSince1970: 1000))
        let snapshot = UsageSnapshot(windows: [UsageWindow(id: "seven_day", title: "주간", usedPercent: 25)])
        var initial = PersistedState()
        initial.accounts = [old]
        initial.pinnedAccountID = old.id
        initial.history[old.id.uuidString] = [HistorySample(date: Date(timeIntervalSince1970: 1000), windows: snapshot.windows)]
        var persisted: PersistedState?
        let store = AppStore(initialState: initial, automaticallyRefresh: false, saveState: { persisted = $0 })
        let replacement = Account(id: old.id, provider: .claude, name: "New label", identity: "SAVED@example.com", plan: "max", kind: .claudeCode)
        try store.finishReauthentication(old, replacement: replacement, snapshot: snapshot)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts[0].id, old.id)
        XCTAssertEqual(store.accounts[0].name, old.name)
        XCTAssertEqual(store.accounts[0].createdAt, old.createdAt)
        XCTAssertEqual(persisted?.pinnedAccountID, old.id)
        XCTAssertEqual(persisted?.history[old.id.uuidString]?.count, 2)
    }

    func testReauthenticationRejectsOtherAccountWithoutChangingStoredData() throws {
        let old = Account(provider: .claude, name: "Saved", identity: "saved@example.com", kind: .claudeCode)
        var initial = PersistedState(); initial.accounts = [old]
        var didPersist = false
        let store = AppStore(initialState: initial, automaticallyRefresh: false, saveState: { _ in didPersist = true })
        let other = Account(id: old.id, provider: .claude, name: "Other", identity: "other@example.com", kind: .claudeCode)
        XCTAssertThrowsError(try store.finishReauthentication(old, replacement: other, snapshot: UsageSnapshot(windows: [])))
        XCTAssertFalse(didPersist)
        XCTAssertEqual(store.accounts, [old])
    }

    func testLocalClaudeMigratesToAnIsolatedLoginKeepingIdentityPinAndHistory() throws {
        let old = Account(provider: .claude, name: "Main Claude", identity: "main@example.com", kind: .claudeLocal,
                          createdAt: Date(timeIntervalSince1970: 1000))
        let prior = HistorySample(date: Date(timeIntervalSince1970: 2000), windows: [])
        var initial = PersistedState()
        initial.accounts = [old]
        initial.pinnedAccountID = old.id
        initial.history[old.id.uuidString] = [prior]
        var persisted: PersistedState?
        let store = AppStore(initialState: initial, automaticallyRefresh: false, saveState: { persisted = $0 })
        let isolated = Account(id: old.id, provider: .claude, name: "New", identity: "main@example.com", kind: .claudeCode)
        try store.finishReauthentication(old, replacement: isolated, snapshot: UsageSnapshot(windows: []))
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.kind, .claudeCode)
        XCTAssertEqual(store.accounts.first?.id, old.id)
        XCTAssertEqual(store.accounts.first?.name, old.name)
        XCTAssertEqual(store.accounts.first?.createdAt, old.createdAt)
        XCTAssertEqual(persisted?.pinnedAccountID, old.id)
        XCTAssertEqual(persisted?.history[old.id.uuidString]?.first?.id, prior.id)
        XCTAssertEqual(persisted?.history[old.id.uuidString]?.count, 2)
    }
}
