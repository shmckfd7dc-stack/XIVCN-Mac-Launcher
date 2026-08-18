import Foundation

enum GameConfigurationError: LocalizedError {
    case bundledDefaultMissing

    var errorDescription: String? {
        switch self {
        case .bundledDefaultMissing: return "应用包缺少 XOM 的 FFXIV 默认配置。"
        }
    }
}

enum GameConfiguration {
    static func prepare(paths: ManagedPaths,
                        gameRoot: URL? = nil,
                        bundle: Bundle = .main, defaultTemplate: URL? = nil,
                        fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: paths.gameConfig, withIntermediateDirectories: true)
        let launcherConfig = paths.gameConfig.appendingPathComponent("FFXIV.cfg")
        if !fileManager.fileExists(atPath: launcherConfig.path) {
            guard let template = defaultTemplate ?? bundle.url(forResource: "FFXIV-MacDefault", withExtension: "cfg") else {
                throw GameConfigurationError.bundledDefaultMissing
            }
            try fileManager.copyItem(at: template, to: launcherConfig)
        }

        // This is the only game fix carried from the verified CN Core path.
        // It is intentionally idempotent so a normal launch does not rewrite
        // the game configuration.
        if let gameRoot {
            try applyCutsceneMovieOpeningFix(gameRoot: gameRoot, fileManager: fileManager)
        }
    }

    private static func applyCutsceneMovieOpeningFix(gameRoot: URL,
                                                     fileManager: FileManager) throws {
        let config = gameRoot.appendingPathComponent(
            "game/My Games/FINAL FANTASY XIV - A Realm Reborn/FFXIV.cfg")
        guard fileManager.fileExists(atPath: config.path) else { return }
        let text = try String(contentsOf: config, encoding: .utf8)
        guard text.range(of: #"(?m)^[ \t]*CutsceneMovieOpening[ \t]+0[ \t]*\r?$"#, options: .regularExpression) != nil else {
            return
        }
        let fixed = text.replacingOccurrences(
            of: #"(?m)^([ \t]*CutsceneMovieOpening)[ \t]+0[ \t]*$"#,
            with: "$1\t1", options: .regularExpression)
        guard fixed != text else { return }
        try fixed.write(to: config, atomically: true, encoding: .utf8)
    }
}
