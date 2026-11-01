import Foundation
import Security
import GaugeCore

struct LocalClaudeAccount {
    let accessToken: String
    let email: String?
    let plan: String?
    let accountID: String?
    let expired: Bool
}

/// Credentials remain owned by the official CLIs. Gauge neither copies refresh tokens nor logs them out.
enum LocalAccounts {
    static var codexHome: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true) }

    static func claude(expirationLeeway: TimeInterval = 0, allowInteraction: Bool = false) throws -> LocalClaudeAccount {
        guard let data = try KeychainAccess.read(service: "Claude Code-credentials", allowInteraction: allowInteraction) else {
            throw GaugeError.message("Claude Code 로그인에 접근하지 못했어요. Claude Code에 로그인하고 키체인 접근을 허용해 주세요.")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else {
            throw GaugeError.message("Claude Code의 구독 로그인을 찾지 못했어요.")
        }
        let metadataURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        let metadata = (try? Data(contentsOf: metadataURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let identity = metadata?["oauthAccount"] as? [String: Any]
        let expiry = (oauth["expiresAt"] as? NSNumber)?.doubleValue
        return LocalClaudeAccount(accessToken: accessToken, email: identity?["emailAddress"] as? String,
                                  plan: oauth["subscriptionType"] as? String, accountID: identity?["accountUuid"] as? String,
                                  expired: expiry.map { $0 / 1000 <= Date().timeIntervalSince1970 + expirationLeeway } ?? false)
    }

    static func assertIdentity(expected: String?, actual: String?) throws {
        guard let expected, !expected.isEmpty else { return }
        guard let actual, expected.caseInsensitiveCompare(actual) == .orderedSame else {
            throw GaugeError.message("이 Mac의 로그인 계정이 변경되었어요. 계정 추가에서 현재 계정을 별도로 연결해 주세요.")
        }
    }
}
