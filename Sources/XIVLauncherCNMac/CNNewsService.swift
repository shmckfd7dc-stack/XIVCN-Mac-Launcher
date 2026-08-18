import Foundation

struct CNNewsItem: Equatable, Identifiable, Sendable {
    let id: Int
    let title: String
    let publishedAt: Date?
    let detailURL: URL
    let imageURL: URL?
}

enum CNNewsState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

final class CNNewsService: @unchecked Sendable {
    static let feedURL = URL(string: "https://cqnews.web.sdo.com/api/news/newsList?gameCode=ff&CategoryCode=5203&pageIndex=0&pageSize=8")!

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? CNNetworkSession.requestResponse(requestTimeout: 15, resourceTimeout: 30)
    }

    func fetchLatest() async throws -> [CNNewsItem] {
        var components = URLComponents(url: Self.feedURL, resolvingAgainstBaseURL: false)!
        var queryItems = components.queryItems ?? []
        // Avoid stale CDN/proxy responses while keeping the request frequency
        // limited to startup and explicit user retries.
        queryItems.append(URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970))))
        components.queryItems = queryItems
        var request = URLRequest(url: components.url ?? Self.feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CNNewsError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> [CNNewsItem] {
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw CNNewsError.invalidResponse }
        guard envelope.code == "0" else { throw CNNewsError.service(envelope.message) }

        return envelope.data.compactMap { item in
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let detailURL = Self.officialURL(item.outLink) else { return nil }
            return CNNewsItem(id: item.id, title: item.title,
                              publishedAt: Self.dateFormatter.date(from: item.publishDate),
                              detailURL: detailURL, imageURL: Self.officialURL(item.homeImagePath))
        }
    }

    private static func officialURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host?.lowercased(),
              host == "sdo.com" || host.hasSuffix(".sdo.com") else { return nil }
        return url
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()

    private struct Envelope: Decodable {
        let data: [WireItem]
        let code: String
        let message: String

        enum CodingKeys: String, CodingKey {
            case data = "Data"
            case code = "Code"
            case message = "Message"
        }
    }

    private struct WireItem: Decodable {
        let id: Int
        let homeImagePath: String
        let outLink: String
        let publishDate: String
        let title: String

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case homeImagePath = "HomeImagePath"
            case outLink = "OutLink"
            case publishDate = "PublishDate"
            case title = "Title"
        }
    }
}

enum CNNewsError: LocalizedError {
    case httpStatus(Int)
    case invalidResponse
    case service(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "国服资讯服务返回 HTTP \(code)。"
        case .invalidResponse: return "国服资讯响应格式无效。"
        case .service(let message): return message.isEmpty ? "国服资讯服务暂时不可用。" : message
        }
    }
}
