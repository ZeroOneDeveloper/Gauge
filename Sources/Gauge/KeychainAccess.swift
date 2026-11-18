import Foundation
import Security
import LocalAuthentication
import GaugeCore

enum KeychainAccess {
    private static let interactionLock = NSRecursiveLock()

    // Claude Code uses the legacy login keychain. LAContext alone controls
    // modern authentication, but does not suppress legacy application-ACL UI.
    // Scope the process-local legacy policy to this serialized operation.
    static func withInteractionPolicy<T>(allowInteraction: Bool, _ operation: () throws -> T) throws -> T {
        if allowInteraction { interactionLock.lock() }
        else if !interactionLock.try() { throw GaugeError.keychainBusy }
        var previous: DarwinBoolean = false
        SecKeychainGetUserInteractionAllowed(&previous)
        SecKeychainSetUserInteractionAllowed(allowInteraction)
        defer {
            SecKeychainSetUserInteractionAllowed(previous.boolValue)
            interactionLock.unlock()
        }
        return try operation()
    }
    static func query(service: String, account: String? = nil, allowInteraction: Bool = false) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        // Automatic refresh must never put up a password dialog. Only a direct
        // click on the authorization button permits interactive Keychain UI.
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        return query
    }

    static func read(service: String, account: String? = nil, allowInteraction: Bool = false) throws -> Data? {
        var request = query(service: service, account: account, allowInteraction: allowInteraction)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = try withInteractionPolicy(allowInteraction: allowInteraction) {
            SecItemCopyMatching(request as CFDictionary, &result)
        }
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw GaugeError.unsupported }
        return data
    }

    static func update(_ data: Data, service: String, account: String? = nil, allowInteraction: Bool = false) throws {
        let status = try withInteractionPolicy(allowInteraction: allowInteraction) {
            SecItemUpdate(query(service: service, account: account, allowInteraction: allowInteraction) as CFDictionary,
                          [kSecValueData as String: data] as CFDictionary)
        }
        try check(status)
    }

    static func store(_ data: Data, service: String, allowInteraction: Bool = false) throws {
        try withInteractionPolicy(allowInteraction: allowInteraction) {
            let request = query(service: service, allowInteraction: allowInteraction)
            let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecItemNotFound else { try check(status); return }
            var item: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: NSUserName(),
                kSecAttrLabel as String: "Gauge Claude 로그인",
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecValueData as String: data,
            ]
            if let context = request[kSecUseAuthenticationContext as String] {
                item[kSecUseAuthenticationContext as String] = context
            }
            try check(SecItemAdd(item as CFDictionary, nil))
        }
    }

    private static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw GaugeError.keychainAccessRequired
        case errSecItemNotFound: throw GaugeError.unauthorized
        default: throw GaugeError.message("키체인에 접근하지 못했어요 (\(status)). 잠금 상태를 확인해 주세요.")
        }
    }
}
