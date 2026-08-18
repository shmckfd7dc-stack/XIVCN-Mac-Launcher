import Foundation
import Combine

final class SettingsStore: ObservableObject {
    @Published var settings: LauncherSettings { didSet { scheduleSave() } }
    @Published private(set) var endpoints: RegionEndpoints
    @Published private(set) var savedAccounts: [CNSavedAccount] = []
    let paths: ManagedPaths
    private let keychain: CNKeychain
    private let settingsURL: URL
    private let firstLaunchBackupURL: URL
    private let endpointsURL: URL
    private let saveQueue = DispatchQueue(label: "cn.xivlaunchermac.settings-save", qos: .utility)
    private var pendingSaveWorkItem: DispatchWorkItem?

    init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default,
         keychain: CNKeychain = CNKeychain()) {
        self.paths = paths
        self.keychain = keychain
        settingsURL = paths.config.appendingPathComponent("launcher.json")
        firstLaunchBackupURL = paths.config.appendingPathComponent("launcher.first-launch-backup.json")
        endpointsURL = paths.config.appendingPathComponent("region-cn.json")
        var loadedSettings: LauncherSettings
        if let data = try? Data(contentsOf: settingsURL), let value = try? JSONDecoder().decode(LauncherSettings.self, from: data) {
            loadedSettings = value
        } else { loadedSettings = LauncherSettings() }
        if let data = try? Data(contentsOf: firstLaunchBackupURL),
           let backup = try? JSONDecoder().decode(LauncherSettings.self, from: data) {
            loadedSettings = backup
        }
        loadedSettings.reconcileGameInstallPaths(managedPath: paths.managedGame.path)
        // Secure values are never activated during decoding. AppDelegate must
        // validate a stored session with the real CN service first.
        loadedSettings.cnTGT = ""
        loadedSettings.cnGUID = ""
        loadedSettings.cnSessionID = ""
        loadedSettings.cnSndaID = ""
        let detectedSavedAccounts = keychain.savedAccounts()
        settings = loadedSettings
        if let data = try? Data(contentsOf: endpointsURL), let value = try? JSONDecoder().decode(RegionEndpoints.self, from: data), (try? value.validated()) != nil {
            endpoints = value
        } else { endpoints = RegionEndpoints() }
        savedAccounts = detectedSavedAccounts
        try? paths.createDirectories(fileManager: fileManager)
        if !fileManager.fileExists(atPath: endpointsURL.path) { saveEndpoints(endpoints) }
    }

    func save() {
        scheduleSave()
    }

    /// Flushes a pending debounced write before the application exits. This
    /// keeps the normal quit path lossless without making every UI keystroke
    /// synchronous; clean uninstall deliberately skips this method.
    func flushSave() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        saveNow(waitForDisk: true)
    }

    private func scheduleSave() {
        pendingSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func saveNow(waitForDisk: Bool = false) {
        try? FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        var persisted = settings
        persisted.cnTGT = ""
        persisted.cnGUID = ""
        persisted.cnSessionID = ""
        persisted.cnSndaID = ""
        guard let data = try? JSONEncoder.pretty.encode(persisted) else { return }
        let destination = settingsURL
        let write = { try? data.write(to: destination, options: .atomic) }
        if waitForDisk {
            saveQueue.sync(execute: write)
        } else {
            saveQueue.async { write() }
        }
    }

    @MainActor
    func beginFirstLaunchTransaction() {
        var snapshot = settings
        snapshot.cnTGT = ""
        snapshot.cnGUID = ""
        snapshot.cnSessionID = ""
        snapshot.cnSndaID = ""
        guard let data = try? JSONEncoder.pretty.encode(snapshot) else { return }
        try? paths.createDirectories()
        try? data.write(to: firstLaunchBackupURL, options: .atomic)
    }

    @MainActor
    func finishFirstLaunchTransaction() {
        try? FileManager.default.removeItem(at: firstLaunchBackupURL)
    }

    func saveEndpoints(_ value: RegionEndpoints) {
        guard (try? value.validated()) != nil else { return }
        endpoints = value
        try? paths.createDirectories()
        if let data = try? JSONEncoder.pretty.encode(value) { try? data.write(to: endpointsURL, options: .atomic) }
    }

    @MainActor
    func apply(login session: CNLoginSession) {
        var next = settings
        next.cnAccount = session.account
        next.cnTGT = session.tgt
        next.cnGUID = session.guid
        next.cnSessionID = session.sessionID
        next.cnSndaID = session.sndaID
        next.cnAreaID = session.area.id
        next.cnLobbyHost = session.area.lobbyHost
        next.cnGMHost = session.area.gmHost
        next.cnSaveDataBankHost = session.area.configUploadHost
        next.cnAreasInfo = session.areasInfo
        settings = next
        if let weGameToken = session.weGameToken, !weGameToken.isEmpty {
            try? keychain.saveWeGameToken(weGameToken, account: session.account)
        } else if settings.quickLoginEnabled, let secret = session.quickLoginSecret, !secret.isEmpty {
            try? keychain.saveSecret(secret, account: session.account)
        }
        if settings.quickLoginEnabled {
            let secure = CNSecureSession(tgt: session.tgt, guid: session.guid,
                                         sessionID: session.sessionID, sndaID: session.sndaID)
            try? keychain.saveSession(secure, account: session.account)
        } else if !settings.quickLoginEnabled {
            keychain.deleteSecret(account: session.account)
            keychain.deleteWeGameToken(account: session.account)
            keychain.deleteSession(account: session.account)
        }
        refreshSavedAccounts()
    }

    @MainActor
    func activateRestoredSession(account: String, secure: CNSecureSession, ticket: String) {
        var next = settings
        next.cnAccount = account
        next.cnTGT = secure.tgt
        next.cnGUID = secure.guid
        next.cnSessionID = ticket
        next.cnSndaID = secure.sndaID
        settings = next
        let refreshed = CNSecureSession(tgt: secure.tgt, guid: secure.guid,
                                        sessionID: ticket, sndaID: secure.sndaID)
        try? keychain.saveSession(refreshed, account: account)
    }

    @MainActor
    func updateGameSessionTicket(_ ticket: String) {
        guard !settings.cnAccount.isEmpty, !settings.cnTGT.isEmpty, !settings.cnGUID.isEmpty else { return }
        var next = settings
        next.cnSessionID = ticket
        settings = next
        guard settings.quickLoginEnabled else { return }
        let secure = CNSecureSession(tgt: settings.cnTGT, guid: settings.cnGUID,
                                     sessionID: ticket, sndaID: settings.cnSndaID)
        try? keychain.saveSession(secure, account: settings.cnAccount)
    }

    /// Ends only the active server session. The reusable 30-day secret is a
    /// separate credential and remains available for an explicit quick login.
    @MainActor
    func logoutCurrentSession() -> String? {
        let account = settings.cnAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        if !account.isEmpty { keychain.deleteSession(account: account) }
        var next = settings
        next.cnTGT = ""
        next.cnGUID = ""
        next.cnSessionID = ""
        next.cnSndaID = ""
        next.cnDCTravelerPort = 0
        settings = next
        refreshSavedAccounts()
        return account.isEmpty ? nil : account
    }

    func clearLogin() {
        let account = settings.cnAccount
        if !account.isEmpty {
            keychain.deleteAccount(account: account)
        }
        var next = settings
        next.cnAccount = ""
        next.cnTGT = ""
        next.cnGUID = ""
        next.cnSessionID = ""
        next.cnSndaID = ""
        next.cnDCTravelerPort = 0
        settings = next
        refreshSavedAccounts()
    }

    func refreshSavedAccounts() {
        savedAccounts = keychain.savedAccounts()
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
