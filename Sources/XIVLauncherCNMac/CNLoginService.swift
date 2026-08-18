import Foundation
import Security

struct CNLoginSession: Codable, Equatable {
    let account: String
    let sndaID: String
    let tgt: String
    let guid: String
    let area: CNLoginArea
    let areasInfo: String
    let sessionID: String
    let quickLoginSecret: String?
    let weGameToken: String?
}

struct CNSecureSession: Codable, Equatable {
    let tgt: String
    let guid: String
    let sessionID: String
    let sndaID: String
}

/// A saved account is discovered from the real Keychain entries. The
/// launcher never treats launcher.json as a credential store.
struct CNSavedAccount: Identifiable, Equatable {
    let account: String
    let hasPassword: Bool
    let hasQuickLogin: Bool
    let hasSession: Bool

    var id: String { account }
}

enum CNLoginServiceError: LocalizedError {
    case emptyCredentials
    case quickLoginUnavailable
    case weGameTokenUnavailable
    case noArea
    case server(String)

    var errorDescription: String? {
        switch self {
        case .emptyCredentials: return "请输入国服账号，动态验证登录需要账号。"
        case .quickLoginUnavailable: return "国服快速续登凭据不可用，请重新扫码或动态验证登录。"
        case .weGameTokenUnavailable: return "没有找到 WeGame 登录信息，请先导入 Windows 端导出的 UserId/Token。"
        case .noArea: return "国服没有可用的大区。"
        case .server(let message): return message
        }
    }
}

final class CNKeychain {
    static var service: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["XIVCN_DEBUG_KEYCHAIN_SERVICE"], !override.isEmpty {
            return override
        }
        #endif
        return "cn.xivlaunchermac.credentials"
    }

    let serviceName: String

    init(service: String = CNKeychain.service) {
        precondition(!service.isEmpty)
        serviceName = service
    }

    func save(account: String, password: String) throws { try saveValue(password, account: account) }
    func load(account: String) -> String? { loadValue(account: account) }
    func saveSecret(_ value: String, account: String) throws { try saveValue(value, account: "secret.\(account)") }
    func loadSecret(account: String) -> String? { loadValue(account: "secret.\(account)") }
    func saveWeGameToken(_ value: String, account: String) throws { try saveValue(value, account: "wegame.\(account)") }
    func loadWeGameToken(account: String) -> String? { loadValue(account: "wegame.\(account)") }
    func deleteWeGameToken(account: String) { deleteValue(account: "wegame.\(account)") }

    func savedAccounts() -> [CNSavedAccount] {
        var accounts: [String: (password: Bool, secret: Bool, session: Bool)] = [:]
        for name in keychainAccountNames() {
            if name.hasPrefix("secret.") {
                let account = String(name.dropFirst("secret.".count))
                guard !account.isEmpty else { continue }
                accounts[account, default: (false, false, false)].secret = true
            } else if name.hasPrefix("session.") {
                let account = String(name.dropFirst("session.".count))
                guard !account.isEmpty else { continue }
                accounts[account, default: (false, false, false)].session = true
            } else if !name.isEmpty {
                accounts[name, default: (false, false, false)].password = true
            }
        }
        return accounts.map { account, flags in
            CNSavedAccount(account: account, hasPassword: flags.password,
                           hasQuickLogin: flags.secret, hasSession: flags.session)
        }.sorted { $0.account.localizedCaseInsensitiveCompare($1.account) == .orderedAscending }
    }

    func savedQuickLoginAccounts() -> [CNSavedAccount] { savedAccounts().filter(\.hasQuickLogin) }

    func deleteAccount(account: String) {
        guard !account.isEmpty else { return }
        deleteValue(account: account)
        deleteSecret(account: account)
        deleteWeGameToken(account: account)
        deleteSession(account: account)
    }

    func deleteSecret(account: String) { deleteValue(account: "secret.\(account)") }
    func deleteSession(account: String) { deleteValue(account: "session.\(account)") }

    func deleteAllProjectItems() throws {
        for account in keychainAccountNames() {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: serviceName,
                                        kSecAttrAccount as String: account]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CNKeychainError.deleteFailed(status)
            }
        }
    }

    func saveSession(_ session: CNSecureSession, account: String) throws {
        let value = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        try saveValue(value, account: "session.\(account)")
    }

    func loadSession(account: String) -> CNSecureSession? {
        guard let value = loadValue(account: "session.\(account)"), let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CNSecureSession.self, from: data)
    }

    private func deleteValue(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: serviceName,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    private func saveValue(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: serviceName,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw CNKeychainError.saveFailed(status) }
    }

    private func loadValue(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: serviceName,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainAccountNames() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: serviceName,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let values = result as? [[String: Any]] else { return [] }
        return values.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

enum CNKeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status): return "无法安全保存国服账号凭据（OSStatus \(status)）。"
        case .deleteFailed(let status): return "无法从系统钥匙串删除本项目凭据（OSStatus \(status)）。"
        }
    }
}
