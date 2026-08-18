import Foundation

enum AppearanceMode: String, CaseIterable, Codable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum AccentTint: String, CaseIterable, Codable, Identifiable {
    case blue, teal, green, orange, pink, purple, graphite

    var id: String { rawValue }
    var title: String {
        switch self {
        case .blue: return "蓝色"
        case .teal: return "青绿色"
        case .green: return "绿色"
        case .orange: return "橙色"
        case .pink: return "粉色"
        case .purple: return "紫色"
        case .graphite: return "石墨灰"
        }
    }
}

enum GameOwnership: String, CaseIterable, Codable, Identifiable {
    case managed, external

    var id: String { rawValue }
    var title: String {
        switch self {
        case .managed: return "启动器管理"
        case .external: return "外部游戏"
        }
    }
    var icon: String {
        switch self {
        case .managed: return "internaldrive"
        case .external: return "folder"
        }
    }
}

enum GameInstallState: Equatable {
    case missing
    case incomplete(reason: String)
    case ready(version: String)
}

enum DalamudVariant: String, CaseIterable, Codable, Identifiable {
    case china
    case soil
    case disabled

    var id: String { rawValue }
    var title: String {
        switch self {
        case .china: return "Dalamud 国服"
        case .soil: return "Dalamud Soil（土月）"
        case .disabled: return "不启用 Dalamud"
        }
    }
    var description: String {
        switch self {
        case .china: return "正常国服 Dalamud，使用 ottercorp 国服发行协议。"
        case .soil: return "国服魔改 Dalamud，参考 AtmoOmen Soil 并适配 macOS。"
        case .disabled: return "启动 FFXIV 时不加载 Dalamud，也不访问任何 Dalamud 更新源。"
        }
    }
}

struct CNDownloadProgress: Equatable {
    let phase: String
    let currentFile: String
    let completedBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double
    let completedFiles: Int
    let totalFiles: Int

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

enum CNLoginMethod: String, CaseIterable, Codable, Identifiable {
    case slide, qrCode, password, quickLogin
    case weGame

    // Quick login is only a real option after CAS issued a reusable secret.
    // Keeping that rule in the model prevents the UI from exposing a control
    // that cannot work for the selected account.
    static func userVisibleCases(hasSavedQuickLogin: Bool) -> [CNLoginMethod] {
        hasSavedQuickLogin
            ? [.quickLogin, .slide, .qrCode, .password, .weGame]
            : [.slide, .qrCode, .password, .weGame]
    }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .slide: return "一键登录"
        case .qrCode: return "扫码登录"
        case .password: return "账号密码"
        case .quickLogin: return "快速续登"
        case .weGame: return "WG登录"
        }
    }
}

/// The launcher's single source of truth for CN authentication. Persisted
/// account names and Keychain entries are only candidates until the server
/// has accepted the stored TGT and issued a fresh game ticket.
enum CNAuthState: Equatable {
    case unknown
    case restoring(account: String)
    case loggedOut
    case authenticating(candidate: String)
    case switching(activeAccount: String, candidate: String)
    case authenticated(account: String)
    case expired(account: String?)
    case failed(message: String)

    var authenticatedAccount: String? {
        switch self {
        case .authenticated(let account), .switching(let account, _):
            return account
        default:
            return nil
        }
    }

    var isAuthenticated: Bool { authenticatedAccount != nil }

    func startingAuthentication(candidate: String) -> CNAuthState {
        if let active = authenticatedAccount {
            return .switching(activeAccount: active, candidate: candidate)
        }
        return .authenticating(candidate: candidate)
    }

    func afterFailedAuthentication(message: String) -> CNAuthState {
        if let active = authenticatedAccount {
            return .authenticated(account: active)
        }
        return .failed(message: message)
    }

    func afterCancelledAuthentication() -> CNAuthState {
        if let active = authenticatedAccount {
            return .authenticated(account: active)
        }
        return .loggedOut
    }
}

enum CNLoginInputField: Hashable {
    case account
    case password
}

enum CNLoginInputIssue: Equatable {
    case accountAndPassword
    case account
    case password

    var message: String {
        switch self {
        case .accountAndPassword: return "请输入账号和密码。"
        case .account: return "请输入账号。"
        case .password: return "请输入密码。"
        }
    }

    var focusedField: CNLoginInputField {
        switch self {
        case .accountAndPassword, .account: return .account
        case .password: return .password
        }
    }

    func applies(to field: CNLoginInputField) -> Bool {
        switch self {
        case .accountAndPassword: return true
        case .account: return field == .account
        case .password: return field == .password
        }
    }
}

