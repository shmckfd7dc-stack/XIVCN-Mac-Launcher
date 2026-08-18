import Foundation

struct OldCoreBridgeRequest: Encodable, Sendable {
    let command: String
    var account: String? = nil
    var password: String? = nil
    var sessionKey: String? = nil
    var token: String? = nil
    var autoLogin: Bool = true
    var patchPath: String? = nil
    var gamePath: String? = nil
    var sessionId: String? = nil
    var sndaId: String? = nil
    var dcTravelPort: Int = 0
    var areaId: String? = nil
    var lobbyHost: String? = nil
    var gmHost: String? = nil
    var dbHost: String? = nil
    var areasInfo: String? = nil
    var additionalArguments: String? = nil
    var wineBinPath: String? = nil
    var prefixPath: String? = nil
    var toolsPath: String? = nil
    var logPath: String? = nil
    var wineDebug: String? = nil
    var wineEnvironment: String? = nil
    var eSync: Bool? = true
    var fSync: Bool? = false
    var mSync: Bool? = true
    var modernMvk: Bool? = true
    var frameLimit: Int = 0
    var metalFx: Bool? = false
    var metalFxFactor: Double? = 1.0
    var dalamudEnabled: Bool = false
    var dalamudInjectorPath: String? = nil
    var dalamudRuntimePath: String? = nil
    var dalamudAssetsPath: String? = nil
    var dalamudConfigPath: String? = nil
    var dalamudPluginPath: String? = nil
    var dalamudLogPath: String? = nil
    var dalamudInjectionDelayMs: Int = 0
    var noThirdPartyPlugins: Bool = false
    var tgt: String? = nil
    var guid: String? = nil
}

struct OldCoreBridgeEvent: Decodable, Sendable {
    let type: String
    let message: String?
    let data: String?
    let pid: Int32?
    let login: OldCoreLoginPayload?
}

struct OldCoreLoginPayload: Decodable, Sendable {
    let state: String
    let account: String
    let sessionId: String
    let sndaId: String
    let tgt: String?
    let guid: String?
    let autoLoginSessionKey: String?
    let loginType: String
    let uniqueId: String?
    let dcTravelPort: Int
}

enum OldCoreBridgeError: LocalizedError {
    case missingExecutable(String)
    case launchFailed(String)
    case invalidResponse
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let path): return "测试包缺少Core bridge：\(path)"
        case .launchFailed(let detail): return "无法启动 Core bridge：\(detail)"
        case .invalidResponse: return "Core 没有返回有效结果。"
        case .backend(let message): return message
        }
    }
}

private final class OldCoreBridgeProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate, process.isRunning { process.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

private final class OldCoreBridgeProcessReaper: @unchecked Sendable {
    private let process: Process
    private let output: FileHandle

    init(process: Process, output: FileHandle) {
        self.process = process
        self.output = output
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            while !output.availableData.isEmpty {}
            try? output.close()
            process.waitUntilExit()
        }
    }
}

enum OldCoreBridge {
    static func execute(_ request: OldCoreBridgeRequest,
                        onEvent: (@Sendable (OldCoreBridgeEvent) -> Void)? = nil) async throws -> [OldCoreBridgeEvent] {
        let controller = OldCoreBridgeProcessController()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
            guard let resources = Bundle.main.resourceURL else {
                throw OldCoreBridgeError.missingExecutable("Contents/Resources")
            }
            let executable = resources.appendingPathComponent("core-bridge/XIVLauncherCN.CoreBridge")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw OldCoreBridgeError.missingExecutable(executable.path)
            }

            let process = Process()
            let output = Pipe()
            let input = Pipe()
            process.executableURL = executable
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                throw OldCoreBridgeError.launchFailed(error.localizedDescription)
            }
            controller.attach(process)
            defer { controller.clear() }

            try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
            try input.fileHandleForWriting.close()

            var events: [OldCoreBridgeEvent] = []
            var pending = Data()
            var receivedLaunch = false
            readEvents: while true {
                if controller.isCancelled { throw CancellationError() }
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[..<newline]
                    pending.removeSubrange(...newline)
                    guard let event = try? JSONDecoder().decode(OldCoreBridgeEvent.self, from: line) else { continue }
                    events.append(event)
                    onEvent?(event)
                    if request.command == "launch", event.type == "launched" {
                        receivedLaunch = true
                    }
                }
                if receivedLaunch { break readEvents }
            }
            if controller.isCancelled { throw CancellationError() }
            if !receivedLaunch, !pending.isEmpty,
               let event = try? JSONDecoder().decode(OldCoreBridgeEvent.self, from: pending) {
                events.append(event)
                onEvent?(event)
            }

            if receivedLaunch {
                // LaunchGameSdo has handed the game process to Wine. The bridge
                // keeps a foreground stdout-forwarding thread alive until the
                // game exits. Reap that helper in the background so the GUI can
                // complete its launch handoff as soon as `launched` arrives.
                OldCoreBridgeProcessReaper(process: process,
                                           output: output.fileHandleForReading).start()
                return events
            }
            process.waitUntilExit()
            if controller.isCancelled { throw CancellationError() }
            if let error = events.last(where: { $0.type == "error" }) {
                throw OldCoreBridgeError.backend(error.message ?? "Core 执行失败。")
            }
            guard process.terminationStatus == 0 else {
                throw OldCoreBridgeError.backend("Core bridge 退出码：\(process.terminationStatus)")
            }
            return events
            }.value
        }, onCancel: {
            controller.cancel()
        })
    }
}
