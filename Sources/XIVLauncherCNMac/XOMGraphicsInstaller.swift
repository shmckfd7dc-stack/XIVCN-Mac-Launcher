import Foundation

/// Thin adapter for the international XOM desktop layer's GraphicsInstaller.
/// This is resource preparation only; it never starts Wine or manages a
/// Prefix. Game execution remains in the source-built Core CompatibilityTools.
enum XOMGraphicsInstaller {
    private static let system32 = "drive_c/windows/system32"
    private static let dxmtNames = ["d3d11.dll", "dxgi.dll"]
    private static let markerName = ".xivcn-xom-graphics-5.4.2"

    static func ensureBackend(paths: ManagedPaths,
                              destinationPrefix: URL? = nil,
                              bundle: Bundle = .main,
                              fileManager: FileManager = .default) throws {
        guard paths.usesBundledXOMRuntime,
              let compiler = bundle.url(forResource: "d3dcompiler_47",
                                         withExtension: "dll",
                                         subdirectory: "d3dcompiler"),
              let dxmt = bundle.url(forResource: "dxmt", withExtension: nil) else {
            throw BundledRuntimeError.missingRuntime
        }

        let destinationRoot = (destinationPrefix ?? paths.winePrefix)
            .appendingPathComponent(system32, isDirectory: true)
        try fileManager.createDirectory(at: destinationRoot,
                                        withIntermediateDirectories: true)
        let marker = destinationRoot.appendingPathComponent(markerName)
        if fileManager.fileExists(atPath: marker.path),
           dxmtNames.allSatisfy({ fileManager.isReadableFile(atPath: destinationRoot.appendingPathComponent($0).path) }),
           fileManager.isReadableFile(atPath: destinationRoot.appendingPathComponent("d3dcompiler_47.dll").path) {
            return
        }
        try install(compiler, into: destinationRoot, fileManager: fileManager)
        for name in dxmtNames {
            let source = dxmt.appendingPathComponent(name)
            guard fileManager.isReadableFile(atPath: source.path) else {
                throw BundledRuntimeError.missingDXMT
            }
            try install(source, into: destinationRoot, fileManager: fileManager)
        }
        try Data(markerName.utf8).write(to: marker, options: .atomic)
    }

    /// Matches XOM's GraphicsInstaller replacement convention while keeping
    /// the copy atomic. The source is always a hash-locked bundled XOM file.
    private static func install(_ source: URL, into destinationRoot: URL,
                                fileManager: FileManager) throws {
        let destination = destinationRoot.appendingPathComponent(source.lastPathComponent)
        let old = destination.appendingPathExtension("old")
        if fileManager.fileExists(atPath: old.path) {
            try fileManager.removeItem(at: old)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: old)
        }
        let temporary = destinationRoot.appendingPathComponent(
            ".\(source.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            if !fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: old.path) {
                try? fileManager.moveItem(at: old, to: destination)
            }
            throw BundledRuntimeError.graphicsBackendInstallFailed(error.localizedDescription)
        }
    }
}