enum CNLoginInputValidator {
    static func issue(method: CNLoginMethod, account: String, password: String) -> CNLoginInputIssue? {
        let accountIsEmpty = account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch method {
        case .password:
            if accountIsEmpty && password.isEmpty { return .accountAndPassword }
            if accountIsEmpty { return .account }
            if password.isEmpty { return .password }
            return nil
        case .slide:
            return accountIsEmpty ? .account : nil
        case .qrCode, .quickLogin:
            return nil
        case .weGame:
            if accountIsEmpty { return .account }
            return nil
        }
    }
}

struct LauncherSettings: Codable, Equatable {
    var gamePath: String = ""
    var externalGamePath: String = ""
    var gameOwnership: GameOwnership = .external
    var appearance: AppearanceMode = .auto
    var accentTint: AccentTint = .blue
    /// New installs show the real setup assistant once. Existing settings
    /// files decode a missing value as complete so an update cannot interrupt
    /// an already configured launcher.
    var firstLaunchCompleted = false
    var firstLaunchStep = 0
    var selectedLoginMethod: CNLoginMethod = .slide
    var quickLoginEnabled = true
    var autoLogin = false
    var autoLaunch = false
    var dalamudVariant: DalamudVariant = .disabled
    var dalamudEnabled: Bool {
        get { dalamudVariant != .disabled }
        set { dalamudVariant = newValue ? (dalamudVariant == .disabled ? .soil : dalamudVariant) : .disabled }
    }
    var dcTravelEnabled = false
    var metalHUDEnabled = false
    // MetalFX defaults to a 1:1 input/output factor. XOM mode is the only
    // alternate mode and uses XOM 5.4.2's original 2x factor.
    var superResolutionEnabled = true
    var xomMetalFxModeEnabled = false
    // Matches XOM's implementation: disabling logical macOS scaling enables
    // Wine RetinaMode and gives the game the physical Retina resolution.
    // This product exposes the positive "High Resolution" meaning, so new
    // installs default to the high-resolution path.
    var macOSScalingEnabled = false
    var msyncEnabled = true
    var wineDebug = "-all"
    var maxFrameRate = 0
    var dalamudInjectionDelay = 0.0
    var leftOptionIsAlt = true
    var rightOptionIsAlt = true
    var leftCommandIsControl = true
    var rightCommandIsControl = true
    var autoCloseLauncher = true
    var minimizeAfterLaunch = true
    var noThirdPartyPlugins = false
    var region = "CN"
    // The selected CN area/session is populated by the CN login workflow. Empty
    // values deliberately prevent us from fabricating a server host.
    var cnAreaID = ""
    var cnLobbyHost = ""
    var cnGMHost = ""
    var cnSaveDataBankHost = ""
    var cnAreasInfo = ""
    var cnSessionID = ""
    var cnSndaID = ""
    var cnDCTravelerPort = 0
    var cnAccount = ""
    var cnTGT = ""
    var cnGUID = ""

    var retinaEnabled: Bool { !macOSScalingEnabled }

    /// A session is considered logged in only when all values required by the
    /// CN game launcher are present. Account text or a saved password alone is
    /// not authentication and must not make the UI claim that it is logged in.
    var hasCompleteCNLaunchFields: Bool {
        !cnSessionID.isEmpty && !cnSndaID.isEmpty && !cnAreaID.isEmpty &&
        !cnLobbyHost.isEmpty && !cnGMHost.isEmpty && !cnSaveDataBankHost.isEmpty
    }

    var metalFxSpatialFactor: Double { xomMetalFxModeEnabled ? 2.0 : 1.0 }

    mutating func reconcileGameInstallPaths(managedPath: String) {
        if gameOwnership == .external {
            if externalGamePath.isEmpty { externalGamePath = gamePath }
            gamePath = externalGamePath
        } else {
            gamePath = managedPath
        }
    }

    mutating func selectGameInstall(_ ownership: GameOwnership, managedPath: String) {
        gameOwnership = ownership
        gamePath = ownership == .managed ? managedPath : externalGamePath
    }

    mutating func setExternalGamePath(_ path: String, select: Bool, managedPath: String) {
        externalGamePath = path
        if select { gameOwnership = .external }
        gamePath = gameOwnership == .managed ? managedPath : externalGamePath
    }

    /// Resolves the only game directory an operation may inspect or modify.
    /// Keeping this derived from ownership prevents a stale compatibility
    /// `gamePath` value from updating the inactive Managed/External install.
    func activeGamePath(managedPath: String) -> String {
        gameOwnership == .managed ? managedPath : externalGamePath
    }

