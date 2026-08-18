import Foundation
import Darwin

enum GameHandoffState: Equatable {
    case waiting
    case gameRunning(Int32)
    case launchProcessFailed(Int32)
}

enum GameLaunchError: LocalizedError {
    case missingExecutable(URL)
    case missingWine(URL)
    case missingRosetta
    case missingCNSession
    case missingRuntime
    case dalamudUnavailable(String)
    case dalamudRuntimeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let url): return "找不到游戏可执行文件: \(url.path)"
        case .missingWine(let url): return "缺少 XOM 5.4.2 Wine Runtime: \(url.path)"
        case .missingRosetta: return "Core 与 Wine Runtime 需要 Rosetta 2。"
        case .missingCNSession: return "尚未完成国服登录。"
        case .missingRuntime: return "Wine / DXMT Runtime 尚未安装完成。"
        case .dalamudUnavailable(let variant): return "\(variant) 运行环境未准备好，请先检查或更新。"
        case .dalamudRuntimeUnavailable(let variant): return "\(variant) Windows .NET Runtime 未准备好，请先检查或更新。"
        }
    }
}

struct LaunchedGame: @unchecked Sendable {
    let process: Process?
    let gameWinePID: Int32?
    let usesDalamudInjector: Bool
}

final class CoreBackend {
    private let store: SettingsStore

    init(store: SettingsStore) { self.store = store }

    @MainActor
    func launch() async throws -> LaunchedGame {
        let settings = store.settings
        let paths = store.paths
        guard settings.hasCompleteCNLaunchFields else { throw GameLaunchError.missingCNSession }
        guard Self.rosettaIsInstalled() else { throw GameLaunchError.missingRosetta }

        let gamePath = settings.activeGamePath(managedPath: paths.managedGame.path)
        let executable = URL(fileURLWithPath: gamePath).appendingPathComponent("game/ffxiv_dx11.exe")
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw GameLaunchError.missingExecutable(executable)
        }
        guard paths.usesBundledXOMRuntime else { throw GameLaunchError.missingRuntime }
        let wine = paths.wineRuntime.appendingPathComponent("bin/wine64")
        guard FileManager.default.isExecutableFile(atPath: wine.path) else {
            throw GameLaunchError.missingWine(wine)
        }
        guard let resources = Bundle.main.resourceURL else { throw GameLaunchError.missingRuntime }
        // The packaged XOM 5.4.2 runtime is the only launch baseline.  A
        // pre-existing ~/.xlcore_cn is diagnostic data, never an implicit
        // source of Wine, Prefix, DXMT or old Win7 settings.
        let effectiveTools = resources.appendingPathComponent("core-tools")
        let effectivePrefix = paths.winePrefix
        let effectiveWine = wine
        let effectiveLog = paths.logs.appendingPathComponent("old-core-game.log")
        let selectedDalamud = settings.dalamudVariant

        // These launch-time preparations must happen before the bridge starts
        // the Windows client, otherwise a stale Prefix backend can leave a live
        // but black game process. Keep them off the AppKit main actor so
        // resource preparation never turns the launcher into a beachball.
        let gameRoot = URL(fileURLWithPath: gamePath)
        try await Task.detached(priority: .userInitiated) {
            Self.appendLaunchDiagnostic(logs: paths.logs, "LaunchStage prepare-start")
            try CNLoginEntryInstaller.ensureLoginEntry(gameRoot: gameRoot, verifyIntegrity: false)
            Self.appendLaunchDiagnostic(logs: paths.logs, "LaunchStage sdo-ready")
            try GameConfiguration.prepare(paths: paths, gameRoot: gameRoot)
            Self.appendLaunchDiagnostic(logs: paths.logs, "LaunchStage game-config-ready")
            try XOMGraphicsInstaller.ensureBackend(paths: paths)
            Self.appendLaunchDiagnostic(logs: paths.logs, "LaunchStage dxmt-prefix-ready")
        }.value

