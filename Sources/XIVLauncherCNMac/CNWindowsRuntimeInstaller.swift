import Foundation

/// Installs the win-x64 .NET runtimes required by the CN Dalamud Injector.
/// These are Windows binaries loaded by Wine, not runtimes for the Swift app.
final class CNWindowsRuntimeInstaller {
    private let session: URLSession
    private let paths: ManagedPaths
    private let runtimeInfoURL = URL(string: "https://gh.atmoomen.top/https://raw.githubusercontent.com/Dalamud-DailyRoutines/XLCNSoilAssets/master/runtimeInfo")!
    private let packageBaseURL = "https://repo.huaweicloud.com/artifactory/api/nuget/v3/nuget-remote"

    init(paths: ManagedPaths, session: URLSession? = nil) {
        self.paths = paths; self.session = session ?? CNNetworkSession.longDownloads()
    }

    static func installedVersion(paths: ManagedPaths, variant: DalamudVariant) -> String? {
        guard variant != .disabled else { return nil }
        let versionFile = paths.dalamudRoot(for: variant).appendingPathComponent("runtime.version")
        guard let version = try? String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              validVersion(version) else { return nil }
        let root = paths.dalamudRuntime(for: variant)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("host/fxr/\(version)/hostfxr.dll").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("shared/Microsoft.NETCore.App/\(version)/System.Private.CoreLib.dll").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("shared/Microsoft.WindowsDesktop.App/\(version)/WindowsBase.dll").path) else {
            return nil
        }
        return version
    }

    func installRequiredRuntime(variant: DalamudVariant = .soil,
                                requiredVersion: String? = nil,
                                progress: ((CNDownloadProgress) -> Void)? = nil) async throws {
        guard variant != .disabled else { return }
        try Task.checkCancellation()
        let downloadCache = paths.caches.appendingPathComponent("dotnet/\(variant.rawValue)", isDirectory: true)
        if FileManager.default.fileExists(atPath: downloadCache.path) {
            try FileManager.default.removeItem(at: downloadCache)
        }
        defer { try? FileManager.default.removeItem(at: downloadCache) }
        let target: String
        if let requiredVersion {
            guard Self.validVersion(requiredVersion) else { throw CNWindowsRuntimeError.invalidVersion }
            target = requiredVersion
        } else if variant == .china {
            throw CNWindowsRuntimeError.invalidVersion
        } else {
            target = try await fetchVersion()
        }
        try recoverInterruptedReplacement(version: target, variant: variant)
        if isReady(version: target, variant: variant) {
            try writeRuntimeVersionIfNeeded(target, variant: variant)
            return
        }

        guard let coreURL = URL(string: "\(packageBaseURL)/microsoft.netcore.app.runtime.win-x64/\(target)/microsoft.netcore.app.runtime.win-x64.\(target).nupkg"),
              let desktopURL = URL(string: "\(packageBaseURL)/microsoft.windowsdesktop.app.runtime.win-x64/\(target)/microsoft.windowsdesktop.app.runtime.win-x64.\(target).nupkg") else {
            throw CNWindowsRuntimeError.invalidVersion
        }
        let corePackage = try await download(coreURL, name: "Microsoft.NETCore.App \(target)",
                                             variant: variant, progress: progress)
        let desktopPackage = try await download(desktopURL, name: "Microsoft.WindowsDesktop.App \(target)",
                                                variant: variant, progress: progress)
        try await install(corePackage: corePackage, desktopPackage: desktopPackage, version: target, variant: variant)
    }

    private func download(_ url: URL, name: String, variant: DalamudVariant,
                          progress: ((CNDownloadProgress) -> Void)?) async throws -> URL {
        let destination = paths.caches.appendingPathComponent("dotnet/\(variant.rawValue)/\(url.lastPathComponent)")
        let started = Date()
        let downloader = CNStreamingDownloader(destination: destination) { completed, total in
            progress?(CNDownloadProgress(phase: "正在更新 \(variant.title) Runtime", currentFile: name,
                                         completedBytes: completed, totalBytes: max(0, total),
                                         bytesPerSecond: Double(completed) / max(0.1, Date().timeIntervalSince(started)),
                                         completedFiles: 0, totalFiles: 2))
        }
        try await downloader.download(url: url)
        return destination
    }

    private func fetchVersion() async throws -> String {
        let (data, response) = try await session.data(from: runtimeInfoURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.validVersion(value) else { throw CNWindowsRuntimeError.invalidVersion }
        return value
    }

    private static func validVersion(_ value: String) -> Bool {
        !value.isEmpty && value.count < 100 && !value.contains("..") &&
        value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    private func isReady(version: String, variant: DalamudVariant) -> Bool {
        let root = paths.dalamudRuntime(for: variant)
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("host/fxr/\(version)/hostfxr.dll").path) &&
            FileManager.default.fileExists(atPath: root.appendingPathComponent("shared/Microsoft.NETCore.App/\(version)/System.Private.CoreLib.dll").path) &&
            FileManager.default.fileExists(atPath: root.appendingPathComponent("shared/Microsoft.WindowsDesktop.App/\(version)/WindowsBase.dll").path)
    }

    private func install(corePackage: URL, desktopPackage: URL, version: String,
                         variant: DalamudVariant) async throws {
        let majorVersion = version.split(separator: ".").first.map(String.init) ?? "10"
        let variantRoot = paths.dalamudRoot(for: variant)
        let staging = variantRoot.appendingPathComponent("runtime-staging-\(version)", isDirectory: true)
        let root = paths.dalamudRuntime(for: variant)
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let extractedCore = staging.appendingPathComponent("package-core", isDirectory: true)
        let extractedDesktop = staging.appendingPathComponent("package-desktop", isDirectory: true)
        try await extract(package: corePackage, into: extractedCore, framework: "net\(majorVersion).0")
        try await extract(package: desktopPackage, into: extractedDesktop, framework: "net\(majorVersion).0")

        let targetManaged = staging.appendingPathComponent("shared/Microsoft.NETCore.App/\(version)")
        let targetDesktop = staging.appendingPathComponent("shared/Microsoft.WindowsDesktop.App/\(version)")
        let targetHost = staging.appendingPathComponent("host/fxr/\(version)")
        try copyTreeContents(from: extractedCore.appendingPathComponent("runtimes/win-x64/native"), to: targetManaged)
        try copyTreeContents(from: extractedCore.appendingPathComponent("runtimes/win-x64/lib/net\(majorVersion).0"), to: targetManaged)
        try copyTreeContents(from: extractedDesktop.appendingPathComponent("runtimes/win-x64/native"), to: targetDesktop)
        try copyTreeContents(from: extractedDesktop.appendingPathComponent("runtimes/win-x64/lib/net\(majorVersion).0"), to: targetDesktop)
        try FileManager.default.createDirectory(at: targetHost, withIntermediateDirectories: true)
        let hostfxr = targetManaged.appendingPathComponent("hostfxr.dll")
        guard FileManager.default.fileExists(atPath: hostfxr.path) else { throw CNWindowsRuntimeError.extractFailed }
        try FileManager.default.copyItem(at: hostfxr, to: targetHost.appendingPathComponent("hostfxr.dll"))
        try FileManager.default.removeItem(at: extractedCore)
        try FileManager.default.removeItem(at: extractedDesktop)

        guard FileManager.default.fileExists(atPath: targetManaged.appendingPathComponent("System.Private.CoreLib.dll").path),
              FileManager.default.fileExists(atPath: targetDesktop.appendingPathComponent("WindowsBase.dll").path) else {
            throw CNWindowsRuntimeError.extractFailed
        }
        try Task.checkCancellation()
        try CNDirectoryTransaction.replace(staging: staging, final: root, validate: {
            guard isReady(version: version, variant: variant) else { throw CNWindowsRuntimeError.extractFailed }
        }, activate: {
            try writeRuntimeVersionIfNeeded(version, variant: variant)
        })
    }

    private func recoverInterruptedReplacement(version: String, variant: DalamudVariant) throws {
        let root = paths.dalamudRuntime(for: variant)
        let legacyBackup = paths.dalamudRoot(for: variant)
            .appendingPathComponent("runtime-backup", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyBackup.path) {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: legacyBackup)
            } else {
                try FileManager.default.moveItem(at: legacyBackup, to: root)
            }
        }
        let backup = CNDirectoryTransaction.backupURL(for: root)
        try CNDirectoryTransaction.recover(final: root, backup: backup) {
            self.isReady(version: version, variant: variant)
        }
    }

    private func writeRuntimeVersionIfNeeded(_ version: String, variant: DalamudVariant) throws {
        let versionFile = paths.dalamudRoot(for: variant).appendingPathComponent("runtime.version")
        let installed = try? String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard installed != version else { return }
        try version.write(to: versionFile, atomically: true, encoding: .utf8)
    }

    private func extract(package: URL, into destination: URL, framework: String) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let status = try await CNCancellableProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-q", "-o", package.path, "runtimes/win-x64/native/*",
                        "runtimes/win-x64/lib/\(framework)/*", "-d", destination.path]
        )
        guard status == 0 else { throw CNWindowsRuntimeError.extractFailed }
        try Task.checkCancellation()
    }

    private func copyTreeContents(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw CNWindowsRuntimeError.extractFailed
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for case let item as URL in enumerator {
            try Task.checkCancellation()
            let relativePath = String(item.path.dropFirst(source.path.count + 1))
            guard !relativePath.isEmpty else { continue }
            let target = destination.appendingPathComponent(relativePath)
            let isDirectory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            if isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                try fileManager.copyItem(at: item, to: target)
            }
        }
    }
}

enum CNWindowsRuntimeError: LocalizedError {
    case invalidVersion, httpStatus(Int), extractFailed
    var errorDescription: String? {
        switch self {
        case .invalidVersion: return "国服 Dalamud .NET Runtime 版本信息无效。"
        case .httpStatus(let code): return "国服 Dalamud .NET Runtime 下载返回 HTTP \(code)。"
        case .extractFailed: return "国服 Dalamud .NET Runtime 解压或完整性验证失败。"
        }
    }
}