    enum CodingKeys: String, CodingKey {
        case gamePath, externalGamePath, gameOwnership, appearance, accentTint, firstLaunchCompleted, firstLaunchStep, selectedLoginMethod, quickLoginEnabled, autoLogin, autoLaunch
        case dalamudVariant, dcTravelEnabled, metalHUDEnabled, superResolutionEnabled, xomMetalFxModeEnabled
        case macOSScalingEnabled, msyncEnabled, wineDebug
        case maxFrameRate, dalamudInjectionDelay
        case leftOptionIsAlt, rightOptionIsAlt
        case leftCommandIsControl, rightCommandIsControl, autoCloseLauncher, minimizeAfterLaunch
        case noThirdPartyPlugins, region, cnAreaID, cnLobbyHost, cnGMHost
        case cnSaveDataBankHost, cnAreasInfo, cnSessionID, cnSndaID, cnDCTravelerPort
        case cnAccount, cnTGT, cnGUID
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case dxmtEnabled, highPriority, dalamudEnabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        gamePath = try c.decodeIfPresent(String.self, forKey: .gamePath) ?? ""
        gameOwnership = try c.decodeIfPresent(GameOwnership.self, forKey: .gameOwnership) ?? .external
        externalGamePath = try c.decodeIfPresent(String.self, forKey: .externalGamePath)
            ?? (gameOwnership == .external ? gamePath : "")
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .auto
        accentTint = try c.decodeIfPresent(AccentTint.self, forKey: .accentTint) ?? .blue
        firstLaunchCompleted = try c.decodeIfPresent(Bool.self, forKey: .firstLaunchCompleted) ?? true
        firstLaunchStep = max(0, try c.decodeIfPresent(Int.self, forKey: .firstLaunchStep) ?? 0)
        selectedLoginMethod = try c.decodeIfPresent(CNLoginMethod.self, forKey: .selectedLoginMethod) ?? .slide
        quickLoginEnabled = try c.decodeIfPresent(Bool.self, forKey: .quickLoginEnabled) ?? true
        autoLogin = try c.decodeIfPresent(Bool.self, forKey: .autoLogin) ?? false
        autoLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoLaunch) ?? false
        if let variant = try c.decodeIfPresent(DalamudVariant.self, forKey: .dalamudVariant) {
            dalamudVariant = variant
        } else if let enabled = try legacy.decodeIfPresent(Bool.self, forKey: .dalamudEnabled) {
            dalamudVariant = enabled ? .soil : .disabled
        } else {
            dalamudVariant = .disabled
        }
        dcTravelEnabled = try c.decodeIfPresent(Bool.self, forKey: .dcTravelEnabled) ?? false
        // Decode and discard the legacy DXMT selector. This product is
        // intentionally DXMT-only and never exposes a non-functional choice.
        _ = try legacy.decodeIfPresent(Bool.self, forKey: .dxmtEnabled)
        metalHUDEnabled = try c.decodeIfPresent(Bool.self, forKey: .metalHUDEnabled) ?? false
        superResolutionEnabled = try c.decodeIfPresent(Bool.self, forKey: .superResolutionEnabled) ?? true
        xomMetalFxModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .xomMetalFxModeEnabled) ?? false
        macOSScalingEnabled = try c.decodeIfPresent(Bool.self, forKey: .macOSScalingEnabled) ?? false
        // MSync defaults to the validated XOM baseline but remains an explicit
        // user setting. Older files without the key keep the enabled default.
        msyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .msyncEnabled) ?? true
        wineDebug = try c.decodeIfPresent(String.self, forKey: .wineDebug) ?? "-all"
        maxFrameRate = try c.decodeIfPresent(Int.self, forKey: .maxFrameRate) ?? 0
        dalamudInjectionDelay = try c.decodeIfPresent(Double.self, forKey: .dalamudInjectionDelay) ?? 0
        leftOptionIsAlt = try c.decodeIfPresent(Bool.self, forKey: .leftOptionIsAlt) ?? true
        rightOptionIsAlt = try c.decodeIfPresent(Bool.self, forKey: .rightOptionIsAlt) ?? true
        leftCommandIsControl = try c.decodeIfPresent(Bool.self, forKey: .leftCommandIsControl) ?? true
        rightCommandIsControl = try c.decodeIfPresent(Bool.self, forKey: .rightCommandIsControl) ?? true
        autoCloseLauncher = try c.decodeIfPresent(Bool.self, forKey: .autoCloseLauncher) ?? true
        minimizeAfterLaunch = try c.decodeIfPresent(Bool.self, forKey: .minimizeAfterLaunch) ?? true
        // Decode and discard the legacy priority switch. An unprivileged app
        // cannot reliably raise another process above the user's normal
        // scheduling priority, so retaining it would be a fake control.
        _ = try legacy.decodeIfPresent(Bool.self, forKey: .highPriority)
        noThirdPartyPlugins = try c.decodeIfPresent(Bool.self, forKey: .noThirdPartyPlugins) ?? false
        region = "CN"
        cnAreaID = try c.decodeIfPresent(String.self, forKey: .cnAreaID) ?? ""
        cnLobbyHost = try c.decodeIfPresent(String.self, forKey: .cnLobbyHost) ?? ""
        cnGMHost = try c.decodeIfPresent(String.self, forKey: .cnGMHost) ?? ""
        cnSaveDataBankHost = try c.decodeIfPresent(String.self, forKey: .cnSaveDataBankHost) ?? ""
        cnAreasInfo = try c.decodeIfPresent(String.self, forKey: .cnAreasInfo) ?? ""
        cnSessionID = try c.decodeIfPresent(String.self, forKey: .cnSessionID) ?? ""
        cnSndaID = try c.decodeIfPresent(String.self, forKey: .cnSndaID) ?? ""
        // The loopback RPC port is allocated per process and must never be
        // reused from a previous Launcher session.
        cnDCTravelerPort = 0
        cnAccount = try c.decodeIfPresent(String.self, forKey: .cnAccount) ?? ""
        cnTGT = try c.decodeIfPresent(String.self, forKey: .cnTGT) ?? ""
        cnGUID = try c.decodeIfPresent(String.self, forKey: .cnGUID) ?? ""
    }
}

