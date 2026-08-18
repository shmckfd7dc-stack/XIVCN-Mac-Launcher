import Foundation
import Security
import Testing
@testable import XIVLauncherCNMac

 @Test func allCNLoginMethodsAreVisibleAndSessionStatusNeedsRealFields() {
    #expect(CNLoginMethod.userVisibleCases(hasSavedQuickLogin: false) == [.slide, .qrCode, .password, .weGame])
    #expect(CNLoginMethod.userVisibleCases(hasSavedQuickLogin: true) == [.quickLogin, .slide, .qrCode, .password, .weGame])
    var settings = LauncherSettings()
    settings.cnAccount = "account"
    #expect(!settings.hasCompleteCNLaunchFields)
    settings.cnSessionID = "session"
    settings.cnSndaID = "snda"
    settings.cnAreaID = "area"
    settings.cnLobbyHost = "lobby.example"
    settings.cnGMHost = "gm.example"
    settings.cnSaveDataBankHost = "save.example"
    #expect(settings.hasCompleteCNLaunchFields)
}

@Test func authStatePreservesTheActiveAccountAcrossFailedSwitches() {
    let active = CNAuthState.authenticated(account: "account-a")
    let switching = active.startingAuthentication(candidate: "account-b")
    #expect(switching == .switching(activeAccount: "account-a", candidate: "account-b"))
    #expect(switching.isAuthenticated)
    #expect(switching.authenticatedAccount == "account-a")
    #expect(switching.afterFailedAuthentication(message: "rejected") == .authenticated(account: "account-a"))
    #expect(switching.afterCancelledAuthentication() == .authenticated(account: "account-a"))

    let loggedOut = CNAuthState.loggedOut.startingAuthentication(candidate: "account-b")
    #expect(!loggedOut.isAuthenticated)
    #expect(loggedOut.afterFailedAuthentication(message: "rejected") == .failed(message: "rejected"))
}

@Test @MainActor func storedSessionRequiresValidationAndLogoutPreservesQuickLogin() throws {
    let identifier = UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xivcn-auth-\(identifier)")
    let paths = ManagedPaths(applicationSupport: root.appendingPathComponent("support"),
                             caches: root.appendingPathComponent("caches"),
                             logs: root.appendingPathComponent("logs"))
    let keychain = CNKeychain(service: "cn.xivlaunchermac.tests.auth.\(identifier)")
    defer {
        try? keychain.deleteAllProjectItems()
        try? FileManager.default.removeItem(at: root)
    }

    try paths.createDirectories()
    do {
        try keychain.saveSecret("quick-secret", account: "account-a")
        try keychain.saveSession(CNSecureSession(tgt: "stored-tgt", guid: "stored-guid",
                                                 sessionID: "stale-ticket", sndaID: "snda-a"),
                                 account: "account-a")
        try keychain.saveSecret("other-secret", account: "account-b")
        try keychain.saveSession(CNSecureSession(tgt: "other-tgt", guid: "other-guid",
                                                 sessionID: "other-ticket", sndaID: "snda-b"),
                                 account: "account-b")
    } catch CNKeychainError.saveFailed(let status)
        where status == errSecInteractionNotAllowed || status == errSecNotAvailable || status == errSecParam {
        return
    }

    var persisted = LauncherSettings()
    persisted.cnAccount = "account-a"
    persisted.quickLoginEnabled = true
    persisted.cnTGT = "must-not-load-from-json"
    persisted.cnGUID = "must-not-load-from-json"
    persisted.cnSessionID = "must-not-be-authenticated"
    persisted.cnSndaID = "must-not-be-authenticated"
    persisted.cnAreaID = "1"
    persisted.cnLobbyHost = "lobby.example.cn"
    persisted.cnGMHost = "gm.example.cn"
    persisted.cnSaveDataBankHost = "save.example.cn"
    try JSONEncoder().encode(persisted).write(
        to: paths.config.appendingPathComponent("launcher.json"), options: .atomic)

    let store = SettingsStore(paths: paths, keychain: keychain)
    #expect(store.settings.cnTGT.isEmpty)
    #expect(store.settings.cnGUID.isEmpty)
    #expect(store.settings.cnSessionID.isEmpty)
    #expect(store.settings.cnSndaID.isEmpty)
    #expect(keychain.loadSession(account: "account-a") != nil)

    let secure = try #require(keychain.loadSession(account: "account-a"))
    store.activateRestoredSession(account: "account-a", secure: secure, ticket: "fresh-ticket")
    #expect(store.settings.cnSessionID == "fresh-ticket")
    #expect(store.settings.hasCompleteCNLaunchFields)

    #expect(store.logoutCurrentSession() == "account-a")
    #expect(store.settings.cnAccount == "account-a")
    #expect(store.settings.cnTGT.isEmpty)
    #expect(store.settings.cnSessionID.isEmpty)
    #expect(keychain.loadSession(account: "account-a") == nil)
    #expect(keychain.loadSecret(account: "account-a") == "quick-secret")
    #expect(keychain.loadSession(account: "account-b") != nil)
    #expect(keychain.loadSecret(account: "account-b") == "other-secret")
}

