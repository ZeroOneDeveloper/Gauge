import Foundation
import Security
import GaugeCore

enum LocalStorage {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Gauge", isDirectory: true)
    }
    static func prepare(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func profile(_ id: UUID) throws -> URL {
        let url = root.appendingPathComponent("CodexProfiles/\(id.uuidString)", isDirectory: true)
        try prepare(url)
        return url
    }
    static func claudeProfile(_ id: UUID) throws -> URL {
        let url = root.appendingPathComponent("ClaudeProfiles/\(id.uuidString)", isDirectory: true)
        try prepare(url)
        return url
    }
    static func load() throws -> PersistedState {
        let url = root.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return PersistedState() }
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw GaugeError.message("다른 버전의 데이터입니다. 앱을 업데이트해 주세요.") }
        return state
    }
    static func save(_ state: PersistedState) throws {
        try prepare(root)
        let url = root.appendingPathComponent("state.json")
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum CredentialVault {
    private static let service = "kr.uniquegood.gauge.credentials"
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    static func read(_ id: UUID, allowInteraction: Bool = false) throws -> String {
        guard let data = try KeychainAccess.read(service: service, account: id.uuidString, allowInteraction: allowInteraction),
              let text = String(data: data, encoding: .utf8) else { throw GaugeError.unauthorized }
        return text
    }
    static func write(_ secret: String, for id: UUID) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw GaugeError.message("키체인 저장에 실패했어요. 기존 인증 정보는 유지됩니다.") }
        var request = query(id)
        request[kSecValueData as String] = data
        request[kSecAttrLabel as String] = "Gauge 계정 인증"
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else {
            throw GaugeError.message("키체인에 인증 정보를 저장하지 못했어요.")
        }
    }
    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GaugeError.message("키체인에서 인증 정보를 삭제하지 못했어요. 키체인 잠금 상태를 확인해 주세요.")
        }
    }
}