struct ManagedPaths {
    let applicationSupport: URL
    let caches: URL
    let logs: URL
    let winePrefix: URL
    let dalamud: URL
    let config: URL

    /// Tools shipped by the app are copied here once and are never mixed with
    /// the game directory. This keeps the game independently installable and
    /// makes runtime/Dalamud replacement atomic.
    var sevenZip: URL { applicationSupport.appendingPathComponent("tools/7zz") }
    var dalamudChina: URL { dalamud.appendingPathComponent("china", isDirectory: true) }
    var dalamudSoil: URL { dalamud.appendingPathComponent("soil", isDirectory: true) }
    func dalamudRoot(for variant: DalamudVariant) -> URL {
        variant == .china ? dalamudChina : dalamudSoil
    }
    func dalamudAssets(for variant: DalamudVariant) -> URL {
        dalamudRoot(for: variant).appendingPathComponent("assets", isDirectory: true)
    }
    func dalamudRuntime(for variant: DalamudVariant) -> URL {
        dalamudRoot(for: variant).appendingPathComponent("runtime", isDirectory: true)
    }
    func dalamudConfigDirectory(for variant: DalamudVariant) -> URL {
        dalamudRoot(for: variant).appendingPathComponent("config", isDirectory: true)
    }
    func dalamudConfigFile(for variant: DalamudVariant) -> URL {
        dalamudConfigDirectory(for: variant).appendingPathComponent("dalamudConfig.json")
    }
    func dalamudPluginDirectory(for variant: DalamudVariant) -> URL {
        dalamudRoot(for: variant).appendingPathComponent("installedPlugins", isDirectory: true)
    }
    func dalamudLogDirectory(for variant: DalamudVariant) -> URL {
        logs.appendingPathComponent("Dalamud/\(variant.rawValue)", isDirectory: true)
    }
    // Compatibility aliases for code and data created before variant support.
    var dalamudAssets: URL { dalamudAssets(for: .soil) }
    var dalamudPluginDirectory: URL { dalamudPluginDirectory(for: .soil) }
    var dalamudConfigFile: URL { dalamudConfigFile(for: .soil) }
    var dalamudRuntime: URL { dalamudRuntime(for: .soil) }
    var managedGame: URL { applicationSupport.appendingPathComponent("game", isDirectory: true) }
    var gameConfig: URL { applicationSupport.appendingPathComponent("gameConfig", isDirectory: true) }
    /// Wine and DXMT exist only inside the signed App bundle. There is no
    /// Application Support fallback and no second installable runtime tree.
    private var bundledXOMResourceRoot: URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let wineURL = resourceURL.appendingPathComponent("wine", isDirectory: true)
        let dxmtURL = resourceURL.appendingPathComponent("dxmt", isDirectory: true)
        guard FileManager.default.fileExists(atPath: wineURL.appendingPathComponent("bin/wine").path),
              FileManager.default.fileExists(atPath: dxmtURL.appendingPathComponent("d3d11.dll").path),
              FileManager.default.fileExists(atPath: dxmtURL.appendingPathComponent("dxgi.dll").path) else {
            return nil
        }
        return resourceURL
    }

    var usesBundledXOMRuntime: Bool { bundledXOMResourceRoot != nil }
    var wineRuntime: URL {
        (Bundle.main.resourceURL ?? URL(fileURLWithPath: "/nonexistent"))
            .appendingPathComponent("wine", isDirectory: true)
    }
    var dxmt: URL {
        (Bundle.main.resourceURL ?? URL(fileURLWithPath: "/nonexistent"))
            .appendingPathComponent("dxmt", isDirectory: true)
    }
    var dxmtD3D11: URL { dxmt.appendingPathComponent("d3d11.dll") }
    var dxmtDXGI: URL { dxmt.appendingPathComponent("dxgi.dll") }

    init(fileManager: FileManager = .default) {
        #if DEBUG
        let debugRoot = ProcessInfo.processInfo.environment["XIVCN_DEBUG_DATA_ROOT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        let debugRoot: URL? = nil
        #endif
        let appSupport: URL
        let cache: URL
        let logs: URL
        if let debugRoot {
            appSupport = debugRoot.appendingPathComponent("Application Support", isDirectory: true)
            cache = debugRoot.appendingPathComponent("Caches", isDirectory: true)
            logs = debugRoot.appendingPathComponent("Logs", isDirectory: true)
        } else {
            appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("XIVCN Mac Launcher", isDirectory: true)
            cache = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("XIVCN Mac Launcher", isDirectory: true)
            logs = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/XIVCN Mac Launcher", isDirectory: true)
        }
        applicationSupport = appSupport
        caches = cache
        self.logs = logs
        winePrefix = appSupport.appendingPathComponent("wineprefix", isDirectory: true)
        dalamud = appSupport.appendingPathComponent("dalamud", isDirectory: true)
        config = appSupport.appendingPathComponent("config", isDirectory: true)
        Self.migrateLegacyDalamudLayout(at: dalamud, fileManager: fileManager)
        Self.migrateLegacyDalamudUserData(config: config, soilRoot: dalamudSoil, fileManager: fileManager)
    }

    init(applicationSupport: URL, caches: URL, logs: URL) {
        self.applicationSupport = applicationSupport
        self.caches = caches
        self.logs = logs
        winePrefix = applicationSupport.appendingPathComponent("wineprefix", isDirectory: true)
        dalamud = applicationSupport.appendingPathComponent("dalamud", isDirectory: true)
        config = applicationSupport.appendingPathComponent("config", isDirectory: true)
        Self.migrateLegacyDalamudLayout(at: dalamud, fileManager: .default)
        Self.migrateLegacyDalamudUserData(config: config, soilRoot: dalamudSoil, fileManager: .default)
    }

    /// Before the two-variant layout was introduced, Soil lived directly in
    /// `dalamud/Hooks`, `dalamud/assets`, and `dalamud/runtime`. Move only
    /// those known core entries into the Soil namespace; China remains a
    /// separate, empty root until the user selects it.
    private static func migrateLegacyDalamudLayout(at root: URL, fileManager: FileManager) {
        let soil = root.appendingPathComponent("soil", isDirectory: true)
        let china = root.appendingPathComponent("china", isDirectory: true)
        guard !fileManager.fileExists(atPath: china.path) ||
              !fileManager.fileExists(atPath: china.appendingPathComponent("ACTIVE").path) else { return }
        let legacyNames = ["Hooks", "assets", "runtime", "ACTIVE", "downloads", "staging-26-08-09-01",
                           "runtime.version", "runtime-staging-10.0.1"]
        guard legacyNames.contains(where: { fileManager.fileExists(atPath: root.appendingPathComponent($0).path) }) else { return }
        try? fileManager.createDirectory(at: soil, withIntermediateDirectories: true)
        for name in legacyNames {
            let source = root.appendingPathComponent(name)
            let destination = soil.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.moveItem(at: source, to: destination)
        }
    }

    /// Versions before variant selection stored Soil's user state beside the
    /// launcher's own settings. Preserve it once, then keep future variants
    /// isolated so switching cannot overwrite repositories or plugins.
    private static func migrateLegacyDalamudUserData(config: URL, soilRoot: URL,
                                                     fileManager: FileManager) {
        let legacyConfig = config.appendingPathComponent("dalamudConfig.json")
        let legacyPlugins = config.appendingPathComponent("installedPlugins", isDirectory: true)
        let targetConfigDirectory = soilRoot.appendingPathComponent("config", isDirectory: true)
        let targetConfig = targetConfigDirectory.appendingPathComponent("dalamudConfig.json")
        let targetPlugins = soilRoot.appendingPathComponent("installedPlugins", isDirectory: true)
        if fileManager.fileExists(atPath: legacyConfig.path),
           !fileManager.fileExists(atPath: targetConfig.path) {
            try? fileManager.createDirectory(at: targetConfigDirectory, withIntermediateDirectories: true)
            try? fileManager.moveItem(at: legacyConfig, to: targetConfig)
        }
        if fileManager.fileExists(atPath: legacyPlugins.path),
           !fileManager.fileExists(atPath: targetPlugins.path) {
            try? fileManager.createDirectory(at: soilRoot, withIntermediateDirectories: true)
            try? fileManager.moveItem(at: legacyPlugins, to: targetPlugins)
        }
    }

    func createDirectories(fileManager: FileManager = .default) throws {
        let paths = [applicationSupport, caches, logs, winePrefix,
                     dalamud, dalamudChina,
                     dalamudSoil, config, sevenZip.deletingLastPathComponent(),
                     dalamudAssets(for: .china), dalamudAssets(for: .soil),
                     dalamudConfigDirectory(for: .china), dalamudConfigDirectory(for: .soil),
                     dalamudPluginDirectory(for: .china), dalamudPluginDirectory(for: .soil),
                     dalamudRuntime(for: .china), dalamudRuntime(for: .soil), gameConfig]
        for path in paths {
            try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        }
    }
}

