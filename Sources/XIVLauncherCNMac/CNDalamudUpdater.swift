import CryptoKit
import Darwin
import Foundation

struct CNDalamudRelease: Codable, Equatable, Sendable {
    let version: String
    let baseURL: URL
    let hashesURL: URL
    let packageURL: URL
}

struct CNDalamudPreparedRelease: Equatable, Sendable {
    let release: CNDalamudRelease
    let directory: URL
    let injector: URL
    let runtimeVersion: String?

    init(release: CNDalamudRelease, directory: URL, injector: URL, runtimeVersion: String? = nil) {
        self.release = release
        self.directory = directory
        self.injector = injector
        self.runtimeVersion = runtimeVersion
    }
}

struct CNDalamudAssets: Equatable, Sendable {
    let version: String
    let directory: URL
}

private struct CNDalamudAssetManifest: Decodable {
    let version: Int
    let assets: [Asset]

    struct Asset: Decodable {
        let fileName: String
        let hash: String
        let url: String?

        enum CodingKeys: String, CodingKey {
            case fileName = "FileName"
            case hash = "Hash"
            case lowerFileName = "fileName"
            case lowerHash = "hash"
            case url
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try values.decodeIfPresent(String.self, forKey: .fileName) {
                fileName = value
            } else {
                fileName = try values.decode(String.self, forKey: .lowerFileName)
            }
            if let value = try values.decodeIfPresent(String.self, forKey: .hash) {
                hash = value
            } else {
                hash = try values.decode(String.self, forKey: .lowerHash)
            }
            url = try values.decodeIfPresent(String.self, forKey: .url)
        }
    }

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case assets = "Assets"
    }
}

private struct NormalCNDalamudVersionInfo: Decodable {
    let assemblyVersion: String
    let runtimeVersion: String?
    let runtimeRequired: Bool
    let downloadURL: URL
    let hash: String?

    enum CodingKeys: String, CodingKey {
        case assemblyVersion = "AssemblyVersion"
        case runtimeVersion = "RuntimeVersion"
        case runtimeRequired = "RuntimeRequired"
        case downloadURL = "DownloadUrl"
        case lowerDownloadURL = "downloadUrl"
        case hash = "Hash"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        assemblyVersion = try values.decode(String.self, forKey: .assemblyVersion)
        runtimeVersion = try values.decodeIfPresent(String.self, forKey: .runtimeVersion)
        runtimeRequired = try values.decode(Bool.self, forKey: .runtimeRequired)
        downloadURL = try values.decodeIfPresent(URL.self, forKey: .downloadURL)
            ?? values.decode(URL.self, forKey: .lowerDownloadURL)
        hash = try values.decodeIfPresent(String.self, forKey: .hash)
    }
}

private struct NormalCNDalamudAssetMeta: Decodable {
    let version: Int
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case assets = "Assets"
    }

    struct Asset: Decodable {
        let url: URL
        let fileName: String
        let hash: String

        enum CodingKeys: String, CodingKey {
            case url = "Url"
            case fileName = "FileName"
            case hash = "Hash"
        }
    }
}


/// CN Dalamud distribution client. It follows the same RELEASE + hashes.json
/// contract as the CN Windows launcher but never falls back to goatcorp URLs.
final class CNDalamudUpdater: @unchecked Sendable {
    private let session: URLSession
    private let endpoints: RegionEndpoints
    let variant: DalamudVariant

    // The normal CN metadata still pins the pre-2021 hash for this font while
    // its USTC URL now serves the current upstream Noto CJK build. Keep this
    // exception exact on path, stale hash, and replacement hash; every other
    // mismatch remains fatal. This mirrors a local compatibility patch rather
    // than disabling normal-CN asset verification.
    private static let normalFontCompatibility = (
        path: "UIRes/NotoSansCJKsc-Medium.otf",
        published: "C8AC9E680749BF31536971BC51DB257DDBAF3E68",
        replacement: "55A035F929EC089979A886AC98D92B3527B8FF38"
    )

