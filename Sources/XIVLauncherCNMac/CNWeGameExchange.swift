import AppKit
import Foundation
import UniformTypeIdentifiers

/// The cross-platform payload produced from the old Core's WeGame capture:
/// Windows obtains UserId/Token, and macOS imports those exact values before
/// calling the same SDO thirdPartyLogin endpoint.
struct CNWeGameCredentials: Codable, Equatable {
    let userID: String
    let token: String

    init(userID: String, token: String) {
        self.userID = userID
        self.token = token
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let userID = try Self.firstString(in: container, keys: [.userID, .userId, .userid, .UserID])
        let token = try Self.firstString(in: container, keys: [.token, .Token])
        guard !userID.isEmpty, !token.isEmpty else { throw CNWeGameExchangeError.invalidPayload }
        self.init(userID: userID, token: token)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: OutputKeys.self)
        try container.encode(userID, forKey: .userId)
        try container.encode(token, forKey: .token)
    }

    private static func firstString(in container: KeyedDecodingContainer<CodingKeys>,
                                    keys: [CodingKeys]) throws -> String {
        for key in keys {
            if let value = try container.decodeIfPresent(String.self, forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        throw CNWeGameExchangeError.invalidPayload
    }

    private enum CodingKeys: String, CodingKey {
        case userID, userId, userid, UserID, token, Token
    }

    private enum OutputKeys: String, CodingKey {
        case userId, token
    }
}

enum CNWeGameExchangeError: LocalizedError {
    case canceled
    case invalidFile
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .canceled: return "已取消导入 WeGame 登录信息。"
        case .invalidFile: return "无法读取 WeGame 登录信息文件。"
        case .invalidPayload: return "WeGame 登录信息格式无效，需要导出UserId 和 Token。"
        }
    }
}

@MainActor
enum CNWeGameExchange {
    /// Imports the old Core capture result. The file is intentionally limited
    /// to the old result shape and is never treated as a new login protocol.
    static func importCredentials() throws -> CNWeGameCredentials {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .plainText]
        panel.message = "选择 Windows 端导出的 WeGame 登录信息"
        guard panel.runModal() == .OK, let url = panel.url else { throw CNWeGameExchangeError.canceled }
        guard let data = try? Data(contentsOf: url) else { throw CNWeGameExchangeError.invalidFile }
        do {
            return try JSONDecoder().decode(CNWeGameCredentials.self, from: data)
        } catch {
            throw CNWeGameExchangeError.invalidPayload
        }
    }
}