struct RegionEndpoints: Codable, Equatable {
    // These are CN-only values copied from the CN Windows launcher constants.
    // They are not interchangeable with the Square Enix/XIV on Mac endpoints.
    var loginAreaURL = CNRegionProfile.loginAreaURL
    var loginAreaPort = CNRegionProfile.loginAreaPort
    var loginRefererURL = CNRegionProfile.loginRefererURL
    var casPrimaryDomain = CNRegionProfile.casPrimaryDomain
    var casFallbackDomain = CNRegionProfile.casFallbackDomain
    var casPort = CNRegionProfile.casPort
    var serviceURL = CNRegionProfile.serviceURL
    var servicePort = CNRegionProfile.servicePort
    var launcherAppID = CNRegionProfile.launcherAppID
    var gameAppID = CNRegionProfile.gameAppID
    var branchID = CNRegionProfile.branchID
    var contentConfigURL = CNRegionProfile.contentConfigURL
    var dalamudDistributionURL = CNRegionProfile.dalamudDistributionURL
    var dalamudVersionURL = CNRegionProfile.dalamudVersionURL
    var dalamudAssetDistributionURL = CNRegionProfile.dalamudAssetDistributionURL
    var dalamudAssetVersionURL = CNRegionProfile.dalamudAssetVersionURL
    var dalamudRuntimeInfoURL = CNRegionProfile.dalamudRuntimeInfoURL
    var dalamudPluginRepositoryURL = CNRegionProfile.dalamudPluginRepositoryURL
    var lobbyPort = CNRegionProfile.lobbyPort

