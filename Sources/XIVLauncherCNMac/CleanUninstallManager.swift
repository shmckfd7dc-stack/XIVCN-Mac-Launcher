import Foundation

struct CleanUninstallReport: Equatable {
    let keychainRemoved: Bool
    let applicationDataRemoved: Bool
    let cachesRemoved: Bool
    let logsRemoved: Bool
    let preferencesRemoved: Bool

    var isComplete: Bool {
        keychainRemoved && applicationDataRemoved && cachesRemoved && logsRemoved && preferencesRemoved
    }
}

enum CleanUninstallError: LocalizedError {
    case launcherBusy
    case externalGameInsideLauncherData(String)
    case removeFailed(path: String, reason: String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .launcherBusy:
            return "游戏、登录或更新正在运行，无法执行完整卸载。"
        case .externalGameInsideLauncherData(let path):
            return "外部游戏位于启动器数据目录内，完整卸载会影响该目录，已拒绝清理：\(path)。请先移动并重新选择外部游戏。"
        case .removeFailed(let path, let reason):
            return "无法删除本项目数据 \(path)：\(reason)"
        case .verificationFailed(let item):
            return "完整卸载后仍检测到本项目数据：\(item)"
        }
    }
}

struct CleanUninstallManager {
    static let bundleIdentifier = "cn.xivlaunchermac"
    static let windowFramePreference = "NSWindow Frame XIVCN Mac Launcher Main Window"
    static let devicePreferenceKeys = [
        "XIVLauncherCNMac.MacAddress",
        "XIVLauncherCNMac.HostName",
        "XIVLauncherCNMac.DeviceID",
        "XIVLauncherCNMac.CASCID"
    ]

    private let fileManager: FileManager
    private let keychain: CNKeychain
    private let userDefaults: UserDefaults
    private let preferenceDomain: String

    init(fileManager: FileManager = .default,
         keychain: CNKeychain = CNKeychain(),
         userDefaults: UserDefaults = .standard,
         preferenceDomain: String = CleanUninstallManager.bundleIdentifier) {
        self.fileManager = fileManager
        self.keychain = keychain
        self.userDefaults = userDefaults
        self.preferenceDomain = preferenceDomain
    }

    func removeAll(paths: ManagedPaths, externalGamePath: String = "") throws -> CleanUninstallReport {
        let groups = removalTargetGroups(paths: paths)
        if !externalGamePath.isEmpty {
            let external = URL(fileURLWithPath: externalGamePath).standardizedFileURL
            if !GameInstallManager.externalGamePathIsSafe(external, paths: paths) {
                throw CleanUninstallError.externalGameInsideLauncherData(external.path)
            }
        }
        try keychain.deleteAllProjectItems()
        guard keychain.savedAccounts().isEmpty else {
            throw CleanUninstallError.verificationFailed("Keychain Service \(keychain.serviceName)")
        }

        try remove(groups.applicationData)
        try remove(groups.caches)
        try remove(groups.logs)

        // Launcher settings use launcher.json, not UserDefaults. These exact
        // keys/domains are still removed because NSWindow frame autosave uses
        // Preferences independently of launcher.json.
        userDefaults.removeObject(forKey: Self.windowFramePreference)
        for key in Self.devicePreferenceKeys { userDefaults.removeObject(forKey: key) }
        userDefaults.removePersistentDomain(forName: preferenceDomain)
        _ = userDefaults.synchronize()
        let preferencesDomainEmpty = userDefaults.persistentDomain(forName: preferenceDomain)?.isEmpty != false

        let report = CleanUninstallReport(
            keychainRemoved: keychain.savedAccounts().isEmpty,
            applicationDataRemoved: groups.applicationData.allSatisfy { !fileManager.fileExists(atPath: $0.path) },
            cachesRemoved: groups.caches.allSatisfy { !fileManager.fileExists(atPath: $0.path) },
            logsRemoved: groups.logs.allSatisfy { !fileManager.fileExists(atPath: $0.path) },
            preferencesRemoved: userDefaults.object(forKey: Self.windowFramePreference) == nil &&
                Self.devicePreferenceKeys.allSatisfy { userDefaults.object(forKey: $0) == nil } &&
                preferencesDomainEmpty
        )
        guard report.isComplete else {
            throw CleanUninstallError.verificationFailed("清理结果未通过回读校验")
        }
        return report
    }

    private func removalTargetGroups(paths: ManagedPaths) ->
        (applicationData: [URL], caches: [URL], logs: [URL]) {
        ([paths.applicationSupport], [paths.caches], [paths.logs])
    }

    private func remove(_ urls: [URL]) throws {
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw CleanUninstallError.removeFailed(path: url.path, reason: error.localizedDescription)
            }
        }
    }
}