@Test func loginInputValidationDoesNotUseDisabledButtonsAsFeedback() {
    #expect(CNLoginInputValidator.issue(method: .password, account: "", password: "") == .accountAndPassword)
    #expect(CNLoginInputValidator.issue(method: .password, account: "cn-user", password: "") == .password)
    #expect(CNLoginInputValidator.issue(method: .password, account: "", password: "secret") == .account)
    #expect(CNLoginInputValidator.issue(method: .password, account: "cn-user", password: "secret") == nil)
    #expect(CNLoginInputValidator.issue(method: .slide, account: "", password: "") == .account)
    #expect(CNLoginInputValidator.issue(method: .slide, account: "cn-user", password: "") == nil)
}

@Test func retinaToggleUsesPositiveHighResolutionSemantics() {
    var settings = LauncherSettings()
    #expect(settings.retinaEnabled)
    settings.macOSScalingEnabled = true
    #expect(!settings.retinaEnabled)
    settings.macOSScalingEnabled = false
    #expect(settings.retinaEnabled)
}

@Test func managedAndExternalGameInstallsCanCoexistAndSwitch() throws {
    var settings = LauncherSettings()
    let managed = "/Library/Application Support/XIVCN Mac Launcher/game"
    let external = "/Games/FFXIV CN"

    settings.setExternalGamePath(external, select: true, managedPath: managed)
    #expect(settings.gameOwnership == .external)
    #expect(settings.gamePath == external)

    settings.selectGameInstall(.managed, managedPath: managed)
    #expect(settings.gamePath == managed)
    #expect(settings.externalGamePath == external)

    settings.selectGameInstall(.external, managedPath: managed)
    #expect(settings.gamePath == external)

    let restored = try JSONDecoder().decode(LauncherSettings.self, from: JSONEncoder().encode(settings))
    #expect(restored.externalGamePath == external)
}

@Test func activeGamePathIsLockedToTheSelectedSource() {
    var settings = LauncherSettings()
    let managed = "/Managed/FFXIV CN"
    let external = "/External/FFXIV CN"

    settings.setExternalGamePath(external, select: true, managedPath: managed)
    settings.gamePath = "/stale/compatibility/path"
    #expect(settings.activeGamePath(managedPath: managed) == external)

    settings.gameOwnership = .managed
    settings.gamePath = external
    #expect(settings.activeGamePath(managedPath: managed) == managed)
}

@Test func externalGamePathCannotBeNestedInLauncherManagedData() {
    let root = URL(fileURLWithPath: "/private/tmp/xivcn-path-safety")
    let paths = ManagedPaths(applicationSupport: root.appendingPathComponent("support"),
                             caches: root.appendingPathComponent("caches"),
                             logs: root.appendingPathComponent("logs"))
    #expect(!GameInstallManager.externalGamePathIsSafe(
        paths.applicationSupport.appendingPathComponent("external-game"), paths: paths))
    #expect(!GameInstallManager.externalGamePathIsSafe(paths.caches, paths: paths))
    #expect(GameInstallManager.externalGamePathIsSafe(
        root.appendingPathComponent("user-owned-game"), paths: paths))
}

@Test func gameFileActivationReplacesVerifiedFileAndRollsBackOnFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent("game.dat")
    let temporary = root.appendingPathComponent("game.dat.xivcn-download")

    try Data("old".utf8).write(to: destination)
    try Data("new".utf8).write(to: temporary)
    try CNGameUpdateClient.activateDownloadedFile(temporary, at: destination)
    #expect(try Data(contentsOf: destination) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("xivcn-backup").path))

    let missingTemporary = root.appendingPathComponent("missing-download")
    #expect(throws: (any Error).self) {
        try CNGameUpdateClient.activateDownloadedFile(missingTemporary, at: destination)
    }
    #expect(try Data(contentsOf: destination) == Data("new".utf8))
}

@Test func legacyExternalGamePathIsMigratedWithoutDataLoss() throws {
    let data = Data(#"{"gamePath":"/Games/Legacy FFXIV","gameOwnership":"external"}"#.utf8)
    var settings = try JSONDecoder().decode(LauncherSettings.self, from: data)
    settings.reconcileGameInstallPaths(managedPath: "/Managed/FFXIV")
    #expect(settings.externalGamePath == "/Games/Legacy FFXIV")
    #expect(settings.gamePath == "/Games/Legacy FFXIV")
}

@Test func managedGameRemovalCannotTouchExternalInstall() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = ManagedPaths(applicationSupport: root.appendingPathComponent("support"),
                             caches: root.appendingPathComponent("cache"),
                             logs: root.appendingPathComponent("logs"))
    let external = root.appendingPathComponent("external-game")
    try FileManager.default.createDirectory(at: paths.managedGame, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try Data("external".utf8).write(to: external.appendingPathComponent("keep.txt"))

    var settings = LauncherSettings()
    settings.selectGameInstall(.managed, managedPath: paths.managedGame.path)
    try GameInstallManager().removeGame(settings: settings, paths: paths)
    #expect(!FileManager.default.fileExists(atPath: paths.managedGame.path))
    #expect(FileManager.default.fileExists(atPath: external.appendingPathComponent("keep.txt").path))
}

@Test func gameConfigurationDoesNotChangeDynamicResolution() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = ManagedPaths(applicationSupport: root.appendingPathComponent("support"),
                             caches: root.appendingPathComponent("cache"),
                             logs: root.appendingPathComponent("logs"))
    let template = root.appendingPathComponent("FFXIV-MacDefault.cfg")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "<UI Settings>\r\nDynamicRezoType\t1\r\n".write(to: template, atomically: true, encoding: .utf8)
    try GameConfiguration.prepare(paths: paths, defaultTemplate: template)
    let config = paths.gameConfig.appendingPathComponent("FFXIV.cfg")
    #expect(try String(contentsOf: config, encoding: .utf8).contains("DynamicRezoType\t1"))
    #expect(!FileManager.default.fileExists(atPath: config.appendingPathExtension("fixed-render-scale-backup.json").path))
}