    enum CodingKeys: String, CodingKey {
        case loginAreaURL, loginAreaPort, loginRefererURL, casPrimaryDomain, casFallbackDomain, casPort
        case serviceURL, servicePort, launcherAppID, gameAppID, branchID, contentConfigURL
        case dalamudDistributionURL, dalamudVersionURL, dalamudAssetDistributionURL, dalamudAssetVersionURL,
             dalamudRuntimeInfoURL, dalamudPluginRepositoryURL, lobbyPort
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        loginAreaURL = try values.decodeIfPresent(String.self, forKey: .loginAreaURL) ?? CNRegionProfile.loginAreaURL
        loginAreaPort = try values.decodeIfPresent(Int.self, forKey: .loginAreaPort) ?? CNRegionProfile.loginAreaPort
        loginRefererURL = try values.decodeIfPresent(String.self, forKey: .loginRefererURL) ?? CNRegionProfile.loginRefererURL
        casPrimaryDomain = try values.decodeIfPresent(String.self, forKey: .casPrimaryDomain) ?? CNRegionProfile.casPrimaryDomain
        casFallbackDomain = try values.decodeIfPresent(String.self, forKey: .casFallbackDomain) ?? CNRegionProfile.casFallbackDomain
        casPort = try values.decodeIfPresent(Int.self, forKey: .casPort) ?? CNRegionProfile.casPort
        serviceURL = try values.decodeIfPresent(String.self, forKey: .serviceURL) ?? CNRegionProfile.serviceURL
        servicePort = try values.decodeIfPresent(Int.self, forKey: .servicePort) ?? CNRegionProfile.servicePort
        launcherAppID = try values.decodeIfPresent(String.self, forKey: .launcherAppID) ?? CNRegionProfile.launcherAppID
        gameAppID = try values.decodeIfPresent(String.self, forKey: .gameAppID) ?? CNRegionProfile.gameAppID
        branchID = try values.decodeIfPresent(String.self, forKey: .branchID) ?? CNRegionProfile.branchID
        contentConfigURL = try values.decodeIfPresent(String.self, forKey: .contentConfigURL) ?? CNRegionProfile.contentConfigURL
        dalamudDistributionURL = try values.decodeIfPresent(String.self, forKey: .dalamudDistributionURL) ?? CNRegionProfile.dalamudDistributionURL
        dalamudVersionURL = try values.decodeIfPresent(String.self, forKey: .dalamudVersionURL) ?? CNRegionProfile.dalamudVersionURL
        dalamudAssetDistributionURL = try values.decodeIfPresent(String.self, forKey: .dalamudAssetDistributionURL) ?? CNRegionProfile.dalamudAssetDistributionURL
        dalamudAssetVersionURL = try values.decodeIfPresent(String.self, forKey: .dalamudAssetVersionURL) ?? CNRegionProfile.dalamudAssetVersionURL
        dalamudRuntimeInfoURL = try values.decodeIfPresent(String.self, forKey: .dalamudRuntimeInfoURL) ?? CNRegionProfile.dalamudRuntimeInfoURL
        dalamudPluginRepositoryURL = try values.decodeIfPresent(String.self, forKey: .dalamudPluginRepositoryURL) ?? CNRegionProfile.dalamudPluginRepositoryURL
        lobbyPort = try values.decodeIfPresent(Int.self, forKey: .lobbyPort) ?? CNRegionProfile.lobbyPort
    }

