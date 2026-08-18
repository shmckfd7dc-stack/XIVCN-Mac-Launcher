import AppKit
import SwiftUI

private enum UpdateOperation {
    case launchPipeline, gameUpdate, gameRepair
    case dalamud(DalamudVariant)
    case dalamudRepair(DalamudVariant)
}

enum RuntimeResetPhase: Equatable {
    case running
    case succeeded(String)
    case failed(String)
}

@main
enum XIVLauncherCNMacMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    let store = SettingsStore()
    @Published private(set) var statusText = "正在初始化启动器…"
    @Published private(set) var isBusy = true
    @Published private(set) var isWinePrefixConfigurationReady = false
    @Published private(set) var availableAreas: [CNLoginArea] = []
    @Published private(set) var qrCodeData: Data?
    @Published private(set) var importedWeGameCredentials: CNWeGameCredentials?
    @Published private(set) var loginMethodStatus = ""
    @Published private(set) var loginVerificationCode: String?
    @Published private(set) var updateStatusText = "尚未检查更新"
    @Published private(set) var updateTitle = "准备 FFXIV"
    @Published private(set) var gameState: GameInstallState = .missing
    @Published private(set) var updateProgress: CNDownloadProgress?
    @Published private(set) var updateError: String?
    @Published private(set) var updateCompletionMessage: String?
    @Published private(set) var isFirstLaunchDalamudPreparing = false
    @Published private(set) var firstLaunchDalamudError: String?
    @Published private(set) var managedGameDownloadProgress: CNDownloadProgress?
    @Published private(set) var managedGameDownloadError: String?
    @Published private(set) var managedGameDownloadCompletionMessage: String?
    @Published private(set) var isManagedGameDownloadActive = false
    @Published private(set) var isManagedGameDownloadPaused = false
    @Published var showsManagedGameDownloadPreparationNotice = false
    @Published var runtimeResetPhase: RuntimeResetPhase?
    @Published private(set) var newsItems: [CNNewsItem] = []
    @Published private(set) var newsState: CNNewsState = .idle
    @Published private(set) var isGameRunning = false
    @Published private(set) var isLoginInProgress = false
    @Published private(set) var authState: CNAuthState = .unknown
    @Published private(set) var isRefreshingAreas = false
    @Published private(set) var areaStatusText = "尚未获取国服大区列表"
    @Published private(set) var showsLaunchDetectionFailure = false
    @Published private(set) var showsLaunchDetectionCancel = false
    @Published private(set) var windowControlAlignmentRevision = 0
    /// SwiftUI's `preferredColorScheme(nil)` does not always invalidate an
    /// already-created hosting view after an app-level appearance override is
    /// removed. Keep the resolved system appearance published so switching
    /// from Light/Dark back to Auto immediately reflects the real macOS mode.
    @Published private(set) var resolvedColorScheme: ColorScheme = .light
    @Published var showsGameNotFound = false
    @Published var showsUpdateWindow = false
    @Published var showsFirstLaunchSetup = false

    private var window: NSWindow!
    private var gameProcess: Process?
    private var loginTask: Task<Void, Never>?
    private var loginOperationToken: UUID?
    private var updateTask: Task<Void, Never>?
    private var firstLaunchDalamudTask: Task<Void, Never>?
    private var updateOperationToken: UUID?
    private var managedGameDownloadTask: Task<Void, Never>?
    private var managedGameDownloadToken: UUID?
    private var gameHandoffDetectionToken: UUID?
    private var gameStateRefreshTask: Task<Void, Never>?
    private var newsTask: Task<Void, Never>?
    private var prefixConfigurationTask: Task<Void, Never>?
    private var prefixConfigurationDebounceTask: Task<Void, Never>?
    private var prefixConfigurationPending = false
    private var lastUpdateOperation: UpdateOperation?
    private let dcTravelRuntime = CNDCTravelRuntime()
    private var gameExitSource: DispatchSourceProcess?
    private var appearanceObserver: NSObjectProtocol?
    private var firstLaunchSettingsSnapshot: LauncherSettings?
    private var firstLaunchStartedAsInitial = false
    private var windowControlRealignmentScheduled = false
    private var suppressFinalSettingsSave = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        normalizeLoginMethodSelection()
        showsFirstLaunchSetup = !store.settings.firstLaunchCompleted
        if showsFirstLaunchSetup {
            firstLaunchSettingsSnapshot = store.settings
            firstLaunchStartedAsInitial = true
            store.beginFirstLaunchTransaction()
        }
        let root = LauncherRootView(app: self, store: store)
        let hosting = NSHostingView(rootView: root)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "XIVCN Mac Launcher"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 900, height: 620)
        window.setFrameAutosaveName("XIVCN Mac Launcher Main Window")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hosting
        appearanceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.store.settings.appearance == .auto else { return }
                self.updateResolvedColorScheme()
            }
        }
        applyAppearance(store.settings.appearance)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshNews()

        Task { @MainActor [self] in
            refreshGameState()
            let selectedVariant = store.settings.dalamudVariant
            if selectedVariant == .disabled {
                statusText = "启动环境已就绪 · 未启用 Dalamud"
            } else if let version = CNDalamudUpdater.activeVersion(in: store.paths.dalamudRoot(for: selectedVariant)) {
                let coreReady = CNDalamudUpdater.activeInstallationIsReady(
                    in: store.paths.dalamudRoot(for: selectedVariant)
                )
                let runtimeReady = CNWindowsRuntimeInstaller.installedVersion(
                    paths: store.paths, variant: selectedVariant
                ) != nil
                statusText = coreReady && runtimeReady
                    ? "启动环境 / \(selectedVariant.title) \(version) 已就绪"
                    : "启动环境已就绪 · \(selectedVariant.title) 需要在启动前修复"
            } else {
                statusText = "启动环境已就绪 · \(selectedVariant.title) 将在启动前安装"
            }
            isBusy = false
            if !showsFirstLaunchSetup {
                // Registry synchronization is best effort. A fresh Prefix
                // may initialize wineserver on the first command; never hold
                // the launch gate on this optional preference sync.
                synchronizeWinePrefixSettings()
            }
            let selectedPath = store.settings.activeGamePath(managedPath: store.paths.managedGame.path)
            Task { @MainActor [weak self] in
                let pid = await Task.detached(priority: .utility) { () -> Int32? in
                    return CoreBackend.gameUnixPID(gamePath: selectedPath)
                }.value
                if let pid { self?.monitorGameProcess(pid: pid) }
            }
            Task { @MainActor in await self.refreshAreas() }
            // Do not hold the startup busy gate on Keychain/network
            // session restoration. A slow or unavailable server must not
            // leave the launcher frozen after a previous failed launch.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let restoredAuthentication = await self.restoreStoredAuthentication()
                guard !restoredAuthentication else { return }
                if self.store.settings.autoLogin, !self.store.settings.cnAccount.isEmpty,
                   CNKeychain().loadSecret(account: self.store.settings.cnAccount) != nil {
                    self.login(method: .quickLogin, account: self.store.settings.cnAccount, password: "")
                } else if self.store.settings.selectedLoginMethod == .qrCode {
                    self.beginQRCodeLogin()
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func alignWindowControls(toWindowY targetY: CGFloat) {
        guard window != nil, !window.styleMask.contains(.fullScreen) else { return }
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttonTypes {
            guard let button = window.standardWindowButton(type), let container = button.superview else { continue }
            let targetInContainer = container.convert(NSPoint(x: 0, y: targetY), from: nil)
            var frame = button.frame
            frame.origin.y = targetInContainer.y - frame.height / 2
            button.setFrameOrigin(frame.origin)
        }
    }

    private func requestWindowControlRealignment() {
        guard window != nil, !window.styleMask.contains(.fullScreen),
              !windowControlRealignmentScheduled else { return }
        windowControlRealignmentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.windowControlRealignmentScheduled = false
            guard !self.window.styleMask.contains(.fullScreen) else { return }
            self.window.layoutIfNeeded()
            self.windowControlAlignmentRevision &+= 1
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        requestWindowControlRealignment()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        requestWindowControlRealignment()
    }

    func windowDidResize(_ notification: Notification) {
        guard !window.inLiveResize else { return }
        requestWindowControlRealignment()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        requestWindowControlRealignment()
    }

    /// Find the real FFXIV process in the macOS process table. The command line
    /// includes the selected game path, so another Wine prefix cannot make this
    /// installation appear to be running.
    private func currentGameUnixPID() -> Int32? {
        let selectedPath = store.settings.activeGamePath(managedPath: store.paths.managedGame.path)
        guard !selectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CoreBackend.gameUnixPID(gamePath: selectedPath)
    }

    @MainActor
    func applyAppearance(_ mode: AppearanceMode) {
        let appearance: NSAppearance?
        switch mode {
        case .auto: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        // Reset both overrides when returning to Auto. Relying only on
        // preferredColorScheme(nil) can leave an existing NSWindow in the
        // previously forced light appearance until it is recreated.
        NSApp.appearance = appearance
        window?.appearance = appearance
        window?.contentView?.appearance = appearance
        updateResolvedColorScheme(for: mode)
    }

    @MainActor
    private func updateResolvedColorScheme(for mode: AppearanceMode? = nil) {
        switch mode ?? store.settings.appearance {
        case .light:
            resolvedColorScheme = .light
        case .dark:
            resolvedColorScheme = .dark
        case .auto:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            resolvedColorScheme = match == .darkAqua ? .dark : .light
        }
    }

    @MainActor
    func normalizeLoginMethodSelection(account: String? = nil) {
        let quickAccounts = store.savedAccounts.filter(\.hasQuickLogin).map(\.account)
        if quickAccounts.isEmpty {
            store.settings.autoLogin = false
            if store.settings.selectedLoginMethod == .quickLogin {
                store.settings.selectedLoginMethod = .slide
            }
            return
        }
        guard store.settings.selectedLoginMethod == .quickLogin else { return }
        // The quick-account picker owns its candidate locally. Selecting a
        // candidate must never replace the currently authenticated account.
    }

    /// A Keychain session becomes active only after the CN CAS/game service
    /// accepts it and returns a fresh ticket. Failure removes only the stale
    /// session record; the separate quick-login secret remains intact.
    @MainActor
    private func restoreStoredAuthentication() async -> Bool {
        let account = store.settings.cnAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.settings.quickLoginEnabled, !account.isEmpty,
              let secure = CNKeychain().loadSession(account: account) else {
            authState = .loggedOut
            return false
        }
        guard !secure.tgt.isEmpty, !secure.guid.isEmpty, !secure.sndaID.isEmpty else {
            CNKeychain().deleteSession(account: account)
            store.refreshSavedAccounts()
            authState = .expired(account: account)
            loginMethodStatus = "已保存会话数据不完整，请重新登录。"
            return false
        }

        authState = .restoring(account: account)
        loginMethodStatus = "正在验证 \(account) 的已保存会话…"
        do {
            let service = try CNCoreLoginBackend(endpoints: store.endpoints)
            let ticket = try await service.refreshSession(tgt: secure.tgt, guid: secure.guid)
            guard !ticket.isEmpty else {
                throw CNLoginServiceError.server("国服服务器没有返回有效游戏 Session。")
            }
            store.activateRestoredSession(account: account, secure: secure, ticket: ticket)
            authState = .authenticated(account: account)
            loginMethodStatus = "已恢复并验证国服账号 \(account)，请手动点击“启动 FFXIV”。"
            return true
        } catch {
            _ = store.logoutCurrentSession()
            authState = .expired(account: account)
            loginMethodStatus = "已保存会话失效：\(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    private func expireCurrentAuthentication(reason: String) {
        let account = authState.authenticatedAccount ?? store.settings.cnAccount
        dcTravelRuntime.stop()
        _ = store.logoutCurrentSession()
        authState = .expired(account: account.isEmpty ? nil : account)
        loginMethodStatus = "登录会话已失效：\(reason)"
    }

    @MainActor
    func clearLogin() {
        loginTask?.cancel()
        loginOperationToken = nil
        isLoginInProgress = false
        dcTravelRuntime.stop()
        store.clearLogin()
        authState = .loggedOut
        qrCodeData = nil
        loginVerificationCode = nil
        importedWeGameCredentials = nil
        loginMethodStatus = ""
        normalizeLoginMethodSelection()
        statusText = "国服登录凭据已清除。"
    }

    /// Ends the current login without deleting the independently saved
    /// 30-day quick-login secret or any other account's Keychain entries.
    @MainActor
    func logout() {
        guard !isBusy, !isGameRunning else { return }
        loginTask?.cancel()
        loginOperationToken = nil
        isLoginInProgress = false
        dcTravelRuntime.stop()
        let account = store.logoutCurrentSession()
        authState = .loggedOut
        qrCodeData = nil
        loginVerificationCode = nil
        loginMethodStatus = account.map { "已退出 \($0)，已保存的快速续登凭据仍保留。" } ?? "已退出登录。"
        statusText = loginMethodStatus
        normalizeLoginMethodSelection()
    }

    @MainActor
    func setQuickLoginPersistence(_ enabled: Bool) {
        guard !isBusy, !isGameRunning else { return }
        store.settings.quickLoginEnabled = enabled
        if !enabled {
            store.settings.autoLogin = false
            if !store.settings.cnAccount.isEmpty {
                CNKeychain().deleteSecret(account: store.settings.cnAccount)
                CNKeychain().deleteSession(account: store.settings.cnAccount)
            }
            store.refreshSavedAccounts()
            normalizeLoginMethodSelection()
            statusText = "已关闭快速续登并删除当前账号的续登凭据。"
        }
    }

    @MainActor
    func deleteSavedAccount(_ account: String) {
        guard !account.isEmpty else { return }
        if store.settings.cnAccount == account {
            dcTravelRuntime.stop()
            store.clearLogin()
            authState = .loggedOut
            qrCodeData = nil
            loginMethodStatus = ""
            statusText = "已删除账号 \(account) 的保存信息。"
        } else {
            CNKeychain().deleteAccount(account: account)
            store.refreshSavedAccounts()
            statusText = "已删除账号 \(account) 的保存信息。"
        }
        normalizeLoginMethodSelection()
    }

    @MainActor
    func cleanUninstall() throws {
        guard !isBusy, !isGameRunning else { throw CleanUninstallError.launcherBusy }
        loginTask?.cancel()
        updateTask?.cancel()
        managedGameDownloadTask?.cancel()
        newsTask?.cancel()
        dcTravelRuntime.stop()
        // AppKit otherwise persists the current window frame again while the
        // app terminates, after CleanUninstallManager has removed our domain.
        window?.setFrameAutosaveName("")
        let report = try CleanUninstallManager().removeAll(paths: store.paths,
                                                           externalGamePath: store.settings.externalGamePath)
        guard report.isComplete else {
            throw CleanUninstallError.verificationFailed("完整卸载回读校验")
        }
        suppressFinalSettingsSave = true
        statusText = "账号、钥匙串、设置、缓存、日志、两套 Dalamud 及启动器管理的游戏已清除。"
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        loginTask?.cancel()
        updateTask?.cancel()
        firstLaunchDalamudTask?.cancel()
        managedGameDownloadTask?.cancel()
        newsTask?.cancel()
        prefixConfigurationDebounceTask?.cancel()
        prefixConfigurationTask?.cancel()
        gameExitSource?.cancel()
        dcTravelRuntime.stop()
        if !suppressFinalSettingsSave {
            store.flushSave()
        }
        if let appearanceObserver {
            DistributedNotificationCenter.default.removeObserver(appearanceObserver)
            self.appearanceObserver = nil
        }
    }

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "XIVCN Mac Launcher")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 XIVCN Mac Launcher", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 XIVCN Mac Launcher", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 XIVCN Mac Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        let launch = NSMenuItem(title: "启动 FFXIV", action: #selector(launchFromMenu), keyEquivalent: "\r")
        launch.target = self
        fileMenu.addItem(launch)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        viewItem.submenu = viewMenu
        let home = NSMenuItem(title: "主页", action: #selector(openHome), keyEquivalent: "1")
        home.target = self
        viewMenu.addItem(home)

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let fullScreen = NSMenuItem(title: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(fullScreen)
        windowMenu.addItem(withTitle: "前置所有窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openLauncherSettings, object: nil)
    }

    @objc private func openHome() {
        NotificationCenter.default.post(name: .openLauncherHome, object: nil)
    }

    @objc private func launchFromMenu() {
        launchGame()
    }

    @MainActor
    private func installBundledToolsIfNeeded() async throws {
        guard let bundled = Bundle.main.url(forResource: "7zz", withExtension: nil) else {
            throw CNDalamudUpdateError.missingExtractor
        }
        try store.paths.createDirectories()
        var shouldSetPermissions = false
        if !FileManager.default.fileExists(atPath: store.paths.sevenZip.path) {
            try FileManager.default.copyItem(at: bundled, to: store.paths.sevenZip)
            shouldSetPermissions = true
        } else {
            let attributes = try FileManager.default.attributesOfItem(atPath: store.paths.sevenZip.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            shouldSetPermissions = permissions & 0o777 != 0o755
        }
        if shouldSetPermissions {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.paths.sevenZip.path)
        }
    }

    @MainActor
    private func prepareDalamud(variantOverride: DalamudVariant? = nil,
                                operationToken: UUID? = nil,
                                fullIntegrity: Bool = false) async throws -> CNDalamudPreparedRelease? {
        let variant = variantOverride ?? store.settings.dalamudVariant
        guard variant != .disabled else { return nil }
        try Task.checkCancellation()
        try await installBundledToolsIfNeeded()
        let updater = try CNDalamudUpdater(endpoints: store.endpoints, variant: variant)
        let root = store.paths.dalamudRoot(for: variant)
        let progressHandler: (CNDownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self,
                      operationToken == nil || self.updateOperationToken == operationToken else { return }
                self.updateProgress = progress
                self.updateStatusText = progress.currentFile.isEmpty ? progress.phase : "\(progress.phase)：\(progress.currentFile)"
            }
        }
        let prepared = try await updater.prepareLocalOrRemote(in: root, sevenZip: store.paths.sevenZip,
                                                              progress: progressHandler,
                                                              verifyExisting: fullIntegrity)
        try Task.checkCancellation()
        if variant == store.settings.dalamudVariant {
            try CNDalamudUpdater.configurePluginRepository(
                at: store.paths.dalamudConfigFile(for: variant), variant: variant
            )
        }
        _ = try await updater.prepareAssets(in: root,
                                            sevenZip: store.paths.sevenZip,
                                            progress: progressHandler,
                                            verifyExisting: fullIntegrity)
        try Task.checkCancellation()
        return prepared
    }

    @MainActor
    private func beginUpdateOperation(_ operation: UpdateOperation) -> UUID {
        let token = UUID()
        updateOperationToken = token
        lastUpdateOperation = operation
        // Never carry progress from a previous operation into a new sheet.
        // In particular, a disabled-Dalamud launch must not display an old
        // Dalamud asset download as if it were making a new network request.
        updateProgress = nil
        updateError = nil
        updateCompletionMessage = nil
        switch operation {
        case .launchPipeline: updateTitle = "准备 FFXIV"
        case .gameUpdate: updateTitle = "更新国服游戏"
        case .gameRepair: updateTitle = "修复国服游戏"
        case .dalamud(let variant): updateTitle = "更新 \(variant.title)"
        case .dalamudRepair(let variant): updateTitle = "修复 \(variant.title)"
        }
        isBusy = true
        return token
    }

    @MainActor
    private func finishUpdateOperation(_ token: UUID) {
        guard updateOperationToken == token else { return }
        updateOperationToken = nil
        updateTask = nil
        isBusy = false
    }

    @MainActor
    private func isCurrentUpdateOperation(_ token: UUID) -> Bool {
        updateOperationToken == token
    }

    /// Launch uses the same sheet as downloads, but the work after the game
    /// version check is not a download. Keep the sheet's phase aligned with
    /// the actual launch pipeline instead of leaving it on the initial
    /// "checking game update" text while Wine/session preparation runs.
    @MainActor
    private func setLaunchProgress(_ phase: String) {
        updateProgress = CNDownloadProgress(phase: phase, currentFile: "",
                                            completedBytes: 0, totalBytes: 0,
                                            bytesPerSecond: 0, completedFiles: 0,
                                            totalFiles: 0)
        updateStatusText = phase
    }

    @MainActor
    private func finishLoginOperation(_ token: UUID) {
        guard loginOperationToken == token else { return }
        loginOperationToken = nil
        loginTask = nil
        isLoginInProgress = false
        isBusy = updateOperationToken != nil
    }

    @MainActor
    private func isCurrentLoginOperation(_ token: UUID) -> Bool {
        loginOperationToken == token
    }

    @MainActor
    private func validateDalamudInstallation(_ variant: DalamudVariant) throws {
        guard variant != .disabled else { return }
        let root = store.paths.dalamudRoot(for: variant)
        guard CNDalamudUpdater.activeInstallationIsHealthy(in: root) else {
            throw GameLaunchError.dalamudUnavailable(variant.title)
        }
        guard CNWindowsRuntimeInstaller.installedVersion(paths: store.paths, variant: variant) != nil else {
            throw GameLaunchError.dalamudRuntimeUnavailable(variant.title)
        }
    }

    @MainActor
    func launchGame() {
        guard !isBusy else { statusText = "启动器正在初始化，请稍候。"; return }
        guard isWinePrefixConfigurationReady else {
            statusText = "正在同步 Wine 图形/键盘设置，请稍候再启动。"
            synchronizeWinePrefixSettings()
            return
        }
        guard prefixConfigurationTask == nil, prefixConfigurationDebounceTask == nil else {
            statusText = "正在同步 Wine 图形/键盘设置，请稍候再启动。"
            return
        }
        if gameProcess?.isRunning == true {
            statusText = "已发送游戏启动命令，正在确认真实 FFXIV 进程。"
            return
        }
        guard authState.isAuthenticated else {
            statusText = "请先完成国服账号登录，再启动游戏。"
            loginMethodStatus = "当前没有经过国服服务器验证的有效登录会话。"
            return
        }
        if isGameRunning {
            statusText = "FFXIV 已在运行。"
            window?.deminiaturize(nil)
            return
        }
        refreshGameState()
        if store.settings.gameOwnership == .managed, isManagedGameDownloadActive {
            if isManagedGameDownloadPaused {
                resumeManagedGameDownload()
            } else {
                statusText = "启动器管理的游戏正在下载，请等待下载完成。"
            }
            return
        }
        switch gameState {
        case .missing:
            if store.settings.gameOwnership == .managed {
                downloadManagedGame(showPreparationNotice: false)
                return
            }
            showsGameNotFound = true
            statusText = "未检测到完整的国服游戏。"
            return
        case .incomplete:
            if store.settings.gameOwnership == .managed {
                downloadManagedGame(showPreparationNotice: false)
                return
            }
            showsGameNotFound = true
            statusText = "未检测到完整的国服游戏。"
            return
        case .ready:
            break
        }
        managedGameDownloadCompletionMessage = nil
        let operationToken = beginUpdateOperation(.launchPipeline)
        showsLaunchDetectionFailure = false
        showsLaunchDetectionCancel = false
        gameHandoffDetectionToken = nil
        let selectedDalamudVariant = store.settings.dalamudVariant
        updateProgress = CNDownloadProgress(phase: selectedDalamudVariant == .disabled
                                            ? "正在准备游戏启动"
                                            : "正在准备 \(selectedDalamudVariant.title)", currentFile: "",
                                            completedBytes: 0, totalBytes: 0, bytesPerSecond: 0,
                                            completedFiles: 0, totalFiles: 0)
        showsUpdateWindow = true
        statusText = "正在刷新国服游戏会话…"
        updateTask = Task { @MainActor [self] in
            var sessionRefreshInProgress = false
            do {
                try Task.checkCancellation()
                setLaunchProgress("正在检查国服游戏版本…")
                try await updateGameIfNeeded(operationToken: operationToken)
                try Task.checkCancellation()
                if selectedDalamudVariant != .disabled {
                    setLaunchProgress("正在检查 \(selectedDalamudVariant.title) 运行环境…")
                    let prepared = try await prepareDalamud(variantOverride: selectedDalamudVariant,
                                                            operationToken: operationToken)
                    if selectedDalamudVariant == .soil || prepared?.runtimeVersion != nil {
                        try await CNWindowsRuntimeInstaller(paths: store.paths)
                            .installRequiredRuntime(variant: selectedDalamudVariant,
                                                    requiredVersion: prepared?.runtimeVersion)
                    }
                    try validateDalamudInstallation(selectedDalamudVariant)
                }
                setLaunchProgress("正在准备 Core / Wine / DXMT 游戏环境…")
                guard !store.settings.cnTGT.isEmpty, !store.settings.cnGUID.isEmpty else {
                    throw CNLoginServiceError.server("当前国服会话缺少刷新凭据，请重新登录后再启动游戏。")
                }
                setLaunchProgress("正在刷新国服游戏会话…")
                let service = try CNCoreLoginBackend(endpoints: store.endpoints)
                sessionRefreshInProgress = true
                let ticket = try await service.refreshSession(tgt: store.settings.cnTGT,
                                                               guid: store.settings.cnGUID)
                guard !ticket.isEmpty else {
                    throw CNLoginServiceError.server("国服服务器没有返回有效游戏 Session。")
                }
                sessionRefreshInProgress = false
                store.updateGameSessionTicket(ticket)
                try await prepareDCTravelForLaunch()
                let launcher = CoreBackend(store: store)
                try Task.checkCancellation()
                setLaunchProgress("正在启动 FFXIV…")
                newsTask?.cancel()
                newsTask = nil
                let launched = try await launcher.launch()
                let process = launched.process
                gameProcess = process
                // Process creation is not launch success. Keep the operation
                // locked until the actual ffxiv_dx11.exe Unix process appears.
                updateOperationToken = nil
                updateTask = nil
                isBusy = true
                updateProgress = nil
                showsUpdateWindow = false
                showsLaunchDetectionCancel = true
                statusText = launched.usesDalamudInjector
                    ? "Dalamud 注入器已启动，正在确认真实 FFXIV 进程…"
                    : "Wine 启动命令已执行，正在确认真实 FFXIV 进程…"
                waitForGameHandoff(process: process,
                                   launchedPID: launched.gameWinePID,
                                   usesDalamudInjector: launched.usesDalamudInjector)
                return
            } catch {
                guard isCurrentUpdateOperation(operationToken) else { return }
                if sessionRefreshInProgress, !Task.isCancelled {
                    expireCurrentAuthentication(reason: error.localizedDescription)
                }
                dcTravelRuntime.stop()
                store.settings.cnDCTravelerPort = 0
                if Task.isCancelled {
                    updateProgress = nil
                    updateError = nil
                    showsUpdateWindow = false
                    showsLaunchDetectionCancel = false
                    gameHandoffDetectionToken = nil
                    statusText = "更新已取消。"
                    finishUpdateOperation(operationToken)
                    return
                }
                updateError = error.localizedDescription
                showsUpdateWindow = true
                statusText = error.localizedDescription
            }
            finishUpdateOperation(operationToken)
        }
    }

    @MainActor
    private func waitForGameHandoff(process: Process?, launchedPID: Int32?,
                                    usesDalamudInjector: Bool) {
        let deadline = Date().addingTimeInterval(15)
        let detectionToken = UUID()
        gameHandoffDetectionToken = detectionToken
        let wrapperPIDText = launchedPID.map(String.init) ?? "none"
        CoreBackend.appendLaunchDiagnostic(
            logs: store.paths.logs,
            "LaunchHandoff wrapperPID=\(wrapperPIDText) realPID=waiting")
        var launchProcessExitDate: Date?
        func check() {
            guard gameHandoffDetectionToken == detectionToken else { return }
            let selectedPath = store.settings.activeGamePath(managedPath: store.paths.managedGame.path)
            Task { @MainActor in
                let pid = await Task.detached(priority: .utility) { () -> Int32? in
                    // LaunchGameSdo returns the game PID after the injector has
                    // completed its handoff. For Dalamud launches, a live PID
                    // is sufficient and avoids waiting on process command-line
                    // inspection that can lag behind an already running game.
                    if usesDalamudInjector, let launchedPID,
                       CoreBackend.processIsRunning(launchedPID) {
                        return launchedPID
                    }
                    return CoreBackend.gameUnixPID(gamePath: selectedPath)
                }.value
                guard gameHandoffDetectionToken == detectionToken else { return }
                handleResult(pid)
            }
        }
        func handleResult(_ pid: Int32?) {
            guard gameHandoffDetectionToken == detectionToken else { return }
            // Dalamud launches use the live PID returned by LaunchGameSdo;
            // bare launches retain the path-aware process-table check.
            let processIsRunning = process?.isRunning == true
            let state = CoreBackend.gameHandoffState(
                gamePID: pid,
                launchProcessIsRunning: processIsRunning,
                launchProcessTerminationStatus: processIsRunning ? nil : process?.terminationStatus
            )
            switch state {
            case .gameRunning(let gamePID):
                gameHandoffDetectionToken = nil
                showsLaunchDetectionCancel = false
                showsLaunchDetectionFailure = false
                monitorGameProcess(pid: gamePID)
                gameProcess = nil
                isBusy = false
                let variantTitle = usesDalamudInjector ? store.settings.dalamudVariant.title : "未加载 Dalamud"
                statusText = "游戏已启动 · DXMT / \(variantTitle)"
                if store.settings.cnDCTravelerPort > 0 {
                    statusText = "游戏已启动 · 超域旅行服务运行中"
                    window.miniaturize(nil)
                } else if store.settings.autoCloseLauncher {
                    NSApp.terminate(nil)
                } else if store.settings.minimizeAfterLaunch {
                    window.miniaturize(nil)
                }
                return
            case .launchProcessFailed(let status):
                // Wine can hand the Windows game to a child process just as
                // its launcher process exits. Give that real game process a
                // short bounded window to appear; success still requires a
                // real ffxiv_dx11.exe PID and is never inferred from status.
                let exitDate = launchProcessExitDate ?? Date()
                launchProcessExitDate = exitDate
                if Date() < deadline && Date().timeIntervalSince(exitDate) < 8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { check() }
                    return
                }
                let reason: String
                switch process?.terminationReason {
                case .uncaughtSignal: reason = "未捕获信号"
                case .exit: reason = "正常退出"
                case .none: reason = "XOM 后端无包装进程"
                @unknown default: reason = "未知退出原因"
                }
                CoreBackend.appendLaunchDiagnostic(
                    logs: store.paths.logs,
                    "LaunchProcessExit status=\(status) reason=\(reason) gamePID=missing")
                let tail = CoreBackend.launchLogTail(logs: store.paths.logs)
                let diagnostic = tail.map { "\nWine 日志尾部：\n\($0)" } ??
                    "\n当前没有可读的 Wine 诊断输出，请在设置中启用 Wine 错误日志后重试。"
                finishFailedGameHandoff("启动进程提前退出（状态码 \(status)，\(reason)）。\(diagnostic)")
                return
            case .waiting:
                break
            }
            guard Date() < deadline else {
                let detail = processIsRunning
                    ? "启动命令仍在运行，但 15 秒内未检测到 ffxiv_dx11.exe。"
                    : "XOM 已完成 Wine 交接，但 15 秒内未检测到 ffxiv_dx11.exe（状态码 \(process?.terminationStatus ?? 0)）。"
                finishFailedGameHandoff(detail + " 未报告启动成功，请查看 game-launch.log。")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { check() }
        }
        check()
    }

    @MainActor
    private func finishFailedGameHandoff(_ detail: String) {
        gameHandoffDetectionToken = nil
        showsLaunchDetectionCancel = false
        gameProcess = nil
        isGameRunning = false
        isBusy = false
        dcTravelRuntime.stop()
        store.settings.cnDCTravelerPort = 0
        updateError = detail
        statusText = detail
        showsLaunchDetectionFailure = true
    }

    @MainActor
    func dismissLaunchDetectionFailure() {
        guard showsLaunchDetectionFailure || showsLaunchDetectionCancel else { return }
        gameHandoffDetectionToken = nil
        showsLaunchDetectionFailure = false
        showsLaunchDetectionCancel = false
        updateError = nil
        isBusy = false
        statusText = store.settings.dalamudVariant == .disabled
            ? "启动环境已就绪 · 未启用 Dalamud"
            : "启动环境已就绪 · \(store.settings.dalamudVariant.title)"
    }

    @MainActor
    private func prepareDCTravelForLaunch() async throws {
        dcTravelRuntime.stop()
        store.settings.cnDCTravelerPort = 0
        guard store.settings.dcTravelEnabled, store.settings.dalamudVariant != .disabled else { return }
        statusText = "正在初始化国服超域旅行服务…"
        let port = try await dcTravelRuntime.start(store: store, areas: availableAreas)
        store.settings.cnDCTravelerPort = Int(port)
    }

    @MainActor
    private func monitorGameProcess(pid suppliedPID: Int32? = nil) {
        guard let pid = suppliedPID ?? currentGameUnixPID() else { return }
        gameExitSource?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.gameDidExit() }
        }
        source.setCancelHandler {}
        gameExitSource = source
        isGameRunning = true
        source.resume()
    }

    @MainActor
    private func gameDidExit() {
        gameExitSource?.cancel()
        gameExitSource = nil
        gameProcess = nil
        isGameRunning = false
        isBusy = false
        dcTravelRuntime.stop()
        store.settings.cnDCTravelerPort = 0
        statusText = "游戏进程已退出"
        refreshGameState()
    }

    @MainActor
    func setDCTravelEnabled(_ enabled: Bool) {
        store.settings.dcTravelEnabled = enabled
        if !enabled {
            dcTravelRuntime.stop()
            store.settings.cnDCTravelerPort = 0
        }
    }

    /// SwiftUI's confirmation alert can return keyboard focus to the
    /// NavigationSplitView sidebar. Release that transient focus so its
    /// selection uses the normal inactive gray treatment after dismissal.
    @MainActor
    func restoreContentFocusAfterDialog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let window = self?.window else { return }
            _ = window.makeFirstResponder(nil)
        }
    }

    @MainActor
    private func updateGameIfNeeded(operationToken: UUID? = nil) async throws {
        let selection = activeGameSelection()
        guard let root = selection.root else { throw CNUpdateError.missingGameVersionFile }
        let versionFile = root.appendingPathComponent("game/ffxivgame.ver")
        let currentVersion = (try? String(contentsOf: versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let updater = try CNGameUpdateClient(endpoints: store.endpoints)
        // Launch checks only version metadata. The full integrity manifest is
        // fetched after this comparison says an update is required.
        let targetVersion = try await updater.latestGameVersion()
        if currentVersion == targetVersion {
            statusText = "国服游戏已是最新版本：\(currentVersion)"
            if case .launchPipeline? = lastUpdateOperation {
                setLaunchProgress("国服游戏已是最新版本，正在准备启动…")
            }
            return
        }
        let update = try await updater.fetchLatestUpdate()
        if currentVersion.isEmpty {
            statusText = "正在安装国服游戏 \(targetVersion)…"
        } else {
            // The official full-file integrity feed can recover versions that
            // have already fallen out of the incremental package graph.
            statusText = "正在通过国服完整性源更新 \(currentVersion) → \(targetVersion)…"
        }
        try await updater.repair(gameRoot: root, manifest: update.manifest) { [weak self] progress in
            Task { @MainActor in
                guard let self,
                      operationToken == nil || self.updateOperationToken == operationToken else { return }
                self.updateProgress = progress
                self.updateStatusText = "\(progress.phase)：\(progress.currentFile)"
            }
        }
        guard activeGameSelection() == selection else {
            throw CNUpdateError.gameSelectionChanged
        }
        try writeGameVersion(targetVersion, at: root)
        refreshGameState()
        guard case .ready(let verifiedVersion) = gameState, verifiedVersion == targetVersion else {
            throw CNUpdateError.integrityMismatch(root.appendingPathComponent("game").path)
        }
        statusText = "国服游戏更新完成。"
    }

    @MainActor
    func refreshGameState() {
        let selection = activeGameSelection()
        if selection.ownership == .external, let root = selection.root,
           !GameInstallManager.externalGamePathIsSafe(root, paths: store.paths) {
            gameState = .incomplete(reason: "外部游戏不能位于启动器数据目录内")
            return
        }
        gameState = GameDetector().detect(gameRoot: selection.root)
    }

    @MainActor
    func scheduleGameStateRefresh() {
        gameStateRefreshTask?.cancel()
        gameStateRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.refreshGameState()
            self.gameStateRefreshTask = nil
        }
    }

    private struct ActiveGameSelection: Equatable {
        let ownership: GameOwnership
        let root: URL?
    }

    @MainActor
    private func activeGameSelection() -> ActiveGameSelection {
        let path = store.settings.activeGamePath(managedPath: store.paths.managedGame.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ActiveGameSelection(ownership: store.settings.gameOwnership,
                                   root: path.isEmpty ? nil : URL(fileURLWithPath: path))
    }

    @MainActor
    func refreshNews() {
        guard !isGameRunning, newsState != .loading else { return }
        newsTask?.cancel()
        newsState = .loading
        newsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.newsTask = nil }
            do {
                self.newsItems = try await CNNewsService().fetchLatest()
                guard !Task.isCancelled, !self.isGameRunning else { return }
                self.newsState = .loaded
            } catch {
                guard !Task.isCancelled, !self.isGameRunning else { return }
                self.newsState = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    func openNews(_ item: CNNewsItem) {
        NSWorkspace.shared.open(item.detailURL)
    }

    @MainActor
    func chooseExistingGame(requireValid: Bool = false) {
        guard !isBusy, !isGameRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "请选择包含 game 目录的 FFXIV 国服目录"
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            Task { @MainActor [weak self] in
                self?.applyExistingGameSelection(url, requireValid: requireValid)
            }
        }
    }

    @MainActor
    private func applyExistingGameSelection(_ url: URL, requireValid: Bool) {
        guard GameInstallManager.externalGamePathIsSafe(url, paths: store.paths) else {
            statusText = "外部游戏不能位于启动器的数据、缓存或日志目录内。"
            return
        }
        let detected = GameDetector().detect(gameRoot: url)
        if requireValid, case .ready = detected {
            // Continue below. The selected path has the executable and a real
            // CN game version file, not merely an existing directory.
        } else if requireValid {
            statusText = "选择的目录不是可用的 FFXIV 国服目录：\(Self.gameStateReason(detected))"
            return
        }
        store.settings.setExternalGamePath(url.path, select: true, managedPath: store.paths.managedGame.path)
        gameState = detected
        if case .ready = gameState { showsGameNotFound = false }
    }

    @MainActor
    func openSelectedGameDirectory() {
        guard let root = activeGameSelection().root,
              FileManager.default.fileExists(atPath: root.path) else {
            statusText = "当前游戏目录不存在。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    @MainActor
    func openDalamudPluginDirectory(_ variant: DalamudVariant) {
        guard variant != .disabled else { return }
        let directory = store.paths.dalamudPluginDirectory(for: variant)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            statusText = "无法打开 \(variant.title) 插件目录：\(error.localizedDescription)"
        }
    }

    @MainActor
    func runFirstLaunchSetup() {
        guard !isBusy, !isGameRunning else {
            statusText = "游戏或后台任务运行期间不能重新配置首次启动选项。"
            return
        }
        firstLaunchSettingsSnapshot = store.settings
        firstLaunchStartedAsInitial = !store.settings.firstLaunchCompleted
        store.beginFirstLaunchTransaction()
        showsFirstLaunchSetup = true
    }

    @MainActor
    func completeFirstLaunchSetup() {
        store.settings.firstLaunchCompleted = true
        store.settings.firstLaunchStep = 0
        firstLaunchSettingsSnapshot = nil
        firstLaunchStartedAsInitial = false
        store.finishFirstLaunchTransaction()
        refreshGameState()
        showsFirstLaunchSetup = false
        statusText = "首次启动设置已保存。"
        synchronizeWinePrefixSettings()
    }

    /// Retina and macOS modifier-key mappings are Wine registry preferences,
    /// not game launch parameters. Apply them only when settings change so the
    /// known-good launch pipeline never waits for Wine registry commands.
    @MainActor
    func scheduleWinePrefixSettingsSynchronization() {
        isWinePrefixConfigurationReady = false
        prefixConfigurationDebounceTask?.cancel()
        prefixConfigurationDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.prefixConfigurationDebounceTask = nil
            self.synchronizeWinePrefixSettings()
        }
    }

    @MainActor
    func synchronizeWinePrefixSettings() {
        guard !showsFirstLaunchSetup, !isGameRunning else { return }
        guard prefixConfigurationTask == nil else {
            prefixConfigurationPending = true
            return
        }
        guard !isBusy else {
            prefixConfigurationPending = true
            return
        }
        prefixConfigurationPending = false
        let settings = store.settings
        let wine = store.paths.wineRuntime.appendingPathComponent("bin/wine64")
        let prefix = store.paths.winePrefix
        guard WinePrefixConfiguration.needsApply(settings: settings, prefix: prefix) else {
            isWinePrefixConfigurationReady = true
            return
        }
        isWinePrefixConfigurationReady = false
        statusText = "正在后台同步 Retina / 键盘映射设置…"
        prefixConfigurationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.prefixConfigurationTask = nil
                if self.prefixConfigurationPending {
                    self.prefixConfigurationPending = false
                    self.scheduleWinePrefixSettingsSynchronization()
                }
            }
            do {
                try await Task.detached(priority: .utility) {
                    try WinePrefixConfiguration.apply(settings: settings,
                                                      wine: wine,
                                                      prefix: prefix)
                }.value
                self.isWinePrefixConfigurationReady = true
                if !self.isGameRunning, !self.isBusy {
                    self.statusText = "Retina / 键盘映射设置已应用。"
                }
            } catch {
                // Registry settings are optional to the verified launch path.
                // Leave the snapshot absent so a later idle sync can retry,
                // but never surface this as a launch failure.
                self.prefixConfigurationPending = false
                self.isWinePrefixConfigurationReady = false
                if !self.isGameRunning, !self.isBusy {
                    self.statusText = "Wine 图形/键盘设置未完成，启动流程未受影响。"
                }
            }
        }
    }

    @MainActor
    func resetRuntimeEnvironment() {
        guard !isBusy, !isGameRunning, prefixConfigurationTask == nil else {
            runtimeResetPhase = .failed("当前有后台任务或图形设置同步正在运行，请完成后再重置 Wine/DXMT。")
            return
        }
        isBusy = true
        isWinePrefixConfigurationReady = false
        runtimeResetPhase = .running
        statusText = "正在重置 Wine / DXMT 运行环境…"
        let paths = store.paths
        let settings = store.settings
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .utility) {
                    try RuntimeEnvironmentResetter.reset(paths: paths, settings: settings)
                }.value
                self.isBusy = false
                self.isWinePrefixConfigurationReady = true
                self.statusText = "Wine / DXMT 运行环境已重置并同步设置。"
                self.runtimeResetPhase = .succeeded(
                    "已重建 Wine Prefix、重新部署内置 DXMT，并重新同步当前 Wine 图形与键盘设置。游戏、登录信息和启动器设置未被删除。"
                )
            } catch {
                self.isBusy = false
                self.isWinePrefixConfigurationReady = false
                self.statusText = error.localizedDescription
                self.runtimeResetPhase = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    func dismissRuntimeResetWindow() {
        guard runtimeResetPhase != .running else { return }
        runtimeResetPhase = nil
    }

    @MainActor
    func cancelFirstLaunchSetup() {
        let task = firstLaunchDalamudTask
        task?.cancel()
        firstLaunchDalamudTask = nil
        isFirstLaunchDalamudPreparing = false
        firstLaunchDalamudError = nil
        updateProgress = nil
        updateOperationToken = nil
        holdBusyUntilCancellationCompletes(task)
        let shouldTerminate = firstLaunchStartedAsInitial || !store.settings.firstLaunchCompleted
        if let snapshot = firstLaunchSettingsSnapshot {
            store.settings = snapshot
        }
        firstLaunchSettingsSnapshot = nil
        firstLaunchStartedAsInitial = false
        store.finishFirstLaunchTransaction()
        applyAppearance(store.settings.appearance)
        refreshGameState()
        showsFirstLaunchSetup = false
        if shouldTerminate {
            NSApp.terminate(nil)
        } else {
            statusText = "已取消首次启动设置，本次更改未保存。"
        }
    }

    /// First-launch Dalamud setup has no pause/resume state. It downloads only
    /// the selected variant, validates it, and advances the wizard on success.
    @MainActor
    func startFirstLaunchDalamudPreparation(completion: @escaping (Bool) -> Void) {
        guard !isBusy, !isGameRunning, !isFirstLaunchDalamudPreparing else { return }
        let variant = store.settings.dalamudVariant
        guard variant != .disabled else {
            completion(true)
            return
        }
        let token = beginUpdateOperation(.dalamud(variant))
        isFirstLaunchDalamudPreparing = true
        firstLaunchDalamudError = nil
        updateProgress = CNDownloadProgress(phase: "正在准备 \(variant.title)", currentFile: "",
                                            completedBytes: 0, totalBytes: 0, bytesPerSecond: 0,
                                            completedFiles: 0, totalFiles: 0)
        firstLaunchDalamudTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var success = false
            defer {
                self.isFirstLaunchDalamudPreparing = false
                self.firstLaunchDalamudTask = nil
                self.finishUpdateOperation(token)
                completion(success)
            }
            do {
                let prepared = try await self.prepareDalamud(variantOverride: variant,
                                                             operationToken: token,
                                                             fullIntegrity: false)
                if variant == .soil || prepared?.runtimeVersion != nil {
                    try await CNWindowsRuntimeInstaller(paths: self.store.paths)
                        .installRequiredRuntime(variant: variant,
                                                requiredVersion: prepared?.runtimeVersion)
                }
                try self.validateDalamudInstallation(variant)
                self.updateProgress = nil
                self.updateStatusText = "\(variant.title) 下载完成。"
                success = true
            } catch is CancellationError {
                CNDalamudUpdater.cleanupIncompleteArtifacts(in: self.store.paths.dalamudRoot(for: variant))
            } catch {
                CNDalamudUpdater.cleanupIncompleteArtifacts(in: self.store.paths.dalamudRoot(for: variant))
                self.firstLaunchDalamudError = error.localizedDescription
                self.updateProgress = nil
                self.updateStatusText = "\(variant.title) 下载失败。"
            }
        }
    }

    private static func gameStateReason(_ state: GameInstallState) -> String {
        switch state {
        case .missing: return "目录不存在"
        case .incomplete(let reason): return reason
        case .ready(let version): return "可用版本 \(version)"
        }
    }

    @MainActor
    func selectGameInstall(_ ownership: GameOwnership) {
        guard !isBusy, !isGameRunning else { return }
        managedGameDownloadCompletionMessage = nil
        store.settings.selectGameInstall(ownership, managedPath: store.paths.managedGame.path)
        refreshGameState()
        if case .ready = gameState { showsGameNotFound = false }
    }

    @MainActor
    func selectDalamudVariant(_ variant: DalamudVariant) {
        guard !isBusy, !isGameRunning else { return }
        store.settings.dalamudVariant = variant
        guard variant != .disabled else {
            statusText = "已选择不启用 Dalamud；启动时不会访问 Dalamud 更新源。"
            return
        }
        do {
            try CNDalamudUpdater.configurePluginRepository(
                at: store.paths.dalamudConfigFile(for: variant), variant: variant
            )
        } catch {
            statusText = "已选择 \(variant.title)，但主库配置失败：\(error.localizedDescription)"
            return
        }
        let root = store.paths.dalamudRoot(for: variant)
        let coreReady = CNDalamudUpdater.activeInstallationIsReady(in: root)
        let runtimeReady = CNWindowsRuntimeInstaller.installedVersion(paths: store.paths, variant: variant) != nil
        if coreReady && runtimeReady {
            let version = CNDalamudUpdater.activeVersion(in: root) ?? "未知版本"
            statusText = "已选择 \(variant.title) \(version)；启动时只检查这一套流程。"
        } else {
            statusText = "已选择 \(variant.title)；将在下次启动前下载并验证。"
        }
    }

    var isManagedGameDownloadRunning: Bool {
        isManagedGameDownloadActive && !isManagedGameDownloadPaused && managedGameDownloadTask != nil
    }

    @MainActor
    func downloadManagedGame(showPreparationNotice: Bool = true) {
        guard !isGameRunning, !isManagedGameDownloadActive else { return }
        store.settings.selectGameInstall(.managed, managedPath: store.paths.managedGame.path)
        managedGameDownloadCompletionMessage = nil
        showsManagedGameDownloadPreparationNotice = showPreparationNotice
        beginManagedGameDownload()
    }

    @MainActor
    private func beginManagedGameDownload() {
        guard managedGameDownloadTask == nil else { return }
        if !isManagedGameDownloadActive {
            isManagedGameDownloadActive = true
            managedGameDownloadProgress = nil
        }
        isManagedGameDownloadPaused = false
        managedGameDownloadError = nil
        showsGameNotFound = false
        let token = UUID()
        managedGameDownloadToken = token
        managedGameDownloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let root = self.store.paths.managedGame
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                self.statusText = "正在准备下载国服游戏…"
                let updater = try CNGameUpdateClient(endpoints: self.store.endpoints)
                let update = try await updater.fetchLatestUpdate()
                try await updater.repair(gameRoot: root, manifest: update.manifest) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.managedGameDownloadToken == token else { return }
                        self.managedGameDownloadProgress = progress
                        self.statusText = "\(progress.phase)：\(progress.currentFile)"
                    }
                }
                guard self.managedGameDownloadToken == token else { return }
                try self.writeGameVersion(update.targetGameVersion, at: root)
                guard case .ready(let version) = GameDetector().detect(gameRoot: root),
                      version == update.targetGameVersion else {
                    throw CNUpdateError.integrityMismatch(root.appendingPathComponent("game").path)
                }
                self.managedGameDownloadToken = nil
                self.managedGameDownloadTask = nil
                self.isManagedGameDownloadActive = false
                self.isManagedGameDownloadPaused = false
                self.managedGameDownloadProgress = nil
                self.managedGameDownloadError = nil
                self.refreshGameState()
                self.statusText = "国服游戏安装完成。"
                self.managedGameDownloadCompletionMessage = "国服游戏下载完成。请手动点击“启动 FFXIV”进入游戏。"
            } catch {
                guard self.managedGameDownloadToken == token, !Task.isCancelled else { return }
                self.managedGameDownloadToken = nil
                self.managedGameDownloadTask = nil
                self.isManagedGameDownloadPaused = false
                self.managedGameDownloadError = error.localizedDescription
                self.statusText = "国服游戏下载失败：\(error.localizedDescription)"
            }
        }
    }

    @MainActor
    func pauseManagedGameDownload() {
        guard isManagedGameDownloadRunning else { return }
        managedGameDownloadToken = nil
        managedGameDownloadTask?.cancel()
        managedGameDownloadTask = nil
        isManagedGameDownloadPaused = true
        statusText = "国服游戏下载已暂停。"
    }

    @MainActor
    func resumeManagedGameDownload() {
        guard isManagedGameDownloadActive, isManagedGameDownloadPaused else { return }
        beginManagedGameDownload()
    }

    @MainActor
    func retryManagedGameDownload() {
        guard isManagedGameDownloadActive, managedGameDownloadTask == nil else { return }
        managedGameDownloadError = nil
        beginManagedGameDownload()
    }

    @MainActor
    func cancelManagedGameDownload() {
        guard isManagedGameDownloadActive else { return }
        managedGameDownloadToken = nil
        managedGameDownloadTask?.cancel()
        managedGameDownloadTask = nil
        isManagedGameDownloadActive = false
        isManagedGameDownloadPaused = false
        managedGameDownloadProgress = nil
        managedGameDownloadError = nil
        try? GameInstallManager().removeManagedGame(paths: store.paths)
        refreshGameState()
        statusText = "国服游戏下载已取消，未完成文件已清理。"
    }

    @MainActor
    func dismissManagedGameDownloadCompletion() {
        managedGameDownloadCompletionMessage = nil
    }

    @MainActor
    func cancelUpdate() {
        let task = updateTask
        updateOperationToken = nil
        updateTask = nil
        task?.cancel()
        holdBusyUntilCancellationCompletes(task)
        updateProgress = nil
        updateError = nil
        updateCompletionMessage = nil
        showsUpdateWindow = false
        updateStatusText = "更新已取消。"
        statusText = "更新已取消。"
    }

    @MainActor
    func returnToLogin() {
        let task = updateTask
        updateOperationToken = nil
        updateTask = nil
        task?.cancel()
        holdBusyUntilCancellationCompletes(task)
        updateProgress = nil
        updateError = nil
        updateCompletionMessage = nil
        showsUpdateWindow = false
        statusText = "请确认国服账号登录状态后再启动游戏。"
        loginMethodStatus = ""
    }

    @MainActor
    private func holdBusyUntilCancellationCompletes(_ task: Task<Void, Never>?) {
        guard let task else {
            isBusy = false
            return
        }
        isBusy = true
        Task { @MainActor [weak self] in
            await task.value
            guard let self, self.updateOperationToken == nil,
                  self.updateTask == nil, self.firstLaunchDalamudTask == nil else { return }
            self.isBusy = false
        }
    }

    @MainActor
    func retryUpdate() {
        updateError = nil
        switch lastUpdateOperation {
        case .launchPipeline: launchGame()
        case .gameUpdate: checkGameUpdate()
        case .gameRepair: repairGameNow()
        case .dalamud(let variant): updateDalamudNow(variant)
        case .dalamudRepair(let variant): repairDalamudNow(variant)
        case .none: checkGameUpdate()
        }
    }

    @MainActor
    func checkGameUpdate() {
        guard !isBusy, !isGameRunning else { return }
        let selection = activeGameSelection()
        guard let root = selection.root else {
            updateStatusText = "请先选择国服游戏目录。"
            return
        }
        let operationToken = beginUpdateOperation(.gameUpdate)
        updateProgress = CNDownloadProgress(phase: "正在检查国服游戏版本", currentFile: "",
                                            completedBytes: 0, totalBytes: 0, bytesPerSecond: 0,
                                            completedFiles: 0, totalFiles: 0)
        showsUpdateWindow = true
        updateStatusText = "正在检查盛趣 V3 游戏更新…"
        updateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishUpdateOperation(operationToken) }
            do {
                let current = try String(contentsOf: root.appendingPathComponent("game/ffxivgame.ver"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let client = try CNGameUpdateClient(endpoints: store.endpoints)
                let latest = try await client.latestGameVersion()
                guard isCurrentUpdateOperation(operationToken), activeGameSelection() == selection else {
                    throw CNUpdateError.gameSelectionChanged
                }
                if current != latest {
                    updateStatusText = "\(selection.ownership.title)发现国服游戏更新：\(current) → \(latest)"
                    let update = try await client.fetchLatestUpdate()
                    try await client.repair(gameRoot: root, manifest: update.manifest) { [weak self] progress in
                        Task { @MainActor in
                            guard let self, self.isCurrentUpdateOperation(operationToken) else { return }
                            self.updateProgress = progress
                            self.updateStatusText = "\(progress.phase)：\(progress.currentFile)"
                        }
                    }
                    guard isCurrentUpdateOperation(operationToken), activeGameSelection() == selection else {
                        throw CNUpdateError.gameSelectionChanged
                    }
                    try writeGameVersion(update.targetGameVersion, at: root)
                    refreshGameState()
                    guard case .ready(let verifiedVersion) = gameState,
                          verifiedVersion == update.targetGameVersion else {
                        throw CNUpdateError.integrityMismatch(root.appendingPathComponent("game").path)
                    }
                    updateProgress = nil
                    updateStatusText = "国服游戏已更新至 \(update.targetGameVersion)。"
                    updateCompletionMessage = updateStatusText
                } else {
                    updateProgress = nil
                    updateStatusText = "检查完成：\(selection.ownership.title)已是最新版本 \(current)。"
                    updateCompletionMessage = updateStatusText
                }
            } catch {
                guard isCurrentUpdateOperation(operationToken), !Task.isCancelled else { return }
                updateProgress = nil
                updateError = error.localizedDescription
                updateStatusText = "游戏更新检查失败：\(error.localizedDescription)"
            }
        }
    }

    @MainActor
    func repairGameNow() {
        guard !isBusy, !isGameRunning else { return }
        let selection = activeGameSelection()
        guard let root = selection.root else {
            updateStatusText = "启动器管理目录尚未配置。"
            showsGameNotFound = true
            return
        }
        let operationToken = beginUpdateOperation(.gameRepair)
        updateError = nil
        showsUpdateWindow = true
        updateStatusText = "正在读取盛趣完整性清单…"
        updateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishUpdateOperation(operationToken) }
            do {
                let client = try CNGameUpdateClient(endpoints: self.store.endpoints)
                let update = try await client.fetchLatestUpdate()
                try await client.repair(gameRoot: root, manifest: update.manifest) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.isCurrentUpdateOperation(operationToken) else { return }
                        self.updateProgress = progress
                        self.updateStatusText = "\(progress.phase)：\(progress.currentFile)"
                    }
                }
                guard self.isCurrentUpdateOperation(operationToken), self.activeGameSelection() == selection else {
                    throw CNUpdateError.gameSelectionChanged
                }
                try self.writeGameVersion(update.targetGameVersion, at: root)
                self.refreshGameState()
                guard case .ready(let verifiedVersion) = self.gameState,
                      verifiedVersion == update.targetGameVersion else {
                    throw CNUpdateError.integrityMismatch(root.appendingPathComponent("game").path)
                }
                self.updateStatusText = "国服游戏完整性检查与修复完成。"
                self.updateProgress = nil
                self.updateCompletionMessage = self.updateStatusText
            } catch {
                guard self.isCurrentUpdateOperation(operationToken), !Task.isCancelled else { return }
                self.updateError = error.localizedDescription
                self.updateStatusText = "游戏修复失败：\(error.localizedDescription)"
            }
        }
    }

    private func writeGameVersion(_ version: String, at root: URL) throws {
        let gameDirectory = root.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
        try version.write(to: gameDirectory.appendingPathComponent("ffxivgame.ver"), atomically: true, encoding: .utf8)
        try version.write(to: gameDirectory.appendingPathComponent("ffxivgame.bck"), atomically: true, encoding: .utf8)
    }

    @MainActor
    func removeManagedGame() throws {
        if isManagedGameDownloadActive { cancelManagedGameDownload() }
        managedGameDownloadCompletionMessage = nil
        try GameInstallManager().removeGame(settings: store.settings, paths: store.paths)
        store.settings.selectGameInstall(.external, managedPath: store.paths.managedGame.path)
        refreshGameState()
        updateStatusText = "启动器管理的游戏已删除。"
    }

    @MainActor
    func removeDalamud(_ variant: DalamudVariant) throws {
        guard variant != .disabled, !isBusy, !isGameRunning else { return }
        let fileManager = FileManager.default
        let root = store.paths.dalamudRoot(for: variant)
        let logs = store.paths.dalamudLogDirectory(for: variant)
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        if fileManager.fileExists(atPath: logs.path) {
            try fileManager.removeItem(at: logs)
        }
        dcTravelRuntime.stop()
        store.settings.cnDCTravelerPort = 0
        statusText = "\(variant.title) 已清除。"
    }

    @MainActor
    func updateDalamudNow(_ requestedVariant: DalamudVariant? = nil) {
        runDalamudOperation(requestedVariant, fullIntegrity: false)
    }

    @MainActor
    func repairDalamudNow(_ requestedVariant: DalamudVariant) {
        runDalamudOperation(requestedVariant, fullIntegrity: true)
    }

    @MainActor
    private func runDalamudOperation(_ requestedVariant: DalamudVariant?, fullIntegrity: Bool) {
        guard !isBusy, !isGameRunning else { return }
        let variant = requestedVariant ?? store.settings.dalamudVariant
        guard variant != .disabled else {
            updateStatusText = "已选择不启用 Dalamud，未执行任何 Dalamud 更新检查。"
            return
        }
        let operationToken = beginUpdateOperation(fullIntegrity ? .dalamudRepair(variant) : .dalamud(variant))
        updateError = nil
        updateProgress = CNDownloadProgress(phase: fullIntegrity ? "正在检查并修复 " + variant.title : "正在检查 " + variant.title,
                                            currentFile: "",
                                            completedBytes: 0, totalBytes: 0, bytesPerSecond: 0,
                                            completedFiles: 0, totalFiles: 0)
        showsUpdateWindow = true
        updateStatusText = fullIntegrity
            ? "正在完整检查 " + variant.title + " / 资源 / Runtime…"
            : "正在检查 " + variant.title + " 版本 / 资源版本 / Runtime 版本…"
        updateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishUpdateOperation(operationToken) }
            do {
                let prepared = try await prepareDalamud(variantOverride: variant,
                                                        operationToken: operationToken,
                                                        fullIntegrity: fullIntegrity)
                if variant == .soil || prepared?.runtimeVersion != nil {
                    try await CNWindowsRuntimeInstaller(paths: store.paths).installRequiredRuntime(
                        variant: variant, requiredVersion: prepared?.runtimeVersion,
                        progress: { [weak self] progress in
                            Task { @MainActor in
                                guard let self, self.isCurrentUpdateOperation(operationToken) else { return }
                                self.updateProgress = progress
                            }
                        })
                }
                guard isCurrentUpdateOperation(operationToken) else { return }
                try validateDalamudInstallation(variant)
                let version = CNDalamudUpdater.activeVersion(in: store.paths.dalamudRoot(for: variant))
                guard let version else { throw GameLaunchError.dalamudUnavailable(variant.title) }
                updateStatusText = fullIntegrity
                    ? variant.title + " 完整性检查与修复完成：" + version
                    : variant.title + " 版本检查完成：" + version
                updateProgress = nil
                updateCompletionMessage = updateStatusText
            } catch {
                guard isCurrentUpdateOperation(operationToken), !Task.isCancelled else { return }
                updateError = error.localizedDescription
                updateStatusText = variant.title + " 更新失败：" + error.localizedDescription
            }
        }
    }

    @MainActor
    func confirmUpdateCompletion() {
        guard updateCompletionMessage != nil else { return }
        updateCompletionMessage = nil
        updateProgress = nil
        updateError = nil
        showsUpdateWindow = false
    }

    @MainActor
    func refreshAreas() async {
        guard !isGameRunning, !isRefreshingAreas else { return }
        isRefreshingAreas = true
        areaStatusText = "正在获取国服大区列表…"
        defer { isRefreshingAreas = false }
        do {
            let service = try CNCoreLoginBackend(endpoints: store.endpoints)
            let refreshedAreas = try await service.fetchAreas()
            availableAreas = refreshedAreas
            areaStatusText = "已获取 \(refreshedAreas.count) 个国服大区"
            if store.settings.cnAreaID.isEmpty,
               let first = availableAreas.first(where: { $0.status == 1 }) {
                selectArea(first)
            }
        } catch {
            areaStatusText = availableAreas.isEmpty
                ? "大区列表获取失败：\(error.localizedDescription)"
                : "刷新失败，已保留上次列表：\(error.localizedDescription)"
        }
    }

    @MainActor
    func selectArea(_ area: CNLoginArea) {
        var next = store.settings
        next.cnAreaID = area.id
        next.cnLobbyHost = area.lobbyHost
        next.cnGMHost = area.gmHost
        next.cnSaveDataBankHost = area.configUploadHost
        if !availableAreas.isEmpty {
            next.cnAreasInfo = ((try? JSONEncoder().encode(availableAreas)) ?? Data("[]".utf8)).base64EncodedString()
        }
        store.settings = next
    }

    @MainActor
    func cancelLogin() {
        let task = loginTask
        loginOperationToken = nil
        loginTask = nil
        task?.cancel()
        qrCodeData = nil
        loginVerificationCode = nil
        isLoginInProgress = false
        isBusy = updateOperationToken != nil
        authState = authState.afterCancelledAuthentication()
        statusText = "已取消登录。"
        loginMethodStatus = "已取消登录。"
    }

    /// Called by the login picker. QR authentication is a two-stage flow: the
    /// first stage obtains and displays a real QR image, then the existing CAS
    /// service polls until the phone confirms it. Other methods only clear a
    /// previous QR task; they never submit credentials implicitly.
    @MainActor
    func loginMethodChanged(_ method: CNLoginMethod) {
        store.settings.selectedLoginMethod = method
        if method == .qrCode {
            beginQRCodeLogin()
            return
        }

        if loginTask != nil {
            let task = loginTask
            loginOperationToken = nil
            loginTask = nil
            task?.cancel()
            isLoginInProgress = false
            isBusy = updateOperationToken != nil
            authState = authState.afterCancelledAuthentication()
        }
        qrCodeData = nil
        loginVerificationCode = nil
        loginMethodStatus = ""
        if !authState.isAuthenticated {
            statusText = "请选择登录方式并登录国服账号。"
        }
    }

    @MainActor
    func beginQRCodeLogin() {
        guard !isBusy else {
            statusText = "正在处理其他操作，请稍候。"
            return
        }
        login(method: .qrCode, account: "", password: "")
    }

    @MainActor
    func refreshQRCode() {
        guard store.settings.selectedLoginMethod == .qrCode, !isGameRunning else { return }
        let task = loginTask
        loginOperationToken = nil
        loginTask = nil
        task?.cancel()
        qrCodeData = nil
        loginVerificationCode = nil
        isLoginInProgress = false
        isBusy = updateOperationToken != nil
        authState = authState.afterCancelledAuthentication()
        login(method: .qrCode, account: "", password: "")
    }

    @MainActor
    func importWeGameCredentials() {
        do {
            let credentials = try CNWeGameExchange.importCredentials()
            importedWeGameCredentials = credentials
            statusText = "已导入 WeGame 登录信息，请点击登录。"
            loginMethodStatus = "已导入 UserId/Token。"
        } catch let error as CNWeGameExchangeError where error == .canceled {
            return
        } catch {
            statusText = error.localizedDescription
            loginMethodStatus = error.localizedDescription
        }
    }

    @MainActor
    func login(method: CNLoginMethod, account: String, password: String) {
        guard !isGameRunning else {
            statusText = "FFXIV 运行期间不能切换国服登录账号。"
            loginMethodStatus = "请先退出游戏，再重新登录。"
            return
        }
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if let issue = CNLoginInputValidator.issue(method: method, account: account, password: password) {
            statusText = issue.message
            loginMethodStatus = issue.message
            return
        }
        if method == .quickLogin && (account.isEmpty || CNKeychain().loadSecret(account: account) == nil) {
            statusText = "没有找到该账号的一键登录凭据，请先使用扫码或动态验证登录。"
            loginMethodStatus = statusText
            return
        }
        loginTask?.cancel()
        let operationToken = UUID()
        loginOperationToken = operationToken
        qrCodeData = nil
        loginVerificationCode = nil
        isBusy = true
        isLoginInProgress = true
        loginMethodStatus = ""
        let candidate = method == .qrCode ? "扫码账号" : account
        authState = authState.startingAuthentication(candidate: candidate)
        let area = availableAreas.first(where: { $0.id == store.settings.cnAreaID && $0.status == 1 })
        loginTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishLoginOperation(operationToken) }
            do {
                let service = try CNCoreLoginBackend(endpoints: store.endpoints)
                let progress: (String) async -> Void = { [weak self] message in
                    await MainActor.run {
                        guard let self, self.isCurrentLoginOperation(operationToken) else { return }
                        self.statusText = message
                        self.loginMethodStatus = message
                    }
                }
                let session: CNLoginSession
                switch method {
                case .password:
                    session = try await service.login(account: account, password: password, area: area,
                                                      quickLogin: store.settings.quickLoginEnabled,
                                                      progress: progress)
                case .quickLogin:
                    guard let secret = CNKeychain().loadSecret(account: account) else {
                        throw CNLoginServiceError.quickLoginUnavailable
                    }
                    session = try await service.quickLogin(account: account, secret: secret, area: area, progress: progress)
                case .weGame:
                    let token = password.isEmpty
                        ? (CNKeychain().loadWeGameToken(account: account) ?? "")
                        : password
                    guard !token.isEmpty else { throw CNLoginServiceError.weGameTokenUnavailable }
                    session = try await service.loginWeGame(account: account, token: token, area: area,
                                                            quickLogin: store.settings.quickLoginEnabled,
                                                            progress: progress)
                case .qrCode:
                    session = try await service.loginQRCode(area: area, quickLogin: store.settings.quickLoginEnabled,
                                                            onQRCode: { [weak self] data in
                                                                await MainActor.run {
                                                                    guard let self,
                                                                          self.isCurrentLoginOperation(operationToken) else { return }
                                                                    self.qrCodeData = data
                                                                    self.statusText = "请使用国服手机 App 扫描二维码…"
                                                                    self.loginMethodStatus = "二维码已生成，等待扫码确认。"
                                                                }
                                                            }, progress: progress)
                case .slide:
                    if let secret = CNKeychain().loadSecret(account: account) {
                        do {
                            session = try await service.quickLogin(account: account, secret: secret,
                                                                   area: area, progress: progress)
                        } catch {
                            CNKeychain().deleteSecret(account: account)
                            await progress("已保存凭据失效，正在回退到国服一键登录…")
                            session = try await service.loginSlide(account: account, area: area,
                                                                   quickLogin: store.settings.quickLoginEnabled,
                                                                   onVerificationCode: { [weak self] code in
                                                                       await self?.showVerificationCode(code, operationToken: operationToken)
                                                                   }, progress: progress)
                        }
                    } else {
                        session = try await service.loginSlide(account: account, area: area,
                                                               quickLogin: store.settings.quickLoginEnabled,
                                                               onVerificationCode: { [weak self] code in
                                                                   await self?.showVerificationCode(code, operationToken: operationToken)
                                                               }, progress: progress)
                    }
                }
                guard isCurrentLoginOperation(operationToken) else { return }
                qrCodeData = nil
                loginVerificationCode = nil
                dcTravelRuntime.stop()
                store.settings.cnDCTravelerPort = 0
                store.apply(login: session)
                authState = .authenticated(account: session.account)
                if let selected = availableAreas.first(where: { $0.id == session.area.id }) { selectArea(selected) }
                let savedQuickLogin = CNKeychain().loadSecret(account: session.account) != nil
                if savedQuickLogin {
                    store.settings.selectedLoginMethod = .quickLogin
                }
                let successTitle = method == .qrCode ? "扫码登录成功" : "登录成功"
                statusText = "\(successTitle) · \(session.area.name) · \(session.account)"
                loginMethodStatus = savedQuickLogin
                    ? "\(successTitle)，快速续登凭据已保存；请手动点击“启动 FFXIV”。"
                    : "\(successTitle)，账号信息已加载；请手动点击“启动 FFXIV”。"
                if store.settings.autoLaunch {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.launchGame()
                    }
                }
            } catch {
                guard isCurrentLoginOperation(operationToken), !Task.isCancelled else { return }
                authState = authState.afterFailedAuthentication(message: error.localizedDescription)
                statusText = error.localizedDescription
                loginMethodStatus = error.localizedDescription
                qrCodeData = nil
                loginVerificationCode = nil
            }
        }
    }

    @MainActor
    private func showVerificationCode(_ code: String, operationToken: UUID) async {
        guard isCurrentLoginOperation(operationToken) else { return }
        loginVerificationCode = code
        loginMethodStatus = "请在叨鱼 App 中确认本次登录请求。"
        statusText = "等待叨鱼 App 确认 · 请求编号 \(code)"
    }

}
