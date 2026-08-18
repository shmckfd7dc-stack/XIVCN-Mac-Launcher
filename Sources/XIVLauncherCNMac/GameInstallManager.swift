import Foundation

enum GameInstallError: LocalizedError {
    case externalGameCannotBeRemoved
    case unsafeManagedPath(URL)

    var errorDescription: String? {
        switch self {
        case .externalGameCannotBeRemoved:
            return "外部游戏不允许由启动器删除。"
        case .unsafeManagedPath(let url):
            return "游戏路径不在启动器管理目录中，已拒绝删除：\(url.path)"
        }
    }
}

struct GameDetector {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func detect(gameRoot: URL?) -> GameInstallState {
        guard let root = gameRoot, !root.path.isEmpty,
              fileManager.fileExists(atPath: root.path) else { return .missing }

        let game = root.appendingPathComponent("game", isDirectory: true)
        let dx11Executable = game.appendingPathComponent("ffxiv_dx11.exe")
        let fallbackExecutable = game.appendingPathComponent("ffxiv.exe")
        let versionFile = game.appendingPathComponent("ffxivgame.ver")
        guard fileManager.fileExists(atPath: game.path) else {
            return .incomplete(reason: "缺少 game 目录")
        }
        let hasExecutable = [dx11Executable, fallbackExecutable].contains {
            fileManager.fileExists(atPath: $0.path) &&
            ((try? fileManager.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value ?? 0) > 0
        }
        guard hasExecutable else {
            return .incomplete(reason: "缺少 game/ffxiv_dx11.exe 或 game/ffxiv.exe")
        }
        guard fileManager.fileExists(atPath: versionFile.path) else {
            return .incomplete(reason: "缺少 game/ffxivgame.ver")
        }
        let version = (try? String(contentsOf: versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else { return .incomplete(reason: "游戏版本文件为空") }
        return .ready(version: version)
    }
}

struct GameInstallManager {
    static func externalGamePathIsSafe(_ path: URL, paths: ManagedPaths) -> Bool {
        let candidate = path.standardizedFileURL.path
        let roots = [paths.applicationSupport, paths.caches, paths.logs].map { $0.standardizedFileURL.path }
        return !roots.contains { candidate == $0 || candidate.hasPrefix($0 + "/") }
    }

    func removeGame(settings: LauncherSettings, paths: ManagedPaths = ManagedPaths(),
                    fileManager: FileManager = .default) throws {
        guard settings.gameOwnership == .managed else { throw GameInstallError.externalGameCannotBeRemoved }
        try removeManagedGame(paths: paths, fileManager: fileManager)
    }

    func removeManagedGame(paths: ManagedPaths = ManagedPaths(),
                           fileManager: FileManager = .default) throws {
        let path = paths.managedGame.standardizedFileURL
        let managedRoot = paths.applicationSupport.appendingPathComponent("game", isDirectory: true)
            .standardizedFileURL
        guard path.path == managedRoot.path else {
            throw GameInstallError.unsafeManagedPath(path)
        }
        if fileManager.fileExists(atPath: path.path) { try fileManager.removeItem(at: path) }
    }
}