@Test func gameConfigurationOnlyAppliesTheExistingCutsceneFixToTheCNConfig() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = ManagedPaths(applicationSupport: root.appendingPathComponent("support"),
                             caches: root.appendingPathComponent("cache"),
                             logs: root.appendingPathComponent("logs"))
    let template = root.appendingPathComponent("FFXIV-MacDefault.cfg")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "<UI Settings>\r\n".write(to: template, atomically: true, encoding: .utf8)
    let gameRoot = root.appendingPathComponent("game-root")
    let config = gameRoot.appendingPathComponent(
        "game/My Games/FINAL FANTASY XIV - A Realm Reborn/FFXIV.cfg")
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try "<UI Settings>\r\nDynamicRezoType\t1\r\nCutsceneMovieOpening\t0\r\n"
        .write(to: config, atomically: true, encoding: .utf8)

    try GameConfiguration.prepare(paths: paths, gameRoot: gameRoot, defaultTemplate: template)
    let updated = try String(contentsOf: config, encoding: .utf8)
    #expect(updated.contains("DynamicRezoType\t1"))
    #expect(updated.contains("CutsceneMovieOpening\t1"))
    #expect(!FileManager.default.fileExists(
        atPath: config.appendingPathExtension("fixed-render-scale-backup.json").path))
}

@Test func metalFxDefaultsToOneAndOffersOnlyTheXOMFactor() throws {
    var settings = LauncherSettings()
    #expect(settings.metalFxSpatialFactor == 1.0)
    settings.xomMetalFxModeEnabled = true
    #expect(settings.metalFxSpatialFactor == 2.0)
    let legacy = try JSONDecoder().decode(
        LauncherSettings.self,
        from: Data(#"{"renderScale":0.5,"fixedRenderScale":true}"#.utf8)
    )
    let encoded = String(data: try JSONEncoder().encode(legacy), encoding: .utf8) ?? ""
    #expect(!encoded.contains("renderScale"))
    #expect(!encoded.contains("fixedRenderScale"))
}

@Test func metalFxDoesNotOverrideTheUsersRetinaPreference() {
    var settings = LauncherSettings()
    settings.macOSScalingEnabled = false
    settings.superResolutionEnabled = true
    #expect(settings.retinaEnabled)
    settings.superResolutionEnabled = false
    #expect(settings.retinaEnabled)
}

@Test func runtimeUsesOnlyBundledXOMWineAndSeparateDxmtDirectory() {
    let paths = ManagedPaths()
    #expect(paths.wineRuntime.lastPathComponent == "wine")
    #expect(paths.dxmt.lastPathComponent == "dxmt")
    #expect(paths.dxmtD3D11.deletingLastPathComponent() == paths.dxmt)
    #expect(paths.dxmtDXGI.deletingLastPathComponent() == paths.dxmt)
    #expect(paths.dxmtD3D11.lastPathComponent == "d3d11.dll")
    #expect(paths.dxmtDXGI.lastPathComponent == "dxgi.dll")
    #expect(BundledRuntime.wineVersion == "5.4.2")
    #expect(BundledRuntime.dxmtVersion == "5.4.2")
}

@Test func managedPathsAreCentralized() {
    let paths = ManagedPaths()
    #expect(paths.applicationSupport.path.hasSuffix("Library/Application Support/XIVCN Mac Launcher"))
    #expect(paths.caches.path.hasSuffix("Library/Caches/XIVCN Mac Launcher"))
    #expect(paths.logs.path.hasSuffix("Library/Logs/XIVCN Mac Launcher"))
    #expect(paths.wineRuntime.lastPathComponent == "wine")
    #expect(paths.dxmtD3D11.path.hasSuffix("/dxmt/d3d11.dll"))
}

@Test func launchHandoffRequiresTheRealGameProcess() {
    #expect(CoreBackend.gameHandoffState(gamePID: nil, launchProcessIsRunning: true,
                                               launchProcessTerminationStatus: nil) == .waiting)
    #expect(CoreBackend.gameHandoffState(gamePID: nil, launchProcessIsRunning: false,
                                               launchProcessTerminationStatus: 53) == .launchProcessFailed(53))
    #expect(CoreBackend.gameHandoffState(gamePID: 4242, launchProcessIsRunning: false,
                                               launchProcessTerminationStatus: 1) == .gameRunning(4242))
}

