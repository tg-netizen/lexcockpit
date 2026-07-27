import Foundation
import Security

/// All API tokens live in the macOS Keychain — never in UserDefaults, code,
/// logs or the projects.json. Generic-password items under one service name.
enum Keychain {
    static let service = "com.lexdigestglobal.lexcockpit"

    /// In-memory cache: each item is read from the keychain AT MOST once per
    /// launch (the ACL prompt, if any, appears once instead of per request).
    private static var memo: [String: String?] = [:]
    private static let lock = NSLock()

    // Accounts
    static let netlifyPAT = "netlify_pat"
    static let netlifyBuildHook = "netlify_build_hook"
    static let githubPAT = "github_pat"

    static func get(_ account: String) -> String? {
        lock.lock()
        if let hit = memo[account] { lock.unlock(); return hit }
        lock.unlock()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        var result: String? = nil
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let str = String(data: data, encoding: .utf8),
           !str.isEmpty {
            result = str
        }
        lock.lock(); memo[account] = result; lock.unlock()
        return result
    }

    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return delete(account) }
        let data = Data(trimmed.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        lock.lock(); memo[account] = trimmed; lock.unlock()
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        lock.lock(); memo[account] = nil as String?; lock.unlock()
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func has(_ account: String) -> Bool { get(account) != nil }
}
