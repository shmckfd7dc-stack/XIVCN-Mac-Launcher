import Foundation

/// Lightweight area-list client. Authentication and session exchange live
/// exclusively in the source-built Core bridge.
final class CNLoginClient {
    private let session: URLSession
    private let endpoints: RegionEndpoints

    private static let userAgent = "Mozilla/4.0 (compatible; MSIE 8.0; Windows NT 5.1; Trident/4.0; Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1; SV1) ; InfoPath.2; .NET CLR 2.0.50727; MS-RTC LM 8; .NET CLR 3.0.04506.648; .NET CLR 3.5.21022; .NET CLR 1.1.4322; .NET CLR 3.0.4506.2152; .NET CLR 3.5.30729)"

    init(endpoints: RegionEndpoints = RegionEndpoints(), session: URLSession? = nil) throws {
        self.endpoints = try endpoints.validated()
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func fetchAreas() async throws -> [CNLoginArea] {
        guard var components = URLComponents(string: endpoints.loginAreaURL),
              components.port == nil else { throw CNLoginError.invalidAreaEndpoint }
        components.port = endpoints.loginAreaPort
        guard let url = components.url else { throw CNLoginError.invalidAreaEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(endpoints.loginRefererURL, forHTTPHeaderField: "Referer")
        request.setValue(url.host, forHTTPHeaderField: "Host")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try Self.parseAreaList(data)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw CNLoginError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private static func parseAreaList(_ data: Data) throws -> [CNLoginArea] {
        guard var text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let marker = text.range(of: "var servers=") else {
            throw CNLoginError.invalidAreaResponse
        }
        text.removeSubrange(text.startIndex..<marker.upperBound)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.last == ";" { text.removeLast() }
        guard let json = text.data(using: .utf8) else { throw CNLoginError.invalidAreaResponse }
        struct WireArea: Decodable {
            let Areaid: String
            let AreaStat: Int
            let AreaOrder: Int
            let AreaName: String
            let Areatype: Int
            let AreaLobby: String
            let AreaGm: String
            let AreaPatch: String
            let AreaConfigUpload: String
        }
        do {
            return try JSONDecoder().decode([WireArea].self, from: json).map {
                CNLoginArea(id: $0.Areaid, status: $0.AreaStat, order: $0.AreaOrder,
                            name: $0.AreaName, type: $0.Areatype,
                            lobbyHost: $0.AreaLobby, gmHost: $0.AreaGm,
                            patchHost: $0.AreaPatch, configUploadHost: $0.AreaConfigUpload)
            }
        } catch {
            throw CNLoginError.invalidAreaResponse
        }
    }
}

enum CNLoginError: LocalizedError {
    case invalidAreaEndpoint
    case invalidAreaResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAreaEndpoint: return "国服大区列表端点无效。"
        case .invalidAreaResponse: return "国服大区列表响应格式无效。"
        case .httpStatus(let code): return "国服登录服务返回 HTTP \(code)。"
        }
    }
}