@Test func gameProcessMatchingSupportsWinePathsAndRejectsCrashHandlerArguments() {
    let gamePath = "/Users/test/Game"
    #expect(CoreBackend.commandMatchesGameProcess(
        #"Z:\Users\test\Game\game\ffxiv_dx11.exe -AppID=100001900"#,
        expectedPath: gamePath
    ))
    #expect(CoreBackend.commandMatchesGameProcess(
        "/Users/test/Game/game/ffxiv_dx11.exe -AppID=100001900",
        expectedPath: gamePath
    ))
    #expect(!CoreBackend.commandMatchesGameProcess(
        #"Z:\DalamudCrashHandler.exe --game=Z:\Users\test\Game\game\ffxiv_dx11.exe"#,
        expectedPath: gamePath
    ))
    #expect(!CoreBackend.commandMatchesGameProcess(
        #"Z:\Users\test\Other\game\ffxiv_dx11.exe -AppID=100001900"#,
        expectedPath: gamePath
    ))
}

@Test func msyncSettingDefaultsOnButCanBeDisabled() throws {
    let settings = try JSONDecoder().decode(
        LauncherSettings.self,
        from: Data(#"{"msyncEnabled":false}"#.utf8)
    )
    #expect(!settings.msyncEnabled)
    #expect(LauncherSettings().msyncEnabled)
}

@Test func cnEndpointsAndPortsCannotBecomeInternational() throws {
    let endpoints = try RegionEndpoints().validated()
    #expect(endpoints.casPort == 443)
    #expect(endpoints.servicePort == 80)
    #expect(endpoints.lobbyPort == 54994)
    #expect(endpoints.launcherAppID == "791000814")
    #expect(endpoints.gameAppID == "100001900")
    #expect(endpoints.dalamudDistributionURL == "https://dalamud-dis.atmoomen.top")
    #expect(endpoints.dalamudPluginRepositoryURL == "https://gh.atmoomen.top/raw.githubusercontent.com/Dalamud-DailyRoutines/PluginDistD17/main/pluginmaster.json")
    #expect(!CNRegionProfile.isCNURL("https://launcher.finalfantasyxiv.com"))
    #expect(!CNRegionProfile.isCNURL("https://goatcorp.github.io"))
}

@Test func dalamudMainRepositoryMigrationPreservesUserConfiguration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("dalamudConfig.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original: [String: Any] = [
        "PluginSafeMode": true,
        "ThirdRepoList": [
            ["Url": "https://raw.githubusercontent.com/Dalamud-DailyRoutines/PluginDistD17/main/pluginmaster.json", "IsEnabled": true],
            ["Url": "https://example.org/custom.json", "IsEnabled": false]
        ]
    ]
    try JSONSerialization.data(withJSONObject: original).write(to: config)

    try CNDalamudUpdater.configurePluginRepository(at: config)
    let decoded = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
    #expect(decoded["PluginSafeMode"] as? Bool == true)
    #expect(decoded["MainRepoUrl"] as? String == CNRegionProfile.dalamudPluginRepositoryURL)
    let repositories = try #require(decoded["ThirdRepoList"] as? [[String: Any]])
    #expect(repositories.count == 1)
    #expect(repositories.first?["Url"] as? String == "https://example.org/custom.json")
    #expect(repositories.first?["IsEnabled"] as? Bool == false)
    let inodeBefore = try #require(
        FileManager.default.attributesOfItem(atPath: config.path)[.systemFileNumber] as? NSNumber
    )
    try CNDalamudUpdater.configurePluginRepository(at: config)
    let inodeAfter = try #require(
        FileManager.default.attributesOfItem(atPath: config.path)[.systemFileNumber] as? NSNumber
    )
    #expect(inodeAfter == inodeBefore)
}

@Test func dalamudActiveVersionsComeFromSymlinkTargets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Hooks/26-08-14-01"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("assets/7"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("ACTIVE").path,
                                               withDestinationPath: "Hooks/26-08-14-01")
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("assets/ACTIVE").path,
                                               withDestinationPath: "7")
    #expect(CNDalamudUpdater.activeVersion(in: root) == "26-08-14-01")
    #expect(CNDalamudUpdater.activeAssetVersion(in: root) == "7")
    #expect(!CNDalamudUpdater.activeInstallationIsHealthy(in: root))
    for name in ["Dalamud.Injector.exe", "Dalamud.dll", "ImGuiScene.dll"] {
        try Data("test".utf8).write(to: root.appendingPathComponent("Hooks/26-08-14-01/\(name)"))
    }
    try Data("asset".utf8).write(to: root.appendingPathComponent("assets/7/asset.dat"))
    #expect(CNDalamudUpdater.activeInstallationIsHealthy(in: root))
}

@Test func dalamudActiveSymlinkSkipsCorrectTargetAndRepairsWrongTarget() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let active = root.appendingPathComponent("ACTIVE")
    #expect(try CNDalamudUpdater.ensureSymbolicLink(at: active, destination: "Hooks/1"))
    #expect(try !CNDalamudUpdater.ensureSymbolicLink(at: active, destination: "Hooks/1"))
    #expect(try CNDalamudUpdater.ensureSymbolicLink(at: active, destination: "Hooks/2"))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: active.path) == "Hooks/2")
}