    init(endpoints: RegionEndpoints = RegionEndpoints(), variant: DalamudVariant = .soil,
         session: URLSession? = nil) throws {
        self.endpoints = try endpoints.validated()
        guard variant != .disabled else { throw CNDalamudUpdateError.disabled }
        self.variant = variant
        self.session = session ?? CNNetworkSession.longDownloads()
    }

    static func activeVersion(in root: URL) -> String? {
        let active = root.appendingPathComponent("ACTIVE")
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: active.path) else { return nil }
        return URL(fileURLWithPath: destination).lastPathComponent
    }

    /// Interrupted downloads are never resumable. Remove only temporary
    /// staging/package data; active versions, plugins and configuration stay
    /// untouched until a complete replacement has passed validation.
    static func cleanupIncompleteArtifacts(in root: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name == "downloads" || name.hasPrefix("staging-") ||
                    name.hasPrefix("assets-staging-") else { continue }
            try? fileManager.removeItem(at: entry)
        }
        for directoryName in ["Hooks", "assets"] {
            let directory = root.appendingPathComponent(directoryName, isDirectory: true)
            CNDirectoryTransaction.recoverBackups(in: directory)
            guard let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for child in children where child.lastPathComponent.hasPrefix(".bootstrap-backup-") {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    private static func removeDownloadedPackage(_ package: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: package)
        let directory = package.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try? fileManager.removeItem(at: directory)
        }
    }

    static func activeAssetVersion(in root: URL) -> String? {
        let active = root.appendingPathComponent("assets/ACTIVE")
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: active.path) else { return nil }
        return URL(fileURLWithPath: destination).lastPathComponent
    }

    static func activeInstallationIsHealthy(in root: URL) -> Bool {
        guard activeVersion(in: root) != nil, activeAssetVersion(in: root) != nil else { return false }
        let core = root.appendingPathComponent("ACTIVE", isDirectory: true)
        let assets = root.appendingPathComponent("assets/ACTIVE", isDirectory: true)
        let requiredCore = ["Dalamud.Injector.exe", "Dalamud.dll", "ImGuiScene.dll"]
        guard requiredCore.allSatisfy({ FileManager.default.fileExists(atPath: core.appendingPathComponent($0).path) }),
              FileManager.default.fileExists(atPath: assets.path),
              let assetFiles = try? FileManager.default.contentsOfDirectory(atPath: assets.path),
              !assetFiles.isEmpty else { return false }
        return true
    }

    /// Lightweight UI/launch readiness check. Full directory validation is
    /// reserved for an explicit repair/check operation.
    static func activeInstallationIsReady(in root: URL) -> Bool {
        guard activeVersion(in: root) != nil, activeAssetVersion(in: root) != nil else { return false }
        let core = root.appendingPathComponent("ACTIVE", isDirectory: true)
        let assets = root.appendingPathComponent("assets/ACTIVE", isDirectory: true)
        let requiredCore = ["Dalamud.Injector.exe", "Dalamud.dll", "ImGuiScene.dll"]
        return requiredCore.allSatisfy { FileManager.default.isReadableFile(atPath: core.appendingPathComponent($0).path) } &&
            fileManagerReadableDirectory(assets)
    }

    private static func fileManagerReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func prepareLocalOrRemote(in root: URL, sevenZip: URL,
                              progress: ((CNDownloadProgress) -> Void)? = nil,
                              verifyExisting: Bool = false) async throws -> CNDalamudPreparedRelease {
        Self.cleanupIncompleteArtifacts(in: root)
        if variant == .china {
            return try await prepareNormalCNRelease(in: root, sevenZip: sevenZip, progress: progress,
                                                    verifyExisting: verifyExisting)
        }
        return try await prepareRelease(in: root, sevenZip: sevenZip,
                                        progress: progress, verifyExisting: verifyExisting)
    }

    /// The Atmo Dalamud fork treats PluginDistD17 as its main repository.
    /// Migrate the launcher's older third-repo entry without touching any
    /// unrelated repositories or user/plugin settings.
    static func configurePluginRepository(at configFile: URL) throws {
        try configurePluginRepository(at: configFile, variant: .soil)
    }

    static func configurePluginRepository(at configFile: URL, variant: DalamudVariant) throws {
        guard variant != .disabled else { return }
        let repository = variant == .china
            ? CNRegionProfile.normalCNDalamudPluginRepositoryURL
            : CNRegionProfile.dalamudPluginRepositoryURL
        let existingData = try? Data(contentsOf: configFile)
        var object: [String: Any] = [:]
        if let existingData,
           let decoded = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            object = decoded
        }
        let legacyRepositories = [
            "https://raw.githubusercontent.com/Dalamud-DailyRoutines/PluginDistD17/main/pluginmaster.json",
            repository
        ]
        let repositories = ((object["ThirdRepoList"] as? [[String: Any]]) ?? []).filter {
            guard let url = $0["Url"] as? String else { return true }
            return !legacyRepositories.contains(url)
        }
        object["MainRepoUrl"] = repository
        object["ThirdRepoList"] = repositories
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        if existingData == data { return }
        try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configFile, options: .atomic)
    }

    func fetchRelease() async throws -> CNDalamudRelease {
        if variant == .china { return try await fetchNormalCNRelease().release }
        guard let versionURL = URL(string: endpoints.dalamudVersionURL),
              let base = URL(string: endpoints.dalamudDistributionURL) else {
            throw CNDalamudUpdateError.invalidRelease
        }
        let (data, response) = try await session.data(from: versionURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.validRemoteVersion(version) else { throw CNDalamudUpdateError.invalidRelease }
        return CNDalamudRelease(version: version, baseURL: base,
                                 hashesURL: base.appendingPathComponent(version).appendingPathComponent("hashes.json"),
                                 packageURL: base.appendingPathComponent(version).appendingPathComponent("latest.7z"))
    }

    private func fetchNormalCNRelease() async throws -> (release: CNDalamudRelease, info: NormalCNDalamudVersionInfo) {
        guard let versionURL = URL(string: CNRegionProfile.normalCNDalamudVersionURL),
              let base = URL(string: CNRegionProfile.normalCNDalamudBaseURL) else {
            throw CNDalamudUpdateError.invalidRelease
        }
        var request = URLRequest(url: versionURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CNDalamudUpdateError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoder = JSONDecoder()
        let info: NormalCNDalamudVersionInfo
        do { info = try decoder.decode(NormalCNDalamudVersionInfo.self, from: data) }
        catch { throw CNDalamudUpdateError.invalidRelease }
        guard Self.validRemoteVersion(info.assemblyVersion),
              !info.runtimeRequired || (info.runtimeVersion.map(Self.validRemoteVersion) ?? false),
              Self.validNormalDownloadURL(info.downloadURL) else {
            throw CNDalamudUpdateError.invalidRelease
        }
        let release = CNDalamudRelease(
            version: info.assemblyVersion,
            baseURL: base,
            hashesURL: info.downloadURL.deletingLastPathComponent().appendingPathComponent("hashes.json"),
            packageURL: info.downloadURL
        )
        return (release, info)
    }

    private static func validNormalDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "aonyx.ffxiv.wang" || host == "s3.ffxiv.wang"
    }

    private func prepareNormalCNRelease(in root: URL, sevenZip: URL,
                                        progress: ((CNDownloadProgress) -> Void)?,
                                        verifyExisting: Bool) async throws -> CNDalamudPreparedRelease {
        guard FileManager.default.isExecutableFile(atPath: sevenZip.path) else {
            throw CNDalamudUpdateError.missingExtractor
        }
        let remote = try await fetchNormalCNRelease()
        let release = remote.release
        let final = root.appendingPathComponent("Hooks/\(release.version)", isDirectory: true)
        if FileManager.default.fileExists(atPath: final.path),
           try (!verifyExisting || Self.normalReleaseMatches(final, expectedHash: remote.info.hash)),
           Self.hasRequiredInjectorFiles(in: final) {
            try activate(root: root, version: release.version)
            return CNDalamudPreparedRelease(release: release, directory: final,
                                            injector: final.appendingPathComponent("Dalamud.Injector.exe"),
                                            runtimeVersion: remote.info.runtimeRequired ? remote.info.runtimeVersion : nil)
        }

        let staging = root.appendingPathComponent("staging-\(release.version)", isDirectory: true)
        let package = root.appendingPathComponent("downloads/\(release.version)-normal")
        defer { Self.removeDownloadedPackage(package) }
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        let started = Date()
        let downloader = CNStreamingDownloader(destination: package) { completed, total in
            progress?(CNDownloadProgress(phase: "正在下载 " + DalamudVariant.china.title,
                                         currentFile: release.packageURL.lastPathComponent,
                                         completedBytes: completed, totalBytes: max(0, total),
                                         bytesPerSecond: Double(completed) / max(0.1, Date().timeIntervalSince(started)),
                                         completedFiles: 0, totalFiles: 1))
        }
        try await downloader.download(url: release.packageURL)

        progress?(CNDownloadProgress(phase: "正在解压 " + DalamudVariant.china.title, currentFile: package.lastPathComponent,
                                     completedBytes: 0, totalBytes: 0, bytesPerSecond: 0,
                                     completedFiles: 0, totalFiles: 1))
        try await Self.extractArchive(package, to: staging, sevenZip: sevenZip)

        let extractedRoot = Self.requiredRoot(in: staging)
        guard Self.hasRequiredInjectorFiles(in: extractedRoot) else { throw CNDalamudUpdateError.missingInjector }
        guard let hashesData = try? Data(contentsOf: extractedRoot.appendingPathComponent("hashes.json")),
              let hashes = try? JSONDecoder().decode([String: String].self, from: hashesData),
              try Self.releaseMatches(extractedRoot, hashes: hashes) else {
            throw CNDalamudUpdateError.integrityMismatch
        }
        if let expectedHash = remote.info.hash, !expectedHash.isEmpty {
            let actual = Self.md5(hashesData)
            guard actual.caseInsensitiveCompare(expectedHash) == .orderedSame else {
                throw CNDalamudUpdateError.integrityMismatch
            }
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CNDirectoryTransaction.replace(staging: extractedRoot, final: final, validate: {
            guard Self.hasRequiredInjectorFiles(in: final) else { throw CNDalamudUpdateError.missingInjector }
        }, activate: {
            try self.activate(root: root, version: release.version)
        })
        if extractedRoot.path != staging.path { try? FileManager.default.removeItem(at: staging) }
        return CNDalamudPreparedRelease(release: release, directory: final,
                                        injector: final.appendingPathComponent("Dalamud.Injector.exe"),
                                        runtimeVersion: remote.info.runtimeRequired ? remote.info.runtimeVersion : nil)
    }

    private static func requiredRoot(in staging: URL) -> URL {
        if hasRequiredInjectorFiles(in: staging) { return staging }
        guard let children = try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey]),
              let first = children.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && hasRequiredInjectorFiles(in: $0) }) else {
            return staging
        }
        return first
    }

    private static func hasRequiredInjectorFiles(in directory: URL) -> Bool {
        ["Dalamud.Injector.exe", "Dalamud.dll", "ImGuiScene.dll", "hashes.json"]
            .allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    private static func normalReleaseMatches(_ directory: URL, expectedHash: String?) throws -> Bool {
        guard let hashesData = try? Data(contentsOf: directory.appendingPathComponent("hashes.json")),
              let hashes = try? JSONDecoder().decode([String: String].self, from: hashesData),
              try releaseMatches(directory, hashes: hashes) else { return false }
        guard let expectedHash, !expectedHash.isEmpty else { return true }
        return md5(hashesData).caseInsensitiveCompare(expectedHash) == .orderedSame
    }

    func downloadVerifiedRelease(to destination: URL,
                                 progress: ((CNDownloadProgress) -> Void)? = nil) async throws -> CNDalamudRelease {
        if variant == .china {
            let remote = try await fetchNormalCNRelease()
            try await download(release: remote.release, hashes: [:], to: destination, progress: progress)
            return remote.release
        }
        let release = try await fetchRelease()
        let hashes = try await fetchHashes(for: release)
        try await download(release: release, hashes: hashes, to: destination, progress: progress)
        return release
    }

    private func download(release: CNDalamudRelease, hashes: [String: String], to destination: URL,
                          progress: ((CNDownloadProgress) -> Void)?) async throws {
        let started = Date()
        let downloader = CNStreamingDownloader(destination: destination) { completed, total in
            let speed = Double(completed) / max(0.1, Date().timeIntervalSince(started))
            progress?(CNDownloadProgress(phase: "正在下载 " + self.variant.title, currentFile: release.packageURL.lastPathComponent,
                                         completedBytes: completed, totalBytes: max(0, total), bytesPerSecond: speed,
                                         completedFiles: 0, totalFiles: 1))
        }
        try await downloader.download(url: release.packageURL)
        // CN Dalamud hashes.json contains MD5 entries for extracted files. A
        // package-level entry is optional, so only enforce it when published;
        // extraction must still run the per-file hashes before activation.
        if let expected = hashes["latest.7z"] ?? hashes[release.packageURL.lastPathComponent] {
            let actual = try Self.md5(file: destination)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw CNDalamudUpdateError.integrityMismatch
            }
        }
    }

    func prepareRelease(in root: URL, sevenZip: URL,
                        progress: ((CNDownloadProgress) -> Void)? = nil,
                        verifyExisting: Bool = false) async throws -> CNDalamudPreparedRelease {
        guard FileManager.default.isExecutableFile(atPath: sevenZip.path) else { throw CNDalamudUpdateError.missingExtractor }
        let release = try await fetchRelease()
        let final = root.appendingPathComponent("Hooks/\(release.version)", isDirectory: true)
        if FileManager.default.fileExists(atPath: final.path),
           !verifyExisting,
           FileManager.default.fileExists(atPath: final.appendingPathComponent("Dalamud.Injector.exe").path) {
            try activate(root: root, version: release.version)
            return CNDalamudPreparedRelease(release: release, directory: final,
                                            injector: final.appendingPathComponent("Dalamud.Injector.exe"), runtimeVersion: nil)
        }
        let hashes = try await fetchHashes(for: release)
        if FileManager.default.fileExists(atPath: final.path),
           try Self.releaseMatches(final, hashes: hashes),
           FileManager.default.fileExists(atPath: final.appendingPathComponent("Dalamud.Injector.exe").path) {
            try activate(root: root, version: release.version)
            return CNDalamudPreparedRelease(release: release, directory: final,
                                            injector: final.appendingPathComponent("Dalamud.Injector.exe"), runtimeVersion: nil)
        }
        let staging = root.appendingPathComponent("staging-\(release.version)", isDirectory: true)
        let package = root.appendingPathComponent("downloads/\(release.version).7z")
        defer { Self.removeDownloadedPackage(package) }
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await download(release: release, hashes: hashes, to: package, progress: progress)
        progress?(CNDownloadProgress(phase: "正在解压 Dalamud Soil（土月）", currentFile: package.lastPathComponent,
                                     completedBytes: 0, totalBytes: 0, bytesPerSecond: 0,
                                     completedFiles: 0, totalFiles: hashes.count))
        try await Self.extractArchive(package, to: staging, sevenZip: sevenZip)

        for (relativePath, expected) in hashes {
            guard !relativePath.contains(".."), !relativePath.hasPrefix("/") else { throw CNDalamudUpdateError.invalidHashes }
            let file = staging.appendingPathComponent(relativePath.replacingOccurrences(of: "\\", with: "/"))
            guard FileManager.default.fileExists(atPath: file.path) else { throw CNDalamudUpdateError.integrityMismatch }
            let actual = try Self.md5(file: file)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else { throw CNDalamudUpdateError.integrityMismatch }
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CNDirectoryTransaction.replace(staging: staging, final: final, validate: {
            guard FileManager.default.fileExists(atPath: final.appendingPathComponent("Dalamud.Injector.exe").path) else {
                throw CNDalamudUpdateError.missingInjector
            }
        }, activate: {
            try self.activate(root: root, version: release.version)
        })
        let injector = final.appendingPathComponent("Dalamud.Injector.exe")
        return CNDalamudPreparedRelease(release: release, directory: final, injector: injector)
    }

    private func fetchHashes(for release: CNDalamudRelease) async throws -> [String: String] {
        let (data, response) = try await session.data(from: release.hashesURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let hashes = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw CNDalamudUpdateError.invalidHashes
        }
        return hashes
    }

    private static func releaseMatches(_ directory: URL, hashes: [String: String]) throws -> Bool {
        try hashes.allSatisfy { relativePath, expected in
            guard !relativePath.contains(".."), !relativePath.hasPrefix("/") else { return false }
            let file = directory.appendingPathComponent(relativePath.replacingOccurrences(of: "\\", with: "/"))
            let actual: String
            do { actual = try md5(file: file) }
            catch is CancellationError { throw CancellationError() }
            catch { return false }
            return actual.caseInsensitiveCompare(expected) == .orderedSame
        }
    }

    private func activate(root: URL, version: String) throws {
        let active = root.appendingPathComponent("ACTIVE")
        try Self.ensureSymbolicLink(at: active, destination: "Hooks/\(version)")
        Self.pruneVersionDirectories(in: root.appendingPathComponent("Hooks", isDirectory: true), keeping: version)
    }

    func prepareAssets(in root: URL, sevenZip: URL,
                       progress: ((CNDownloadProgress) -> Void)? = nil,
                       verifyExisting: Bool = false) async throws -> CNDalamudAssets {
        if variant == .china {
            return try await prepareNormalCNAssets(in: root, progress: progress,
                                                   verifyExisting: verifyExisting)
        }
        guard FileManager.default.isExecutableFile(atPath: sevenZip.path) else { throw CNDalamudUpdateError.missingExtractor }
        guard let versionURL = URL(string: endpoints.dalamudAssetVersionURL) else {
            throw CNDalamudUpdateError.invalidAssets
        }
        let (versionData, versionResponse) = try await session.data(from: versionURL)
        guard let versionHTTP = versionResponse as? HTTPURLResponse, (200..<300).contains(versionHTTP.statusCode),
              let version = String(data: versionData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.validRemoteVersion(version) else { throw CNDalamudUpdateError.invalidAssets }
        let final = root.appendingPathComponent("assets/\(version)", isDirectory: true)
        if FileManager.default.fileExists(atPath: final.path), !verifyExisting {
            try activateAssets(root: root, version: version)
            return CNDalamudAssets(version: version, directory: final)
        }
        guard let assetBase = URL(string: endpoints.dalamudAssetDistributionURL) else {
            throw CNDalamudUpdateError.invalidAssets
        }
        let manifestURL = assetBase.appendingPathComponent(version).appendingPathComponent("assetCN.json")
        let (manifestData, manifestResponse) = try await session.data(from: manifestURL)
        guard let manifestHTTP = manifestResponse as? HTTPURLResponse, (200..<300).contains(manifestHTTP.statusCode),
              let manifest = try? JSONDecoder().decode(CNDalamudAssetManifest.self, from: manifestData) else {
            throw CNDalamudUpdateError.invalidAssets
        }

        if FileManager.default.fileExists(atPath: final.path),
           try Self.assetsMatch(final, manifest: manifest) {
            try activateAssets(root: root, version: version)
            return CNDalamudAssets(version: version, directory: final)
        }
        let staging = root.appendingPathComponent("assets-staging-\(version)", isDirectory: true)
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (index, asset) in manifest.assets.enumerated() {
            guard Self.validRelativePath(asset.fileName) else { throw CNDalamudUpdateError.invalidAssets }
            let url = assetBase.appendingPathComponent(version).appendingPathComponent("files").appendingPathComponent(asset.fileName)
            let destination = staging.appendingPathComponent(asset.fileName)
            let started = Date()
            let downloader = CNStreamingDownloader(destination: destination) { completed, total in
                progress?(CNDownloadProgress(phase: "正在更新 Dalamud Assets", currentFile: asset.fileName,
                                             completedBytes: completed, totalBytes: max(0, total),
                                             bytesPerSecond: Double(completed) / max(0.1, Date().timeIntervalSince(started)),
                                             completedFiles: index, totalFiles: manifest.assets.count))
            }
            try await downloader.download(url: url)
            let actual = try Self.sha1(file: destination)
            guard actual.caseInsensitiveCompare(asset.hash) == .orderedSame else {
                throw CNDalamudUpdateError.integrityMismatch
            }
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CNDirectoryTransaction.replace(staging: staging, final: final, validate: {
            guard try Self.assetsMatch(final, manifest: manifest) else {
                throw CNDalamudUpdateError.integrityMismatch
            }
        }, activate: {
            try self.activateAssets(root: root, version: version)
        })
        return CNDalamudAssets(version: version, directory: final)
    }

    private func prepareNormalCNAssets(in root: URL,
                                       progress: ((CNDownloadProgress) -> Void)?,
                                       verifyExisting: Bool) async throws -> CNDalamudAssets {
        guard let metaURL = URL(string: CNRegionProfile.normalCNDalamudAssetMetaURL) else {
            throw CNDalamudUpdateError.invalidAssets
        }
        var request = URLRequest(url: metaURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CNDalamudUpdateError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let meta: NormalCNDalamudAssetMeta
        do { meta = try JSONDecoder().decode(NormalCNDalamudAssetMeta.self, from: data) }
        catch { throw CNDalamudUpdateError.invalidAssets }
        let version = String(meta.version)
        guard meta.version >= 0, Self.validRemoteVersion(version),
              meta.assets.allSatisfy({ Self.validRelativePath($0.fileName) && Self.validNormalAssetURL($0.url) }) else {
            throw CNDalamudUpdateError.invalidAssets
        }
        let final = root.appendingPathComponent("assets/\(version)", isDirectory: true)
        if FileManager.default.fileExists(atPath: final.path),
           try (!verifyExisting || Self.normalAssetsMatch(final, assets: meta.assets)) {
            try activateAssets(root: root, version: version)
            return CNDalamudAssets(version: version, directory: final)
        }
        let staging = root.appendingPathComponent("assets-staging-\(version)", isDirectory: true)
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (index, asset) in meta.assets.enumerated() {
            let destination = staging.appendingPathComponent(asset.fileName)
            let started = Date()
            let downloader = CNStreamingDownloader(destination: destination) { completed, total in
                progress?(CNDownloadProgress(phase: "正在更新 " + DalamudVariant.china.title + " Assets",
                                             currentFile: asset.fileName,
                                             completedBytes: completed, totalBytes: max(0, total),
                                             bytesPerSecond: Double(completed) / max(0.1, Date().timeIntervalSince(started)),
                                             completedFiles: index, totalFiles: meta.assets.count))
            }
            try await downloader.download(url: asset.url)
            let actual = try Self.sha1(file: destination)
            guard Self.normalAssetHashMatches(fileName: asset.fileName,
                                              publishedHash: asset.hash,
                                              actualHash: actual) else {
                throw CNDalamudUpdateError.integrityMismatch
            }
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CNDirectoryTransaction.replace(staging: staging, final: final, validate: {
            guard try Self.normalAssetsMatch(final, assets: meta.assets) else {
                throw CNDalamudUpdateError.integrityMismatch
            }
        }, activate: {
            try self.activateAssets(root: root, version: version)
        })
        return CNDalamudAssets(version: version, directory: final)
    }

    private static func validNormalAssetURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "aonyx.ffxiv.wang" || host == "s3.ffxiv.wang" || host.hasSuffix(".aliyun.com") ||
            host.hasSuffix(".edu.cn") || host.hasSuffix(".com.cn")
    }

    private static func normalAssetsMatch(_ directory: URL, assets: [NormalCNDalamudAssetMeta.Asset]) throws -> Bool {
        try assets.allSatisfy { asset in
            let actual: String
            do { actual = try sha1(file: directory.appendingPathComponent(asset.fileName)) }
            catch is CancellationError { throw CancellationError() }
            catch { return false }
            return normalAssetHashMatches(fileName: asset.fileName,
                                          publishedHash: asset.hash,
                                          actualHash: actual)
        }
    }

    static func normalAssetHashMatches(fileName: String, publishedHash: String,
                                       actualHash: String) -> Bool {
        if actualHash.caseInsensitiveCompare(publishedHash) == .orderedSame { return true }
        let compatibility = normalFontCompatibility
        return fileName == compatibility.path &&
            publishedHash.caseInsensitiveCompare(compatibility.published) == .orderedSame &&
            actualHash.caseInsensitiveCompare(compatibility.replacement) == .orderedSame
    }

    private func activateAssets(root: URL, version: String) throws {
        let active = root.appendingPathComponent("assets/ACTIVE")
        try Self.ensureSymbolicLink(at: active, destination: version)
        Self.pruneVersionDirectories(in: root.appendingPathComponent("assets", isDirectory: true), keeping: version)
    }

    @discardableResult
    static func ensureSymbolicLink(at link: URL, destination: String) throws -> Bool {
        let fileManager = FileManager.default
        let currentDestination = try? fileManager.destinationOfSymbolicLink(atPath: link.path)
        if currentDestination == destination { return false }
        if currentDestination == nil, fileManager.fileExists(atPath: link.path) {
            try fileManager.removeItem(at: link)
        }
        try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = link.deletingLastPathComponent()
            .appendingPathComponent(".active-link-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createSymbolicLink(atPath: temporary.path, withDestinationPath: destination)
        let result = temporary.path.withCString { source in
            link.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    static func pruneVersionDirectories(in directory: URL, keeping version: String) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name != version, name != "ACTIVE", !name.hasPrefix(".") else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func validRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("..") && !value.contains("\\")
    }

    private static func validRemoteVersion(_ value: String) -> Bool {
        !value.isEmpty && value.count < 100 && !value.contains("..") &&
        value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    private static func assetsMatch(_ directory: URL, manifest: CNDalamudAssetManifest) throws -> Bool {
        try manifest.assets.allSatisfy { asset in
            let file = directory.appendingPathComponent(asset.fileName)
            let actual: String
            do { actual = try sha1(file: file) }
            catch is CancellationError { throw CancellationError() }
            catch { return false }
            return actual.caseInsensitiveCompare(asset.hash) == .orderedSame
        }
    }

    private static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func md5(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = Insecure.MD5()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha1(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = Insecure.SHA1()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func extractArchive(_ archive: URL, to destination: URL, sevenZip: URL) async throws {
        let status = try await CNCancellableProcess.run(
            executableURL: sevenZip,
            arguments: ["x", archive.path, "-o\(destination.path)", "-y"]
        )
        guard status == 0 else { throw CNDalamudUpdateError.extractFailed }
        try Task.checkCancellation()
    }

}
enum CNDalamudUpdateError: LocalizedError {
    case disabled, invalidRelease, invalidHashes, invalidAssets, integrityMismatch, httpStatus(Int), missingExtractor, extractFailed, missingInjector
    var errorDescription: String? {
        switch self {
        case .disabled: return "当前已选择不启用 Dalamud，因此不会访问 Dalamud 更新源。"
        case .invalidRelease: return "当前 Dalamud 发行源返回了无效版本。"
        case .invalidHashes: return "当前 Dalamud 完整性清单无效。"
        case .invalidAssets: return "当前 Dalamud 资源清单无效。"
        case .integrityMismatch: return "Dalamud 下载包校验失败。"
        case .httpStatus(let code): return "Dalamud 发行源返回 HTTP \(code)。"
        case .missingExtractor: return "缺少内置 7z 解压器，无法安装 Dalamud。"
        case .extractFailed: return "Dalamud 解压失败。"
        case .missingInjector: return "Dalamud 包缺少 Injector 或必要文件。"
        }
    }
}
