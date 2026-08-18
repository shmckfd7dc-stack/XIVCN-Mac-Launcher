import Foundation
import Network

enum CNDCTravelError: LocalizedError {
    case invalidResponse(String)
    case server(code: Int, message: String)
    case listener(String)
    case invalidRPC(String)

    var isMaintenance: Bool {
        if case .server(let code, _) = self { return code == -10_339_180 }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail): return "国服超域旅行响应无效：\(detail)"
        case .server(let code, let message): return "国服超域旅行服务返回 \(code)：\(message)"
        case .listener(let detail): return "国服超域旅行本地服务启动失败：\(detail)"
        case .invalidRPC(let detail): return "国服超域旅行插件请求无效：\(detail)"
        }
    }
}

private enum CNDCTravelReferer {
    case travel, travelWithTicket, order
}

actor CNDCTravelClient {
    private let endpoints: RegionEndpoints
    private let tgt: String
    private let guid: String
    private let session: URLSession
    private let onGameSession: (String) async -> Void
    private let onSetArea: (String) async -> Void
    private var cookies = ["CAS_LOGIN_STATE": "1", "SECURE_CAS_LOGIN_STATE": "1", "isLogin": "1"]
    private var ticket = ""
    private var initialized = false

    init(endpoints: RegionEndpoints, tgt: String, guid: String,
         onGameSession: @escaping (String) async -> Void,
         onSetArea: @escaping (String) async -> Void) {
        self.endpoints = endpoints
        self.tgt = tgt
        self.guid = guid
        self.onGameSession = onGameSession
        self.onSetArea = onSetArea
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        // Keep the travel site's cookies inside this actor. Using the shared
        // process cookie store would leave authentication state behind after
        // the launcher exits and would make a precise clean uninstall
        // impossible without touching unrelated sdo.com cookies.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    func initialize() async throws {
        let login = try CNCoreLoginBackend(endpoints: endpoints)
        ticket = try await login.refreshDCTravelSession(tgt: tgt, guid: guid)
        _ = try await requestData(path: "api/gmallinter/validateTicket",
                                  parameters: ["ticket": ticket], referer: .travelWithTicket,
                                  requiresInitialization: false, retrySession: false)
        _ = try await requestData(path: "api/orderserivce/pageInit",
                                  parameters: ["migrationType": "4"], referer: .travelWithTicket,
                                  requiresInitialization: false, retrySession: false)
        initialized = true
    }

    func shutdown() {
        initialized = false
        session.invalidateAndCancel()
    }

    func invoke(method: String, parameters: [Any]) async throws -> Any {
        guard initialized || method == "RefreshGameSessionId" || method == "SetSdoArea" else {
            throw CNDCTravelError.invalidRPC("服务尚未完成国服鉴权")
        }
        switch method {
        case "RefreshGameSessionId":
            let service = try CNCoreLoginBackend(endpoints: endpoints)
            let value = try await service.refreshSession(tgt: tgt, guid: guid)
            await onGameSession(value)
            return value
        case "SetSdoArea":
            guard let name = parameters.first as? String, !name.isEmpty else {
                throw CNDCTravelError.invalidRPC("SetSdoArea 缺少大区名称")
            }
            await onSetArea(name)
            return NSNull()
        case "QueryGroupListTravelSource":
            let data = try await requestData(path: "api/orderserivce/queryGroupListTravelSource",
                                             parameters: ["appId": CNRegionProfile.gameAppID], referer: .travel)
            return try areaList(from: data, action: method)
        case "QueryGroupListTravelTarget":
            let areaID = try intParameter(parameters, 0, method)
            let groupID = try intParameter(parameters, 1, method)
            let data = try await requestData(path: "api/orderserivce/queryGroupListTravelTarget",
                                             parameters: ["appId": CNRegionProfile.gameAppID,
                                                          "areaId": String(areaID), "groupId": String(groupID)],
                                             referer: .travel)
            return try areaList(from: data, action: method)
        case "QueryRoleList":
            let areaID = try intParameter(parameters, 0, method)
            let groupID = try intParameter(parameters, 1, method)
            let data = try await requestData(path: "api/gmallgateway/queryRoleList4Migration",
                                             parameters: ["appId": CNRegionProfile.gameAppID,
                                                          "areaId": String(areaID), "groupId": String(groupID)],
                                             referer: .travel)
            try ensureResult(data, action: method)
            return try jsonArray(in: data, key: "roleList", action: method).compactMap { item -> [String: Any]? in
                guard var role = item as? [String: Any] else { return nil }
                role["AreaID"] = areaID
                role["GroupID"] = groupID
                return role
            }
        case "QueryTravelQueueTime":
            // The publisher removed this API. Atmo keeps this exact zero
            // result solely as the live plugin RPC compatibility contract;
            // it is not a simulated network result.
            return 0
        case "TravelOrder":
            guard parameters.count >= 3,
                  let target = parameters[0] as? [String: Any],
                  let source = parameters[1] as? [String: Any],
                  let character = parameters[2] as? [String: Any] else {
                throw CNDCTravelError.invalidRPC("TravelOrder 参数不完整")
            }
            let role = [["roleId": try string(character, ["roleId", "ContentID"]),
                         "roleName": try string(character, ["roleName", "Name"]), "key": 0] as [String: Any]]
            let roleData = try JSONSerialization.data(withJSONObject: role)
            let roleJSON = String(data: roleData, encoding: .utf8) ?? "[]"
            let data = try await requestData(path: "api/orderserivce/travelOrder", parameters: [
                "appId": CNRegionProfile.gameAppID, "migrationType": "4", "isMigrationTimes": "1", "productId": "1",
                "areaId": String(try int(source, ["AreaID", "areaId"])),
                "areaName": try string(source, ["AreaName", "areaName"]),
                "groupId": String(try int(source, ["groupId", "GroupID"])),
                "groupCode": try string(source, ["groupCode", "GroupCode"]),
                "groupName": try string(source, ["groupName", "GroupName"]),
                "targetArea": String(try int(target, ["AreaID", "areaId"])),
                "targetAreaName": try string(target, ["AreaName", "areaName"]),
                "targetGroupId": String(try int(target, ["groupId", "GroupID"])),
                "targetGroupCode": try string(target, ["groupCode", "GroupCode"]),
                "targetGroupName": try string(target, ["groupName", "GroupName"]),
                "roleList": roleJSON
            ], referer: .travel)
            try ensureResult(data, action: method)
            return try string(data, ["orderId"])
        case "QueryOrderStatus":
            let orderID = try stringParameter(parameters, 0, method)
            let data = try await requestData(path: "api/gmallgateway/queryOrderStatus",
                                             parameters: ["orderId": orderID], referer: .travel)
            let status = try int(data, ["migrationStatus"])
            var checkMessage = ""
            var migrationMessage = ""
            if let raw = data["migrationMsg"] as? String,
               let messageData = raw.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: messageData) as? [[String: Any]],
               let first = array.first {
                checkMessage = first["checkMsg"] as? String ?? ""
                migrationMessage = first["migrationMsg"] as? String ?? ""
            }
            return ["Status": status, "CheckMessage": checkMessage, "MigrationMessage": migrationMessage]
        case "InitOrderPage":
            do {
                _ = try await requestData(path: "api/orderserivce/pageInit",
                                          parameters: ["migrationType": "0"], referer: .order)
                return true
            } catch { return false }
        case "QueryMigrationOrders":
            let page = parameters.isEmpty ? 1 : try intParameter(parameters, 0, method)
            let data = try await requestData(path: "api/orderserivce/queryMigrationOrders",
                                             parameters: ["appId": CNRegionProfile.gameAppID,
                                                          "pageIndex": String(page), "pageNum": "10"],
                                             referer: .order)
            try ensureResult(data, action: method)
            let rawOrders = try jsonArray(in: data, key: "orderlist", action: method)
            let orders = rawOrders.compactMap(Self.normalizedMigrationOrder)
            return ["Orders": orders, "TotalCount": try int(data, ["totalCount"]),
                    "TotalPageNum": try int(data, ["totalPageNum"])]
        case "TravelBack":
            let orderID = try stringParameter(parameters, 0, method)
            let groupID = try intParameter(parameters, 1, method)
            let groupCode = try stringParameter(parameters, 2, method)
            let groupName = try stringParameter(parameters, 3, method)
            let data = try await requestData(path: "api/orderserivce/travelBack", parameters: [
                "travelOrderId": orderID, "groupId": String(groupID),
                "groupCode": groupCode, "groupName": groupName
            ], referer: .order)
            try ensureResult(data, action: method)
            return try string(data, ["orderId"])
        default:
            throw CNDCTravelError.invalidRPC("未知或未授权的方法 \(method)")
        }
    }

    private func requestData(path: String, parameters: [String: String], referer: CNDCTravelReferer,
                             requiresInitialization: Bool = true, retrySession: Bool = true) async throws -> [String: Any] {
        if requiresInitialization && !initialized { throw CNDCTravelError.invalidRPC("服务尚未初始化") }
        do {
            return try await requestDataOnce(path: path, parameters: parameters, referer: referer)
        } catch let error as CNDCTravelError where retrySession && !error.isMaintenance {
            initialized = false
            try await initialize()
            return try await requestDataOnce(path: path, parameters: parameters, referer: referer)
        }
    }

    private func requestDataOnce(path: String, parameters: [String: String], referer: CNDCTravelReferer) async throws -> [String: Any] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "ff14bjz.sdo.com"
        components.path = "/" + path
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw CNDCTravelError.invalidResponse("URL 无效") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/137.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue(cookies.keys.sorted().compactMap { key in
            cookies[key].map { "\(key)=\($0)" }
        }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        switch referer {
        case .travel: request.setValue("https://ff14bjz.sdo.com/RegionKanTelepo", forHTTPHeaderField: "Referer")
        case .travelWithTicket:
            request.setValue("https://ff14bjz.sdo.com/RegionKanTelepo?ticket=\(ticket)", forHTTPHeaderField: "Referer")
        case .order: request.setValue("https://ff14bjz.sdo.com/orderList", forHTTPHeaderField: "Referer")
        }
        let (body, response) = try await session.data(for: request)
        captureCookies(from: response, url: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CNDCTravelError.invalidResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw CNDCTravelError.invalidResponse("不是 JSON 对象")
        }
        let code = (root["return_code"] as? NSNumber)?.intValue ?? Int(root["return_code"] as? String ?? "") ?? Int.min
        guard code == 0 else {
            throw CNDCTravelError.server(code: code, message: root["return_message"] as? String ?? "unknown")
        }
        guard let data = root["data"] as? [String: Any] else {
            throw CNDCTravelError.invalidResponse("缺少 data")
        }
        return data
    }

    private func captureCookies(from response: URLResponse, url: URL) {
        guard let http = response as? HTTPURLResponse else { return }
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
            result[String(describing: item.key)] = String(describing: item.value)
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            cookies[cookie.name] = cookie.value
        }
    }

    private func areaList(from data: [String: Any], action: String) throws -> [[String: Any]] {
        try ensureResult(data, action: action)
        return try jsonArray(in: data, key: "groupList", action: action).compactMap { item in
            guard var area = item as? [String: Any] else { return nil }
            let areaID = (area["areaId"] as? NSNumber)?.intValue ?? 0
            let areaName = area["areaName"] as? String ?? ""
            if let groups = area["groups"] as? [[String: Any]] {
                area["groups"] = groups.map { value in
                    var group = value
                    group["AreaID"] = areaID
                    group["AreaName"] = areaName
                    return group
                }
            }
            return area
        }
    }

    private func ensureResult(_ data: [String: Any], action: String) throws {
        let code = try int(data, ["resultCode"])
        guard code == 0 else {
            throw CNDCTravelError.server(code: code, message: data["resultMessage"] as? String ?? action)
        }
    }

    private func jsonArray(in data: [String: Any], key: String, action: String) throws -> [Any] {
        guard let raw = data[key] as? String, let json = raw.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: json) as? [Any] else {
            throw CNDCTravelError.invalidResponse("\(action) 缺少 \(key)")
        }
        return array
    }

    private func intParameter(_ values: [Any], _ index: Int, _ action: String) throws -> Int {
        guard values.indices.contains(index) else { throw CNDCTravelError.invalidRPC("\(action) 参数不足") }
        if let value = values[index] as? NSNumber { return value.intValue }
        if let value = values[index] as? String, let result = Int(value) { return result }
        throw CNDCTravelError.invalidRPC("\(action) 参数 \(index) 不是整数")
    }

    private func stringParameter(_ values: [Any], _ index: Int, _ action: String) throws -> String {
        guard values.indices.contains(index), let value = values[index] as? String, !value.isEmpty else {
            throw CNDCTravelError.invalidRPC("\(action) 参数 \(index) 不是字符串")
        }
        return value
    }

    private func string(_ dictionary: [String: Any], _ keys: [String]) throws -> String {
        for key in keys { if let value = dictionary[key] as? String, !value.isEmpty { return value } }
        throw CNDCTravelError.invalidRPC("缺少字段 \(keys.joined(separator: "/"))")
    }

    private func int(_ dictionary: [String: Any], _ keys: [String]) throws -> Int {
        for key in keys {
            if let value = dictionary[key] as? NSNumber { return value.intValue }
            if let value = dictionary[key] as? String, let result = Int(value) { return result }
        }
        throw CNDCTravelError.invalidRPC("缺少整数字段 \(keys.joined(separator: "/"))")
    }

    private static func normalizedMigrationOrder(_ value: Any) -> [String: Any]? {
        guard let order = value as? [String: Any],
              let status = integer(order["migrationStatus"]), status == 5,
              let type = integer(order["migrationType"]), type == 4,
              let travelStatus = integer(order["travelStatus"]), travelStatus == 1,
              let details = order["migrationDetailList"] as? [[String: Any]], let detail = details.first,
              let orderID = order["orderId"] as? String,
              let contentID = detail["roleId"] as? String,
              let groupID = integer(order["groupId"]),
              let groupCode = order["groupCode"] as? String,
              let groupName = order["groupName"] as? String,
              let createTime = order["createTime"] as? String else { return nil }
        return ["orderId": orderID, "roleId": contentID, "groupId": groupID,
                "groupCode": groupCode, "groupName": groupName, "createTime": createTime,
                "travelStatus": travelStatus, "roleName": detail["roleName"] as? String ?? "",
                "sourceAreaName": detail["areaName"] as? String ?? order["areaName"] as? String ?? "",
                "sourceGroupName": detail["groupName"] as? String ?? groupName,
                "targetAreaName": order["targetAreaName"] as? String ?? detail["targetAreaName"] as? String ?? "",
                "targetGroupName": order["targetGroupName"] as? String ?? detail["targetGroupName"] as? String ?? ""]
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

final class CNDCTravelRPCServer: @unchecked Sendable {
    private let client: CNDCTravelClient
    private let queue = DispatchQueue(label: "cn.ffxivmac.dctravel.rpc", qos: .utility)
    private var listener: NWListener?

    init(client: CNDCTravelClient) { self.client = client }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = CNListenerStartGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    guard let port = listener.port else {
                        continuation.resume(throwing: CNDCTravelError.listener("没有分配端口")); return
                    }
                    continuation.resume(returning: port.rawValue)
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: CNDCTravelError.listener(error.localizedDescription))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        Task { await client.shutdown() }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if accumulated.count > 1_048_576 { self.send(connection, status: 413, body: Data()); return }
            if let request = self.completeRequest(accumulated) {
                Task { await self.process(request, connection: connection) }
            } else if complete || error != nil {
                self.send(connection, status: 400, body: Data())
            } else {
                self.receive(connection, buffer: accumulated)
            }
        }
    }

    private func completeRequest(_ data: Data) -> (headers: String, body: Data)? {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: marker),
              let headers = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let contentLength = headers.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        let bodyStart = range.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        return (headers, data.subdata(in: bodyStart..<(bodyStart + contentLength)))
    }

    private func process(_ request: (headers: String, body: Data), connection: NWConnection) async {
        do {
            let firstLine = request.headers.split(separator: "\r\n").first.map(String.init) ?? ""
            guard firstLine.hasPrefix("POST /dctravel/") || firstLine.hasPrefix("POST /dctravel ") else {
                throw CNDCTravelError.invalidRPC("路径无效")
            }
            guard !request.headers.lowercased().contains("\r\norigin:") else {
                send(connection, status: 403, body: Data("CORS Forbidden".utf8)); return
            }
            guard let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let method = (object["Method"] ?? object["method"]) as? String else {
                throw CNDCTravelError.invalidRPC("缺少 Method")
            }
            let parameters = (object["Params"] ?? object["params"]) as? [Any] ?? []
            let result = try await client.invoke(method: method, parameters: parameters)
            let body = try JSONSerialization.data(withJSONObject: ["Result": result, "Error": NSNull()])
            send(connection, status: 200, body: body)
        } catch {
            let body = (try? JSONSerialization.data(withJSONObject: ["Result": NSNull(), "Error": error.localizedDescription])) ?? Data()
            send(connection, status: 200, body: body)
        }
    }

    private func send(_ connection: NWConnection, status: Int, body: Data) {
        let label = status == 200 ? "OK" : "Error"
        let header = "HTTP/1.1 \(status) \(label)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class CNListenerStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

@MainActor
final class CNDCTravelRuntime {
    private var server: CNDCTravelRPCServer?
    private(set) var port: UInt16 = 0

    func start(store: SettingsStore, areas: [CNLoginArea]) async throws -> UInt16 {
        stop()
        guard !store.settings.cnTGT.isEmpty, !store.settings.cnGUID.isEmpty else {
            throw CNDCTravelError.invalidRPC("需要先完成国服登录")
        }
        let client = CNDCTravelClient(endpoints: store.endpoints, tgt: store.settings.cnTGT,
                                      guid: store.settings.cnGUID,
                                      onGameSession: { value in
                                          await MainActor.run { store.updateGameSessionTicket(value) }
                                      }, onSetArea: { name in
                                          await MainActor.run {
                                              guard let area = areas.first(where: { $0.name == name && $0.status == 1 }) else { return }
                                              store.settings.cnAreaID = area.id
                                              store.settings.cnLobbyHost = area.lobbyHost
                                              store.settings.cnGMHost = area.gmHost
                                              store.settings.cnSaveDataBankHost = area.configUploadHost
                                          }
                                      })
        let server = CNDCTravelRPCServer(client: client)
        let port = try await server.start()
        do {
            try await client.initialize()
        } catch {
            server.stop()
            throw error
        }
        self.server = server
        self.port = port
        return port
    }

    func stop() {
        server?.stop()
        server = nil
        port = 0
    }
}