@Test func cancellableProcessTerminatesTheRunningChild() async throws {
    let task = Task {
        try await CNCancellableProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"]
        )
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    let started = Date()
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Cancelled child process completed successfully")
    } catch is CancellationError {
        #expect(Date().timeIntervalSince(started) < 3)
    } catch {
        Issue.record("Cancelled child process returned \(error) instead of CancellationError")
    }
}

@Test func directoryReplacementRollsBackAndRecoversInterruptedCommit() throws {
    enum ExpectedFailure: Error { case commit }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let final = root.appendingPathComponent("runtime", isDirectory: true)
    let staging = root.appendingPathComponent("runtime-staging", isDirectory: true)
    try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
    try "old".write(to: final.appendingPathComponent("version"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try "new".write(to: staging.appendingPathComponent("version"), atomically: true, encoding: .utf8)

    #expect(throws: ExpectedFailure.self) {
        try CNDirectoryTransaction.replace(staging: staging, final: final, validate: {}, activate: {
            throw ExpectedFailure.commit
        })
    }
    #expect(try String(contentsOf: final.appendingPathComponent("version"), encoding: .utf8) == "old")

    let backup = CNDirectoryTransaction.backupURL(for: final)
    try FileManager.default.moveItem(at: final, to: backup)
    try CNDirectoryTransaction.recover(final: final, backup: backup) { false }
    #expect(try String(contentsOf: final.appendingPathComponent("version"), encoding: .utf8) == "old")
    #expect(!FileManager.default.fileExists(atPath: backup.path))
}

@Test func dalamudVersionPruningKeepsOnlyTheActiveCoreOrAssetsDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for version in ["old", "current"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(version),
                                                withIntermediateDirectories: true)
    }
    try Data("keep".utf8).write(to: root.appendingPathComponent("user-file"))
    CNDalamudUpdater.pruneVersionDirectories(in: root, keeping: "current")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("old").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("current").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("user-file").path))
}

@Test func dalamudRuntimeVersionRequiresActualWindowsRuntimeFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = ManagedPaths(applicationSupport: root.appendingPathComponent("support"),
                             caches: root.appendingPathComponent("cache"),
                             logs: root.appendingPathComponent("logs"))
    let version = "10.0.1"
    let runtime = paths.dalamudRuntime(for: .china)
    for file in ["host/fxr/\(version)/hostfxr.dll",
                 "shared/Microsoft.NETCore.App/\(version)/System.Private.CoreLib.dll",
                 "shared/Microsoft.WindowsDesktop.App/\(version)/WindowsBase.dll"] {
        let url = runtime.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: url)
    }
    try FileManager.default.createDirectory(at: paths.dalamudChina, withIntermediateDirectories: true)
    try version.write(to: paths.dalamudChina.appendingPathComponent("runtime.version"),
                      atomically: true, encoding: .utf8)
    #expect(CNWindowsRuntimeInstaller.installedVersion(paths: paths, variant: .china) == version)
    try FileManager.default.removeItem(at: runtime.appendingPathComponent("host/fxr/\(version)/hostfxr.dll"))
    #expect(CNWindowsRuntimeInstaller.installedVersion(paths: paths, variant: .china) == nil)
}

@Test func explicitDalamudRuntimeVersionDoesNotRequestTheOtherProvider() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = ManagedPaths(applicationSupport: root.appendingPathComponent("support"),
                             caches: root.appendingPathComponent("cache"),
                             logs: root.appendingPathComponent("logs"))
    let version = "10.0.1"
    let runtime = paths.dalamudRuntime(for: .soil)
    for file in ["host/fxr/\(version)/hostfxr.dll",
                 "shared/Microsoft.NETCore.App/\(version)/System.Private.CoreLib.dll",
                 "shared/Microsoft.WindowsDesktop.App/\(version)/WindowsBase.dll"] {
        let url = runtime.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: url)
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockForbiddenNetworkProtocol.self]
    MockForbiddenNetworkProtocol.requestCount = 0
    let installer = CNWindowsRuntimeInstaller(paths: paths, session: URLSession(configuration: configuration))

    try await installer.installRequiredRuntime(variant: .soil, requiredVersion: version)

    #expect(MockForbiddenNetworkProtocol.requestCount == 0)
    #expect(CNWindowsRuntimeInstaller.installedVersion(paths: paths, variant: .soil) == version)
    let versionFile = paths.dalamudSoil.appendingPathComponent("runtime.version")
    let inodeBefore = try #require(
        FileManager.default.attributesOfItem(atPath: versionFile.path)[.systemFileNumber] as? NSNumber
    )
    try await installer.installRequiredRuntime(variant: .soil, requiredVersion: version)
    let inodeAfter = try #require(
        FileManager.default.attributesOfItem(atPath: versionFile.path)[.systemFileNumber] as? NSNumber
    )
    #expect(inodeAfter == inodeBefore)
}

