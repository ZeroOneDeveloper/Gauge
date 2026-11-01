import Foundation
import GaugeCore

struct ClaudeOrganization: Identifiable {
    let id: String
    let name: String
}

final class ClaudeService {
    static let shared = ClaudeService()
    private let session: URLSession
    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    static func normalize(_ input: String) throws -> (String, ConnectionKind) {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("{") {
            guard let json = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String else {
                throw GaugeError.message("Claude Code 인증 파일에서 accessToken을 찾지 못했어요.")
            }
            value = token
        }
        if value.lowercased().hasPrefix("cookie:") { value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if let cookie = value.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("sessionKey=") }) {
            value = String(cookie.dropFirst("sessionKey=".count))
        }
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r"), !value.contains(";"), !value.contains(" ") else {
            throw GaugeError.message("sessionKey 또는 Claude OAuth 토큰을 입력해 주세요.")
        }
        if value.hasPrefix("sk-ant-oat") { return (value, .claudeOAuth) }
        guard value.hasPrefix("sk-ant-") else { throw GaugeError.message("Claude sessionKey는 sk-ant-로 시작합니다. API 키로는 구독 사용량을 조회할 수 없어요.") }
        guard !value.hasPrefix("sk-ant-api") && !value.hasPrefix("sk-ant-admin") else {
            throw GaugeError.message("API 키 대신 claude.ai의 sessionKey를 입력해 주세요.")
        }
        return (value, .claudeSession)
    }

    private func get(_ path: String, secret: String, kind: ConnectionKind) async throws -> Data {
        let host = kind.usesClaudeOAuth ? "https://api.anthropic.com" : "https://claude.ai"
        guard let url = URL(string: host + path) else { throw GaugeError.unsupported }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Gauge/1.0 (macOS; usage monitor)", forHTTPHeaderField: "User-Agent")
        if kind.usesClaudeOAuth {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else { request.setValue("sessionKey=\(secret)", forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw GaugeError.unsupported }
        switch http.statusCode {
        case 200...299: break
        case 401: throw GaugeError.unauthorized
        case 403:
            let body = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if body.contains("cloudflare") || body.contains("just a moment") || body.contains("challenge") {
                throw GaugeError.message("Claude 웹 보안 확인으로 조회가 차단되었어요. 브라우저에서 claude.ai를 확인하거나 Claude Code OAuth 토큰으로 연결해 주세요.")
            }
            throw GaugeError.message("Claude가 접근을 거절했어요. 세션 만료 또는 OAuth의 user:profile 권한을 확인하고 다시 연결해 주세요.")
        case 429: throw GaugeError.rateLimited(Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 120)
        default: throw GaugeError.message("Claude 응답 오류 (HTTP \(http.statusCode)). 잠시 후 다시 시도합니다.")
        }
        return data
    }

    func organizations(secret: String) async throws -> [ClaudeOrganization] {
        let data = try await get("/api/organizations", secret: secret, kind: .claudeSession)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw GaugeError.unsupported }
        let orgs = json.compactMap { item -> ClaudeOrganization? in
            guard let id = item["uuid"] as? String, UUID(uuidString: id) != nil else { return nil }
            return ClaudeOrganization(id: id, name: item["name"] as? String ?? "개인 계정")
        }
        guard !orgs.isEmpty else { throw GaugeError.message("이 계정에 연결된 Claude 조직을 찾지 못했어요.") }
        return orgs
    }

    func identity(secret: String, kind: ConnectionKind) async -> String? {
        guard let data = try? await get(kind.usesClaudeOAuth ? "/api/oauth/profile" : "/api/account", secret: secret, kind: kind),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let account = json["account"] as? [String: Any] ?? json
        return account["email"] as? String ?? account["email_address"] as? String
    }

    func usage(account: Account, secret: String) async throws -> UsageSnapshot {
        let path: String
        if account.kind.usesClaudeOAuth { path = "/api/oauth/usage" }
        else {
            guard let org = account.organizationID, UUID(uuidString: org) != nil else {
                throw GaugeError.message("연결된 Claude 조직이 없어요. 계정을 다시 연결해 주세요.")
            }
            path = "/api/organizations/\(org)/usage"
        }
        return try UsageParser.claude(await get(path, secret: secret, kind: account.kind))
    }
}
