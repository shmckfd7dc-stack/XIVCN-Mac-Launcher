import Foundation

enum RuntimeEnvironmentResetter {
    static func reset(paths: ManagedPaths,
                      settings: LauncherSettings,
                      fileManager: FileManager = .default) throws {
        guard paths.usesBundledXOMRuntime else { throw BundledRuntimeError.missingRuntime }
        let prefix = paths.winePrefix.standardizedFileURL
        let expected = paths.applicationSupport.appendingPathComponent("wineprefix", isDirectory: true)
            .standardizedFileURL
        guard prefix.path == expected.path else {
            throw WinePrefixConfigurationError.unsafePrefixPath(prefix)
        }
        if fileManager.fileExists(atPath: prefix.path) {
            try fileManager.removeItem(at: prefix)
        }
        try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)
        let wine = paths.wineRuntime.appendingPathComponent("bin/wine64")
        guard fileManager.isExecutableFile(atPath: wine.path) else {
            throw BundledRuntimeError.missingRuntime
        }
        try XOMGraphicsInstaller.ensureBackend(paths: paths, destinationPrefix: prefix,
                                               fileManager: fileManager)
        // The Prefix is now a fresh runtime. Apply the user's current
        // settings only after recreation so reset always ends in a usable,
        // synchronized environment.
        try WinePrefixConfiguration.apply(settings: settings, wine: wine, prefix: prefix,
                                          fileManager: fileManager)
    }
}