        var request = OldCoreBridgeRequest(command: "launch")
        request.patchPath = paths.caches.path
        request.gamePath = gamePath
        request.sessionId = settings.cnSessionID
        request.sndaId = settings.cnSndaID
        request.dcTravelPort = settings.cnDCTravelerPort
        request.areaId = settings.cnAreaID
        request.lobbyHost = settings.cnLobbyHost
        request.gmHost = settings.cnGMHost
        request.dbHost = settings.cnSaveDataBankHost
        // The verified old-Core path passes an empty areasInfo value to
        // LaunchGameSdo.  The GUI still keeps the fetched area list for
        // selection, but injecting a reconstructed XL.LobbyHosts payload
        // changes the game's login argument set and is not part of the
        // known-good launch contract.
        request.areasInfo = ""
        request.wineBinPath = effectiveWine.deletingLastPathComponent().path
        request.prefixPath = effectivePrefix.path
        // CompatibilityTools appends "dxmt/dxmt" internally. Keep this
        // resource layout identical to the old Core contract so it installs
        // the bundled XOM 5.4.2 files instead of downloading its old DXMT.
        request.toolsPath = effectiveTools.path
        request.logPath = effectiveLog.path
        // Do not add UserPath here.  The old Core source constructs a local
        // UserPath candidate but calls LaunchGameSdo with the original empty
        // AdditionalArgs; the successful baseline therefore lets the client
        // use its normal config location.
        request.wineDebug = settings.wineDebug
        request.eSync = false
        request.fSync = false
        request.mSync = settings.msyncEnabled
        request.modernMvk = true
        request.frameLimit = settings.maxFrameRate
        // MetalFX is handled by the old Core's existing DXMT environment path.
        // Metal HUD is the single XOM environment flag and does not require
        // launching Wine registry commands or mutating the Prefix.
        request.metalFx = settings.superResolutionEnabled
        request.metalFxFactor = settings.metalFxSpatialFactor
        request.wineEnvironment = "MTL_HUD_ENABLED=\(settings.metalHUDEnabled ? 1 : 0)"
        request.dalamudEnabled = selectedDalamud != .disabled
        if selectedDalamud != .disabled {
            let dalamudRoot = paths.dalamudRoot(for: selectedDalamud)
            request.dalamudInjectorPath = dalamudRoot
                .appendingPathComponent("ACTIVE/Dalamud.Injector.exe").path
            request.dalamudRuntimePath = paths.dalamudRuntime(for: selectedDalamud).path
            request.dalamudAssetsPath = dalamudRoot
                .appendingPathComponent("assets/ACTIVE", isDirectory: true).path
            request.dalamudConfigPath = paths.dalamudConfigFile(for: selectedDalamud).path
            request.dalamudPluginPath = paths.dalamudPluginDirectory(for: selectedDalamud).path
            request.dalamudLogPath = paths.dalamudLogDirectory(for: selectedDalamud).path
            request.dalamudInjectionDelayMs = max(0, Int(settings.dalamudInjectionDelay * 1000))
            request.noThirdPartyPlugins = settings.noThirdPartyPlugins
        }
        Self.appendLaunchDiagnostic(
            logs: paths.logs,
            "LaunchFeatures metalFx=\(settings.superResolutionEnabled) " +
            "factor=\(settings.metalFxSpatialFactor) metalHud=\(settings.metalHUDEnabled) registry=false")
        Self.appendLaunchDiagnostic(logs: paths.logs, "LaunchStage bridge-start")
        let events = try await OldCoreBridge.execute(request)
        let gameUnixPID = events.last(where: { $0.type == "launched" })?.pid
        let wrapperPIDText = gameUnixPID.map(String.init) ?? "none"
        Self.appendLaunchDiagnostic(logs: paths.logs,
                                    "LaunchStage bridge-launched wrapperPID=\(wrapperPIDText)")
        return LaunchedGame(process: nil, gameWinePID: gameUnixPID,
                            usesDalamudInjector: selectedDalamud != .disabled)
    }

    static func gameUnixPID(processName: String = "ffxiv_dx11.exe",
                            gamePath: String? = nil,
                            preferredPID: Int32? = nil) -> Int32? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = preferredPID.map { ["-p", String($0), "-o", "pid=,command="] } ??
            ["-axo", "pid=,command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Drain stdout before waiting. A running Wine tree can make `ps` output
        // larger than the pipe buffer; waiting first would deadlock when `ps`
        // blocks on a full pipe.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: output, encoding: .utf8) else { return nil }
        let expectedPath = gamePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]) else { continue }
            let command = String(fields[1])
            guard commandMatchesGameProcess(command, processName: processName,
                                            expectedPath: expectedPath) else { continue }
            return pid
        }
        return nil
    }

    static func commandMatchesGameProcess(_ command: String, processName: String = "ffxiv_dx11.exe",
                                          expectedPath: String?) -> Bool {
        guard let executableRange = command.range(of: processName, options: .caseInsensitive) else {
            return false
        }
        // Crash handlers and injectors include ffxiv_dx11.exe only as an
        // argument. The real game command has no earlier Windows executable.
        let prefix = command[..<executableRange.lowerBound]
        guard prefix.range(of: ".exe", options: .caseInsensitive) == nil else { return false }
        guard let expectedPath, !expectedPath.isEmpty else { return true }
        let wineBackslashPath = "Z:" + expectedPath.replacingOccurrences(of: "/", with: "\\")
        let wineSlashPath = "Z:" + expectedPath
        return [expectedPath, wineBackslashPath, wineSlashPath].contains {
            command.range(of: $0, options: .caseInsensitive) != nil
        }
    }

    static func processIsRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func gameHandoffState(gamePID: Int32?, launchProcessIsRunning: Bool,
                                 launchProcessTerminationStatus: Int32?) -> GameHandoffState {
        if let gamePID { return .gameRunning(gamePID) }
        if !launchProcessIsRunning, let status = launchProcessTerminationStatus, status != 0 {
            return .launchProcessFailed(status)
        }
        return .waiting
    }

    static func launchLogTail(logs: URL, maxBytes: Int = 6_000) -> String? {
        let file = logs.appendingPathComponent("old-core-game.log")
        guard let data = try? Data(contentsOf: file), !data.isEmpty,
              let text = String(data: data.suffix(maxBytes), encoding: .utf8) else { return nil }
        return text
    }

    static func appendLaunchDiagnostic(logs: URL, _ line: String) {
        let file = logs.appendingPathComponent("old-core-game.log")
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    static func rosettaIsInstalled(fileManager: FileManager = .default,
                                   receipt: URL = URL(fileURLWithPath: "/Library/Apple/System/Library/Receipts/com.apple.pkg.RosettaUpdateAuto.plist")) -> Bool {
        #if arch(arm64)
        return fileManager.fileExists(atPath: receipt.path)
        #else
        return true
        #endif
    }
}