@Test func dalamudVariantsHaveIndependentRootsAndRealSelectionPersistence() throws {
    let paths = ManagedPaths(applicationSupport: URL(fileURLWithPath: "/tmp/variant-layout"),
                             caches: URL(fileURLWithPath: "/tmp/variant-cache"),
                             logs: URL(fileURLWithPath: "/tmp/variant-logs"))
    #expect(paths.dalamudChina != paths.dalamudSoil)
    #expect(paths.dalamudRuntime(for: .china) != paths.dalamudRuntime(for: .soil))
    #expect(paths.dalamudAssets(for: .china) != paths.dalamudAssets(for: .soil))
    #expect(paths.dalamudConfigFile(for: .china) != paths.dalamudConfigFile(for: .soil))
    #expect(paths.dalamudPluginDirectory(for: .china) != paths.dalamudPluginDirectory(for: .soil))
    #expect(paths.dalamudLogDirectory(for: .china) != paths.dalamudLogDirectory(for: .soil))

    var settings = LauncherSettings()
    settings.dalamudVariant = .china
    let restoredChina = try JSONDecoder().decode(LauncherSettings.self,
                                                  from: JSONEncoder().encode(settings))
    #expect(restoredChina.dalamudVariant == .china)
    settings.dalamudVariant = .disabled
    #expect(!settings.dalamudEnabled)
    #expect(throws: CNDalamudUpdateError.self) {
        try CNDalamudUpdater(endpoints: RegionEndpoints(), variant: .disabled)
    }
}

@Test func legacyDalamudCoreIsMigratedIntoSoilWithoutTouchingConfig() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyRoot = root.appendingPathComponent("dalamud")
    try FileManager.default.createDirectory(at: legacyRoot.appendingPathComponent("Hooks/legacy"), withIntermediateDirectories: true)
    try Data("legacy".utf8).write(to: legacyRoot.appendingPathComponent("Hooks/legacy/Dalamud.dll"))
    let paths = ManagedPaths(applicationSupport: root, caches: root.appendingPathComponent("cache"), logs: root.appendingPathComponent("logs"))
    #expect(FileManager.default.fileExists(atPath: paths.dalamudSoil.appendingPathComponent("Hooks/legacy/Dalamud.dll").path))
    #expect(!FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("Hooks").path))
}

@Test func dalamudUpdaterUsesOnlyTheSelectedChinaOrSoilFeed() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockDalamudProviderProtocol.self]
    let session = URLSession(configuration: configuration)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    // Production normal-CN metadata uses lower-case `downloadUrl`, while the
    // other keys retain their published PascalCase spelling.
    MockDalamudProviderProtocol.response = Data(#"{"AssemblyVersion":"2026-08-14-01","SupportedGameVer":"2026.08.14.0000.0000","RuntimeVersion":"10.0.1","RuntimeRequired":true,"downloadUrl":"https://s3.ffxiv.wang/dalamud/china.zip","Hash":""}"#.utf8)
    MockDalamudProviderProtocol.requests.removeAll()
    let china = try CNDalamudUpdater(variant: .china, session: session)
    let chinaRelease = try await china.fetchRelease()
    #expect(chinaRelease.packageURL.host == "s3.ffxiv.wang")
    #expect(MockDalamudProviderProtocol.requests == [CNRegionProfile.normalCNDalamudVersionURL])
    #expect(CNRegionProfile.normalCNDalamudVersionURL.hasSuffix("track=release"))

    MockDalamudProviderProtocol.response = Data(#"{"Version":115,"Assets":[]}"#.utf8)
    MockDalamudProviderProtocol.requests.removeAll()
    let chinaAssets = try await china.prepareAssets(in: root, sevenZip: root.appendingPathComponent("unused"))
    #expect(chinaAssets.version == "115")
    #expect(MockDalamudProviderProtocol.requests == [CNRegionProfile.normalCNDalamudAssetMetaURL])

    MockDalamudProviderProtocol.response = Data("2026-08-14-02".utf8)
    MockDalamudProviderProtocol.requests.removeAll()
    let soil = try CNDalamudUpdater(variant: .soil, session: session)
    _ = try await soil.fetchRelease()
    #expect(MockDalamudProviderProtocol.requests == [CNRegionProfile.dalamudVersionURL])
}

@Test func normalCNFontCompatibilityExceptionIsExact() {
    let published = "C8AC9E680749BF31536971BC51DB257DDBAF3E68"
    let currentNoto = "55A035F929EC089979A886AC98D92B3527B8FF38"
    #expect(CNDalamudUpdater.normalAssetHashMatches(
        fileName: "UIRes/NotoSansCJKsc-Medium.otf",
        publishedHash: published, actualHash: currentNoto
    ))
    #expect(!CNDalamudUpdater.normalAssetHashMatches(
        fileName: "UIRes/another.otf", publishedHash: published, actualHash: currentNoto
    ))
    #expect(!CNDalamudUpdater.normalAssetHashMatches(
        fileName: "UIRes/NotoSansCJKsc-Medium.otf",
        publishedHash: published, actualHash: String(repeating: "0", count: 40)
    ))
}

