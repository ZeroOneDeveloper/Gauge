import Foundation
import GaugeCore

/// Gauge owns these isolated profiles. Refresh a normal browser login with the
/// same grant and scopes, rather than the CLI's one-year setup-token import.
final class ClaudeOAuthRefresh: NSObject, URLSessionTaskDelegate {
    static let shared = ClaudeOAuthRefresh()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    static func request(for oauth: [String: Any]) throws -> URLRequest {
        guard let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty,
              let scopes = oauth["scopes"] as? [String], !scopes.isEmpty else { throw GaugeError.unauthorized }
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refresh,
            "client_id": oauth["clientId"] as? String ?? "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": scopes.joined(separator: " "),
        ])
        // expires_in is intentionally absent: renewing a subscription login
        // must not request the CLI setup-token's one-year token lifetime.
        return request
    }

    func refresh(_ oauth: [String: Any]) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: Self.request(for: oauth))
        guard let http = response as? HTTPURLResponse else { throw GaugeError.unsupported }
        if let error = Self.responseError(status: http.statusCode, data: data,
                                          retryAfter: http.value(forHTTPHeaderField: "Retry-After")) { throw error }
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GaugeError.unsupported }
        return try Self.updated(oauth, response: response)
    }

    static func responseError(status: Int, data: Data, retryAfter: String? = nil) -> Error? {
        guard !(200...299).contains(status) else { return nil }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let nested = payload["error"] as? [String: Any]
        let code = payload["error"] as? String ?? nested?["type"] as? String ?? nested?["code"] as? String
        let body = String(decoding: data.prefix(8192), as: UTF8.self).lowercased()
        if payload["cloudflare_error"] != nil || body.contains("cloudflare") || body.contains("just a moment") {
            return GaugeError.message("Claude 인증 서버의 보안 확인으로 갱신이 차단됐어요. 잠시 후 자동으로 다시 확인합니다. 로그인을 반복할 필요는 없어요.")
        }
        if status == 429 { return GaugeError.rateLimited(Int(retryAfter ?? "") ?? 120) }
        if [400, 401].contains(status), code == "invalid_grant" { return GaugeError.unauthorized }
        if ["invalid_scope", "invalid_client", "unauthorized_client"].contains(code ?? "") {
            return GaugeError.message("Claude가 현재 인증 갱신 방식을 거절했어요. ‘다시 로그인’으로 새 인증을 연결해 주세요. 기존 계정과 기록은 유지됩니다.")
        }
        // An HTTP status alone cannot establish that a stored login was revoked.
        return GaugeError.message("Claude 인증 갱신 요청이 거절됐어요 (HTTP \(status)). 잠시 후 다시 확인합니다.")
    }

    static func updated(_ original: [String: Any], response: [String: Any], now: Date = Date()) throws -> [String: Any] {
        guard let access = response["access_token"] as? String, !access.isEmpty,
              let seconds = UsageParser.number(response["expires_in"]), seconds > 0, seconds < 253402300800 else {
            throw GaugeError.unsupported
        }
        var updated = original
        updated["accessToken"] = access
        updated["expiresAt"] = (now.timeIntervalSince1970 + seconds) * 1000
        if let refresh = response["refresh_token"] as? String, !refresh.isEmpty { updated["refreshToken"] = refresh }
        if let scope = response["scope"] as? String, !scope.isEmpty { updated["scopes"] = scope.split(separator: " ").map(String.init) }
        if let expiry = response["refresh_token_expires_in"] as? NSNumber {
            updated["refreshTokenExpiresAt"] = (now.timeIntervalSince1970 + expiry.doubleValue) * 1000
        }
        return updated
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