    func validated() throws -> RegionEndpoints {
        guard loginAreaURL == CNRegionProfile.loginAreaURL, loginAreaPort == CNRegionProfile.loginAreaPort,
              loginRefererURL == CNRegionProfile.loginRefererURL, casPort == CNRegionProfile.casPort,
              casPrimaryDomain == CNRegionProfile.casPrimaryDomain,
              casFallbackDomain == CNRegionProfile.casFallbackDomain,
              serviceURL == CNRegionProfile.serviceURL, servicePort == CNRegionProfile.servicePort,
              launcherAppID == CNRegionProfile.launcherAppID, gameAppID == CNRegionProfile.gameAppID,
              branchID == CNRegionProfile.branchID, contentConfigURL == CNRegionProfile.contentConfigURL,
              dalamudDistributionURL == CNRegionProfile.dalamudDistributionURL,
              dalamudVersionURL == CNRegionProfile.dalamudVersionURL,
              dalamudAssetDistributionURL == CNRegionProfile.dalamudAssetDistributionURL,
              dalamudAssetVersionURL == CNRegionProfile.dalamudAssetVersionURL,
              dalamudRuntimeInfoURL == CNRegionProfile.dalamudRuntimeInfoURL,
              dalamudPluginRepositoryURL == CNRegionProfile.dalamudPluginRepositoryURL,
              lobbyPort == CNRegionProfile.lobbyPort,
              CNRegionProfile.isCNURL(loginAreaURL), CNRegionProfile.isCNURL(loginRefererURL),
              CNRegionProfile.isCNURL("https://\(casPrimaryDomain)"), CNRegionProfile.isCNURL(serviceURL),
              CNRegionProfile.isCNURL(contentConfigURL),
              CNRegionProfile.isCNURL(dalamudDistributionURL),
              CNRegionProfile.isCNURL(dalamudAssetDistributionURL),
              CNRegionProfile.isCNURL(dalamudAssetVersionURL),
              CNRegionProfile.isCNURL(dalamudRuntimeInfoURL),
              CNRegionProfile.isCNURL(dalamudPluginRepositoryURL) else {
            throw RegionConfigurationError.foreignOrInvalidEndpoint
        }
        return self
    }
}

enum RegionConfigurationError: LocalizedError {
    case foreignOrInvalidEndpoint

    var errorDescription: String? {
        "国服配置包含无效或国际服端点，已拒绝启动。请删除 region-cn.json 后重新生成。"
    }
}