@Test func officialCNNewsResponseIsParsedWithoutFabricatedItems() throws {
    let json = #"{"Data":[{"Id":391950,"HomeImagePath":"https://fu5.web.sdo.com/news.jpg","OutLink":"https://ff.web.sdo.com/web7/news/news.html?id=391897","PublishDate":"2026/08/12 16:24:28","Title":"国服真实公告"},{"Id":1,"HomeImagePath":"","OutLink":"https://example.com/fake","PublishDate":"2026/08/12 16:24:28","Title":"非官方链接"}],"Code":"0","Message":""}"#
    let items = try CNNewsService.decode(Data(json.utf8))
    #expect(items.count == 1)
    #expect(items[0].title == "国服真实公告")
    #expect(items[0].detailURL.host == "ff.web.sdo.com")
    #expect(items[0].publishedAt != nil)
}

@Test func cancelledGameRepairPropagatesIntoTheDetachedIntegrityScan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let files = Dictionary(uniqueKeysWithValues: (0..<2_000).map {
        ("game/missing-\($0).bin", CNIntegrityFile(size: 1, md5: "c4ca4238a0b923820dcc509a6f75849b"))
    })
    let manifest = CNIntegrityManifest(appID: CNRegionProfile.gameAppID,
                                       baseURL: URL(string: "https://example.org/files")!,
                                       dataVersion: "test", files: files)
    let client = try CNGameUpdateClient()
    let task = Task { try await client.repair(gameRoot: root, manifest: manifest) }
    task.cancel()
    do {
        try await task.value
        Issue.record("Cancelled repair unexpectedly completed")
    } catch is CancellationError {
        // Expected: the detached scan observes cancellation before downloads.
    } catch {
        Issue.record("Cancelled repair returned \(error) instead of CancellationError")
    }
}

@Test func dalamudCoreUpdatesCannotOverlapUserPluginsOrConfiguration() {
    let root = URL(fileURLWithPath: "/tmp/FFXIV-CN-MAC-layout")
    let paths = ManagedPaths(applicationSupport: root, caches: root.appendingPathComponent("cache"),
                             logs: root.appendingPathComponent("logs"))
    let core = paths.dalamud.appendingPathComponent("Hooks/26-08-14-01").standardizedFileURL.path
    let plugins = paths.dalamudPluginDirectory.standardizedFileURL.path
    let config = paths.dalamudConfigFile.standardizedFileURL.path
    #expect(!plugins.hasPrefix(core + "/"))
    #expect(!config.hasPrefix(core + "/"))
    #expect(!core.hasPrefix(paths.config.standardizedFileURL.path + "/"))
}

private final class MockDalamudProviderProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response = Data()
    nonisolated(unsafe) static var requests: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let url = request.url?.absoluteString { Self.requests.append(url) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class MockForbiddenNetworkProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
    }
    override func stopLoading() {}
}

@Test func cnIntegrityManifestAndVersionGraphUseOfficialV3Formats() throws {
    let manifest = try CNGameUpdateClient.parseIntegrityManifest("https://cdn.example.cn/game|100001900|data-v2\ngame/ffxiv_dx11.exe|4|098f6bcd4621d373cade4e832627b4f6")
    #expect(manifest.appID == "100001900")
    #expect(manifest.dataVersion == "data-v2")
    #expect(manifest.files["game/ffxiv_dx11.exe"]?.size == 4)

    let json = #"{"baseUrl":"https://cdn.example.cn/","backupBaseUrl":"","areas":[{"id":"0","max":"data-v2","min":"data-v1","must":"data-v2","back":"","view":"2026.08.14.0000.0000"}],"packages":[{"fileListUrl":"v1-v2.json","forcetype":0,"from":"data-v1","md5":"","name":"patch","to":"data-v2","versionView":"2026.08.14.0000.0000"}]}"#
    let remote = try JSONDecoder().decode(CNGameRemoteVersion.self, from: Data(json.utf8))
    let path = try CNGameUpdateClient.findPackagePath(remote.packages, from: "data-v1", to: "data-v2")
    #expect(path.count == 1)
    #expect(CNGameUpdateClient.resolveGameVersion(dataVersion: "data-v2", remote: remote) == "2026.08.14.0000.0000")
}

@Test func dcTravelPortIsEphemeralButTogglePersists() throws {
    var settings = LauncherSettings()
    settings.dcTravelEnabled = true
    settings.cnDCTravelerPort = 43123
    let restored = try JSONDecoder().decode(LauncherSettings.self, from: JSONEncoder().encode(settings))
    #expect(restored.dcTravelEnabled)
    #expect(restored.cnDCTravelerPort == 0)
}

@Test func dcTravelRPCServerBindsARealLoopbackPort() async throws {
    let client = CNDCTravelClient(endpoints: try RegionEndpoints().validated(), tgt: "", guid: "",
                                  onGameSession: { _ in }, onSetArea: { _ in })
    let server = CNDCTravelRPCServer(client: client)
    let port: UInt16
    do {
        port = try await server.start()
    } catch {
        // The Codex filesystem sandbox denies all listener creation. The same
        // assertion remains active in normal local/CI runs where loopback is
        // permitted; only the OS-level EPERM condition is treated as unavailable.
        if error.localizedDescription.contains("Operation not permitted") { return }
        throw error
    }
    #expect(port > 0)
    server.stop()
}

