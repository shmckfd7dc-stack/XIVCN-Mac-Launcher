import Foundation

/// UI adapter for the original Core login assembly. No CAS/SDO request,
/// cookie, GUID, ticket or session logic is implemented in Swift.
final class CNCoreLoginBackend {
    private let areaClient: CNLoginClient

    init(endpoints: RegionEndpoints = RegionEndpoints(), session: URLSession? = nil) throws {
        let validated = try endpoints.validated()
        areaClient = try CNLoginClient(endpoints: validated, session: session)
    }

    func fetchAreas() async throws -> [CNLoginArea] {
        try await areaClient.fetchAreas().sorted { $0.order < $1.order }
    }

    func login(account: String, password: String, area: CNLoginArea? = nil,
               quickLogin: Bool = true,
               progress: ((String) async -> Void)? = nil) async throws -> CNLoginSession {
        guard !account.isEmpty, !password.isEmpty else { throw CNLoginServiceError.emptyCredentials }
        await progress?("正在验证国服账号…")
        var request = OldCoreBridgeRequest(command: "loginStatic")
        request.account = account
        request.password = password
        request.autoLogin = quickLogin
        let payload = try await runLogin(request)
        return try makeSession(payload, requestedAccount: account, selectedArea: area)
    }

    func quickLogin(account: String, secret: String, area: CNLoginArea? = nil,
                    progress: ((String) async -> Void)? = nil) async throws -> CNLoginSession {
        guard !account.isEmpty, !secret.isEmpty else { throw CNLoginServiceError.quickLoginUnavailable }
        await progress?("正在使用快速续登凭据…")
        var request = OldCoreBridgeRequest(command: "loginSession")
        request.account = account
        request.sessionKey = secret
        let payload = try await runLogin(request)
        return try makeSession(payload, requestedAccount: account, selectedArea: area)
    }

    func loginWeGame(account: String, token: String, area: CNLoginArea? = nil,
                     quickLogin: Bool = true,
                     progress: ((String) async -> Void)? = nil) async throws -> CNLoginSession {
        guard !account.isEmpty, !token.isEmpty else { throw CNLoginServiceError.emptyCredentials }
        await progress?("正在验证 WeGame 凭据…")
        var request = OldCoreBridgeRequest(command: "loginWeGame")
        request.account = account
        request.token = token
        request.autoLogin = quickLogin
        let payload = try await runLogin(request)
        return try makeSession(payload, requestedAccount: account, selectedArea: area, weGameToken: token)
    }

    func loginQRCode(area: CNLoginArea? = nil, quickLogin: Bool = true,
                     onQRCode: ((Data) async -> Void)? = nil,
                     progress: ((String) async -> Void)? = nil) async throws -> CNLoginSession {
        await progress?("正在获取扫码二维码…")
        var request = OldCoreBridgeRequest(command: "loginQr")
        request.autoLogin = quickLogin
        let payload = try await runLogin(request) { event in
            guard event.type == "qrCode", let encoded = event.data,
                  let data = Data(base64Encoded: encoded) else { return }
            Task { await onQRCode?(data) }
        }
        return try makeSession(payload, requestedAccount: "", selectedArea: area)
    }

    func loginSlide(account: String, area: CNLoginArea? = nil, quickLogin: Bool = true,
                    onVerificationCode: ((String) async -> Void)? = nil,
                    progress: ((String) async -> Void)? = nil) async throws -> CNLoginSession {
        guard !account.isEmpty else { throw CNLoginServiceError.emptyCredentials }
        await progress?("正在发起动态验证…")
        var request = OldCoreBridgeRequest(command: "loginSlide")
        request.account = account
        request.autoLogin = quickLogin
        let payload = try await runLogin(request) { event in
            guard event.type == "verificationCode", let code = event.data else { return }
            Task { await onVerificationCode?(code) }
        }
        return try makeSession(payload, requestedAccount: account, selectedArea: area)
    }

    func refreshSession(tgt: String, guid: String) async throws -> String {
        guard !tgt.isEmpty, !guid.isEmpty else { throw CNLoginServiceError.quickLoginUnavailable }
        var request = OldCoreBridgeRequest(command: "getSessionId")
        request.tgt = tgt
        request.guid = guid
        let events = try await OldCoreBridge.execute(request)
        guard let value = events.last(where: { $0.type == "sessionId" })?.data, !value.isEmpty else {
            throw OldCoreBridgeError.invalidResponse
        }
        return value
    }

    func refreshDCTravelSession(tgt: String, guid: String) async throws -> String {
        guard !tgt.isEmpty, !guid.isEmpty else { throw CNLoginServiceError.quickLoginUnavailable }
        var request = OldCoreBridgeRequest(command: "getDcTravelSessionId")
        request.tgt = tgt
        request.guid = guid
        let events = try await OldCoreBridge.execute(request)
        guard let value = events.last(where: { $0.type == "sessionId" })?.data, !value.isEmpty else {
            throw OldCoreBridgeError.invalidResponse
        }
        return value
    }

    private func runLogin(_ request: OldCoreBridgeRequest,
                          onEvent: (@Sendable (OldCoreBridgeEvent) -> Void)? = nil) async throws -> OldCoreLoginPayload {
        let events = try await OldCoreBridge.execute(request, onEvent: onEvent)
        guard let payload = events.last(where: { $0.type == "loginResult" })?.login,
              payload.state == "Ok" else { throw OldCoreBridgeError.invalidResponse }
        return payload
    }

    private func makeSession(_ payload: OldCoreLoginPayload, requestedAccount: String,
                             selectedArea: CNLoginArea?, weGameToken: String? = nil) throws -> CNLoginSession {
        guard let selectedArea else { throw CNLoginServiceError.noArea }
        guard let tgt = payload.tgt, !tgt.isEmpty,
              let guid = payload.guid, !guid.isEmpty else {
            throw OldCoreBridgeError.invalidResponse
        }
        let encodedAreas = try JSONEncoder().encode([selectedArea]).base64EncodedString()
        let account = payload.account.isEmpty ? requestedAccount : payload.account
        return CNLoginSession(account: account,
                              sndaID: payload.sndaId,
                              tgt: tgt,
                              guid: guid,
                              area: selectedArea,
                              areasInfo: encodedAreas,
                              sessionID: payload.sessionId,
                              quickLoginSecret: payload.autoLoginSessionKey,
                              weGameToken: weGameToken)
    }
}