enum CNRegionProfile {
    static let loginAreaURL = "https://ff.dorado.sdo.com/ff/area/serverlist_new.js"
    static let loginAreaPort = 443
    static let loginRefererURL = "https://ff.web.sdo.com/project/launcher0904/index.html"
    static let casPrimaryDomain = "cas.sdo.com"
    static let casFallbackDomain = "n1.cas.sdo.com"
    static let casPort = 443
    static let serviceURL = "http://www.sdo.com"
    static let servicePort = 80
    static let launcherAppID = "791000814"
    static let gameAppID = "100001900"
    static let branchID = "8847"
    static let contentConfigURL = "https://v3launcher.jijiagames.com/v3launcher"
    static let dalamudDistributionURL = "https://dalamud-dis.atmoomen.top"
    static let dalamudVersionURL = "https://dalamud-dis.atmoomen.top/RELEASE"
    static let dalamudAssetDistributionURL = "https://dalamud-dis.atmoomen.top/assets"
    static let dalamudAssetVersionURL = "https://dalamud-dis.atmoomen.top/assets/RELEASE"
    // Atmo's CN build pins the .NET runtime feed to its own mirrored metadata.
    // It is deliberately not the international Dalamud runtime endpoint.
    static let dalamudRuntimeInfoURL = "https://gh.atmoomen.top/https://raw.githubusercontent.com/Dalamud-DailyRoutines/XLCNSoilAssets/master/runtimeInfo"
    // This is the actual MainRepoUrlSoil constant in the Atmo/DailyRoutines
    // Dalamud fork. It is a main repository, not an added third-party feed.
    static let dalamudPluginRepositoryURL = "https://gh.atmoomen.top/raw.githubusercontent.com/Dalamud-DailyRoutines/PluginDistD17/main/pluginmaster.json"
    // Normal CN launcher (ottercorp/FFXIVQuickLauncher) contracts. These are
    // deliberately separate from the Soil R2 feed above.
    static let normalCNDalamudBaseURL = "https://aonyx.ffxiv.wang"
    // The normal CN service treats the track value as case-sensitive. Its
    // production endpoint returns HTTP 400 for `Release`; the upstream
    // launcher sends the lower-case channel name.
    static let normalCNDalamudVersionURL = "https://aonyx.ffxiv.wang/Dalamud/Release/VersionInfo?track=release"
    static let normalCNDalamudAssetMetaURL = "https://aonyx.ffxiv.wang/Dalamud/Asset/Meta"
    static let normalCNDalamudPluginRepositoryURL = "https://aonyx.ffxiv.wang/Plugin/PluginMaster"
    // CN game launch uses a fixed lobby port. DC Travel is a separate local
    // listener and is supplied per session, so it must never be hard-coded here.
    static let lobbyPort = 54994
    static let dcTravelURL = "https://ff14bjz.sdo.com/RegionKanTelepo"

    static func isCNURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host?.lowercased(),
              (url.scheme == "https" || (url.scheme == "http" && host == "www.sdo.com")) else { return false }
        return host == "ff.dorado.sdo.com" || host == "ff.web.sdo.com" || host == "cas.sdo.com" ||
            host == "n1.cas.sdo.com" || host == "www.sdo.com" || host == "v3launcher.jijiagames.com" ||
            host == "ff14.jijiagames.com" ||
            host == "xl-dis.atmoomen.top" || host == "dalamud-dis.atmoomen.top" ||
            host == "gh.atmoomen.top" || host == "raw.githubusercontent.com" ||
            host == "aonyx.ffxiv.wang" || host == "s3.ffxiv.wang"
    }
}

struct CNLoginArea: Codable, Equatable, Identifiable {
    let id: String
    let status: Int
    let order: Int
    let name: String
    let type: Int
    let lobbyHost: String
    let gmHost: String
    let patchHost: String
    let configUploadHost: String

    init(id: String, status: Int, order: Int, name: String, type: Int, lobbyHost: String,
         gmHost: String, patchHost: String, configUploadHost: String) {
        self.id = id; self.status = status; self.order = order; self.name = name; self.type = type
        self.lobbyHost = lobbyHost; self.gmHost = gmHost; self.patchHost = patchHost
        self.configUploadHost = configUploadHost
    }

    enum CodingKeys: String, CodingKey {
        case id = "Areaid"
        case status = "AreaStat"
        case order = "AreaOrder"
        case name = "AreaName"
        case type = "Areatype"
        case lobbyHost = "AreaLobby"
        case gmHost = "AreaGm"
        case patchHost = "AreaPatch"
        case configUploadHost = "AreaConfigUpload"
    }
}