@Test func gameDetectorSeparatesMissingIncompleteAndReady() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let detector = GameDetector()
    #expect(detector.detect(gameRoot: root) == .missing)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("game"), withIntermediateDirectories: true)
    #expect(detector.detect(gameRoot: root) == .incomplete(reason: "缺少 game/ffxiv_dx11.exe 或 game/ffxiv.exe"))
    try Data("MZ".utf8).write(to: root.appendingPathComponent("game/ffxiv_dx11.exe"))
    try "2026.08.05.0000.0000".write(to: root.appendingPathComponent("game/ffxivgame.ver"), atomically: true, encoding: .utf8)
    #expect(detector.detect(gameRoot: root) == .ready(version: "2026.08.05.0000.0000"))
}

@Test func launcherSettingsFirstLaunchDefaultsAndLegacyDecode() throws {
    #expect(LauncherSettings().firstLaunchCompleted == false)
    #expect(LauncherSettings().firstLaunchStep == 0)
    let legacy = try JSONSerialization.data(withJSONObject: ["gamePath": ""])
    let decoded = try JSONDecoder().decode(LauncherSettings.self, from: legacy)
    #expect(decoded.firstLaunchCompleted == true)
    var settings = LauncherSettings()
    settings.firstLaunchCompleted = true
    settings.firstLaunchStep = 4
    let restored = try JSONDecoder().decode(LauncherSettings.self,
                                             from: JSONEncoder().encode(settings))
    #expect(restored.firstLaunchCompleted)
    #expect(restored.firstLaunchStep == 4)
}

@Test func gameDetectorAcceptsLegacyFfxivExecutableName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let game = root.appendingPathComponent("game", isDirectory: true)
    try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    try Data("MZ".utf8).write(to: game.appendingPathComponent("ffxiv.exe"))
    try "2026.08.05.0000.0000".write(to: game.appendingPathComponent("ffxivgame.ver"), atomically: true, encoding: .utf8)
    #expect(GameDetector().detect(gameRoot: root) == .ready(version: "2026.08.05.0000.0000"))
}

@Test func cleanUninstallRemovesExactKeychainAndLauncherDataOnly() throws {
    let identifier = UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xivcn-clean-\(identifier)")
    let support = root.appendingPathComponent("Application Support/XIVCN Mac Launcher")
    let caches = root.appendingPathComponent("Caches/XIVCN Mac Launcher")
    let logs = root.appendingPathComponent("Logs/XIVCN Mac Launcher")
    let external = root.appendingPathComponent("External Game/game/ffxiv_dx11.exe")
    let paths = ManagedPaths(applicationSupport: support, caches: caches, logs: logs)
    let keychain = CNKeychain(service: "cn.xivlaunchermac.tests.\(identifier)")
    let preferencesDomain = "cn.xivlaunchermac.tests.preferences.\(identifier)"
    let defaults = try #require(UserDefaults(suiteName: preferencesDomain))
    defer {
        try? keychain.deleteAllProjectItems()
        defaults.removePersistentDomain(forName: preferencesDomain)
        try? FileManager.default.removeItem(at: root)
    }

    try paths.createDirectories()
    try FileManager.default.createDirectory(at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("external".utf8).write(to: external)
    try Data("settings".utf8).write(to: paths.config.appendingPathComponent("launcher.json"))
    do {
        try keychain.save(account: "test-account", password: "test-password")
    } catch CNKeychainError.saveFailed(let status)
        where status == errSecInteractionNotAllowed || status == errSecNotAvailable || status == errSecParam {
        // Sandboxed runners can reject Security.framework before a login
        // Keychain is available (including errSecParam). The same exact-item
        // round trip remains active on normal local/CI macOS runners.
        return
    }
    try keychain.saveSecret("test-secret", account: "test-account")
    defaults.set("frame", forKey: CleanUninstallManager.windowFramePreference)
    #expect(!keychain.savedAccounts().isEmpty)

    let report = try CleanUninstallManager(fileManager: .default, keychain: keychain,
                                            userDefaults: defaults,
                                            preferenceDomain: preferencesDomain).removeAll(paths: paths)
    #expect(report.isComplete)
    #expect(keychain.savedAccounts().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: support.path))
    #expect(!FileManager.default.fileExists(atPath: caches.path))
    #expect(!FileManager.default.fileExists(atPath: logs.path))
    #expect(FileManager.default.fileExists(atPath: external.path))
}

@Test func cleanUninstallRefusesToDeleteAnExternalGameNestedInLauncherData() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Application Support/XIVCN Mac Launcher")
    let paths = ManagedPaths(applicationSupport: support,
                             caches: root.appendingPathComponent("Caches/XIVCN Mac Launcher"),
                             logs: root.appendingPathComponent("Logs/XIVCN Mac Launcher"))
    let external = support.appendingPathComponent("Imported External Game")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try Data("external".utf8).write(to: external.appendingPathComponent("keep.txt"))

    #expect(throws: CleanUninstallError.self) {
        try CleanUninstallManager()
            .removeAll(paths: paths, externalGamePath: external.path)
    }
    #expect(FileManager.default.fileExists(atPath: external.appendingPathComponent("keep.txt").path))
}
