import Foundation
import CryptoKit

struct CNGameRemoteVersion: Codable, Equatable {
    let baseURL: String
    let backupBaseURL: String
    let areas: [CNGameVersionArea]
    let packages: [CNGameVersionPackage]

    enum CodingKeys: String, CodingKey { case baseURL = "baseUrl", backupBaseURL = "backupBaseUrl", areas, packages }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        backupBaseURL = try values.decodeIfPresent(String.self, forKey: .backupBaseURL) ?? ""
        areas = try values.decode([CNGameVersionArea].self, forKey: .areas)
        packages = try values.decode([CNGameVersionPackage].self, forKey: .packages)
    }
}

struct CNGameVersionArea: Codable, Equatable {
    let id: String
    let max: String
    let min: String
    let must: String
    let back: String
    let view: String?

    enum CodingKeys: String, CodingKey { case id, max, min, must, back, view }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        max = try values.decode(String.self, forKey: .max)
        min = try values.decode(String.self, forKey: .min)
        must = try values.decode(String.self, forKey: .must)
        back = try values.decodeIfPresent(String.self, forKey: .back) ?? ""
        view = try values.decodeIfPresent(String.self, forKey: .view)
    }
}

struct CNGameVersionPackage: Codable, Equatable {
    let fileListURL: String
    let forceType: Int
    let from: String
    let md5: String
    let name: String
    let to: String
    let versionView: String

    enum CodingKeys: String, CodingKey {
        case fileListURL = "fileListUrl", forceType = "forcetype", from, md5, name, to, versionView
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fileListURL = try values.decode(String.self, forKey: .fileListURL)
        forceType = try values.decodeIfPresent(Int.self, forKey: .forceType) ?? 0
        from = try values.decode(String.self, forKey: .from)
        md5 = try values.decodeIfPresent(String.self, forKey: .md5) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        to = try values.decode(String.self, forKey: .to)
        versionView = try values.decodeIfPresent(String.self, forKey: .versionView) ?? ""
    }
}

struct CNGameUpdatePlan: Equatable {
    let baseURL: URL
    let backupBaseURL: URL?
    let currentGameVersion: String
    let currentDataVersion: String
    let targetDataVersion: String
    let targetGameVersion: String
    let packages: [CNGameVersionPackage]
}

struct CNGamePackageFileList: Codable, Equatable {
    let baseURL: String
    let backupBaseURL: String
    let fileList: [CNGamePackageFile]

    enum CodingKeys: String, CodingKey { case baseURL = "baseUrl", backupBaseURL = "backupBaseUrl", fileList = "fileList" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        backupBaseURL = try values.decodeIfPresent(String.self, forKey: .backupBaseURL) ?? ""
        fileList = try values.decode([CNGamePackageFile].self, forKey: .fileList)
    }
}

struct CNGamePackageFile: Codable, Equatable {
    let url: String
    let path: String
    let md5: String
    let size: Int64

    enum CodingKeys: String, CodingKey { case url, path, md5, size }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(String.self, forKey: .url)
        path = try values.decode(String.self, forKey: .path)
        md5 = try values.decode(String.self, forKey: .md5)
        if let number = try? values.decode(Int64.self, forKey: .size) {
            size = number
        } else {
            size = Int64(try values.decode(String.self, forKey: .size)) ?? 0
        }
    }
}

struct CNIntegrityManifest: Equatable {
    let appID: String
    let baseURL: URL
    let dataVersion: String
    let files: [String: CNIntegrityFile]
}

struct CNIntegrityFile: Equatable {
    let size: Int64
    let md5: String
}

struct CNIntegrityScanResult: Equatable {
    let valid: [String]
    let missingOrCorrupt: [String]
}

struct CNGameUpdateDescriptor: Equatable {
    let targetDataVersion: String
    let targetGameVersion: String
    let manifest: CNIntegrityManifest
}

/// CN V3 metadata and full-file fallback updater. Delta packages are parsed
/// and verified, while macOS installs use the official integrity CDN when a
/// VCDIFF merge runtime is unavailable.
final class CNGameUpdateClient: @unchecked Sendable {
    private let session: URLSession
    private let endpoints: RegionEndpoints

    init(endpoints: RegionEndpoints = RegionEndpoints(), session: URLSession? = nil) throws {
        self.endpoints = try endpoints.validated()
        self.session = session ?? CNNetworkSession.longDownloads()
    }

    func fetchRemoteVersion() async throws -> CNGameRemoteVersion {
        guard let url = URL(string: "\(endpoints.contentConfigURL)/build/ver2data/\(endpoints.gameAppID)/\(endpoints.branchID)/-1/ver2.dat") else {
            throw CNUpdateError.invalidRemoteVersion
        }
        let data = try await fetch(url)
        do { return try JSONDecoder().decode(CNGameRemoteVersion.self, from: data) }
        catch { throw CNUpdateError.invalidRemoteVersion }
    }

    func buildUpdatePlan(currentGameVersion: String, force: Bool = false) async throws -> CNGameUpdatePlan? {
        let remote = try await fetchRemoteVersion()
        guard let target = remote.areas.first(where: { $0.id == "0" }) ?? remote.areas.first,
              let baseURL = URL(string: remote.baseURL) else { throw CNUpdateError.invalidRemoteVersion }
        let current = Self.resolveDataVersion(gameVersion: currentGameVersion, remote: remote)
        guard !current.isEmpty else { throw CNUpdateError.unsupportedGameVersion(currentGameVersion) }
        if !force && current == target.must { return nil }
        let packages = try Self.findPackagePath(remote.packages, from: current, to: target.must)
        let gameVersion = Self.resolveGameVersion(dataVersion: target.must, remote: remote)
        guard !gameVersion.isEmpty else { throw CNUpdateError.invalidRemoteVersion }
        return CNGameUpdatePlan(baseURL: baseURL, backupBaseURL: URL(string: remote.backupBaseURL),
                                currentGameVersion: currentGameVersion,
                                currentDataVersion: current, targetDataVersion: target.must,
                                targetGameVersion: gameVersion, packages: packages)
    }

    func fetchPackageFileList(_ package: CNGameVersionPackage, plan: CNGameUpdatePlan) async throws -> CNGamePackageFileList {
        let primary = try Self.resolveURL(package.fileListURL, relativeTo: plan.baseURL)
        do {
            let signed = try Self.signedURL(primary)
            return try JSONDecoder().decode(CNGamePackageFileList.self, from: await fetch(signed))
        }
        catch {
            guard let backup = plan.backupBaseURL else { throw CNUpdateError.invalidPackageList }
            let backupURL = try Self.resolveURL(package.fileListURL, relativeTo: backup)
            do {
                let signed = try Self.signedURL(backupURL)
                return try JSONDecoder().decode(CNGamePackageFileList.self, from: await fetch(signed))
            }
            catch { throw CNUpdateError.invalidPackageList }
        }
    }

    func fetchIntegrityManifest() async throws -> CNIntegrityManifest {
        guard let url = URL(string: "\(endpoints.contentConfigURL)/build/\(endpoints.gameAppID)/\(endpoints.branchID)/client-all-files-list/client_all_files_list.dat") else {
            throw CNUpdateError.invalidManifest
        }
        let data = try await fetch(url)
        guard let text = String(data: data, encoding: .utf8) else { throw CNUpdateError.invalidManifest }
        let manifest = try Self.parseIntegrityManifest(text)
        guard manifest.appID == endpoints.gameAppID,
              CNRegionProfile.isCNURL(manifest.baseURL.absoluteString) else {
            throw CNUpdateError.invalidManifest
        }
        return manifest
    }

    /// Fetches version metadata and the integrity manifest as one coherent
    /// snapshot. If the publisher changes versions between the two requests,
    /// the caller retries instead of assigning a version to the wrong files.
    func fetchLatestUpdate() async throws -> CNGameUpdateDescriptor {
        let remote = try await fetchRemoteVersion()
        guard let target = remote.areas.first(where: { $0.id == "0" }) ?? remote.areas.first else {
            throw CNUpdateError.invalidRemoteVersion
        }
        let gameVersion = Self.resolveGameVersion(dataVersion: target.must, remote: remote)
        guard !gameVersion.isEmpty else { throw CNUpdateError.invalidRemoteVersion }
        let manifest = try await fetchIntegrityManifest()
        guard manifest.dataVersion == target.must else { throw CNUpdateError.metadataChanged }
        return CNGameUpdateDescriptor(targetDataVersion: target.must,
                                      targetGameVersion: gameVersion,
                                      manifest: manifest)
    }

    func scan(gameRoot: URL, manifest: CNIntegrityManifest,
              progress: ((Int, Int, String) -> Void)? = nil) throws -> CNIntegrityScanResult {
        var valid: [String] = []
        var invalid: [String] = []
        var lastProgressDate = Date.distantPast
        let entries = manifest.files.sorted(by: { $0.key < $1.key })
        for (index, entry) in entries.enumerated() {
            try Task<Never, Never>.checkCancellation()
            let (path, expected) = entry
            let now = Date()
            if now.timeIntervalSince(lastProgressDate) >= 0.1 {
                lastProgressDate = now
                progress?(index, entries.count, path)
            }
            let file = gameRoot.appendingPathComponent(path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  (attributes[.size] as? NSNumber)?.int64Value == expected.size,
                  let handle = try? FileHandle(forReadingFrom: file) else { invalid.append(path); continue }
            defer { try? handle.close() }
            let digest = try Self.md5(handle: handle)
            digest.caseInsensitiveCompare(expected.md5) == .orderedSame ? valid.append(path) : invalid.append(path)
        }
        progress?(entries.count, entries.count, "")
        return CNIntegrityScanResult(valid: valid, missingOrCorrupt: invalid)
    }

    func repair(gameRoot: URL, manifest: CNIntegrityManifest,
                progress: ((CNDownloadProgress) -> Void)? = nil) async throws {
        let scanTask = Task.detached(priority: .utility) { [self] in
            try scan(gameRoot: gameRoot, manifest: manifest) { index, count, path in
                progress?(CNDownloadProgress(phase: "正在校验", currentFile: path,
                                             completedBytes: 0, totalBytes: 0,
                                             bytesPerSecond: 0, completedFiles: index, totalFiles: count))
            }
        }
        let scanResult = try await withTaskCancellationHandler(operation: {
            try await scanTask.value
        }, onCancel: {
            scanTask.cancel()
        })
        let total = scanResult.missingOrCorrupt.reduce(Int64(0)) { result, path in
            result + (manifest.files[path]?.size ?? 0)
        }
        var missingBytes: Int64 = 0
        var replacementBytes: Int64 = 0
        for path in scanResult.missingOrCorrupt {
            let size = manifest.files[path]?.size ?? 0
            if FileManager.default.fileExists(atPath: gameRoot.appendingPathComponent(path).path) {
                replacementBytes = max(replacementBytes, size)
            } else {
                missingBytes += size
            }
        }
        try Self.checkDiskSpace(for: missingBytes + replacementBytes, at: gameRoot)
        var completed: Int64 = 0
        let started = Date()
        for (index, path) in scanResult.missingOrCorrupt.enumerated() {
            let fileSize = manifest.files[path]?.size ?? 0
            try Task.checkCancellation()
            try await download(file: path, from: manifest, to: gameRoot.appendingPathComponent(path)) { fileBytes, _ in
                let elapsed = max(0.1, Date().timeIntervalSince(started))
                progress?(CNDownloadProgress(phase: "正在下载", currentFile: path,
                                             completedBytes: min(total, completed + fileBytes), totalBytes: total,
                                             bytesPerSecond: Double(completed + fileBytes) / elapsed,
                                             completedFiles: index,
                                             totalFiles: scanResult.missingOrCorrupt.count))
            }
            completed += fileSize
            progress?(CNDownloadProgress(phase: "正在安装", currentFile: path,
                                         completedBytes: completed, totalBytes: total,
                                         bytesPerSecond: Double(completed) / max(0.1, Date().timeIntervalSince(started)),
                                         completedFiles: index + 1,
                                         totalFiles: scanResult.missingOrCorrupt.count))
        }
        progress?(CNDownloadProgress(phase: "完成", currentFile: "", completedBytes: total,
                                     totalBytes: total, bytesPerSecond: 0,
                                     completedFiles: scanResult.missingOrCorrupt.count,
                                     totalFiles: scanResult.missingOrCorrupt.count))
    }

    func download(file relativePath: String, from manifest: CNIntegrityManifest, to destination: URL,
                  progress: ((Int64, Int64) -> Void)? = nil) async throws {
        guard let file = manifest.files[relativePath] else { throw CNUpdateError.fileNotInManifest }
        let normalizedPath = try Self.normalizePath(relativePath)
        let temporary = destination.appendingPathExtension("xivcn-download")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try await downloadStream(try Self.signedCDNURL(for: normalizedPath, manifest: manifest),
                                     to: temporary, progress: progress)
        } catch {
            try Task.checkCancellation()
            // Some CN mirrors expose the integrity base as a plain CDN path;
            // retain the signed request as the primary path and only use the
            // documented base URL as a compatibility fallback.
            try await downloadStream(manifest.baseURL.appendingPathComponent(normalizedPath),
                                     to: temporary, progress: progress)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        guard size == file.size,
              try Self.md5(handle: handle).caseInsensitiveCompare(file.md5) == .orderedSame else {
            try? FileManager.default.removeItem(at: temporary)
            throw CNUpdateError.integrityMismatch(relativePath)
        }
        try Self.activateDownloadedFile(temporary, at: destination)
    }

    func latestGameVersion() async throws -> String {
        let remote = try await fetchRemoteVersion()
        guard let target = remote.areas.first(where: { $0.id == "0" }) ?? remote.areas.first else {
            throw CNUpdateError.invalidRemoteVersion
        }
        let version = Self.resolveGameVersion(dataVersion: target.must, remote: remote)
        guard !version.isEmpty else { throw CNUpdateError.invalidRemoteVersion }
        return version
    }

    static func parseIntegrityManifest(_ text: String) throws -> CNIntegrityManifest {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace })
        guard let header = lines.first?.split(separator: "|"), header.count >= 3,
              let baseURL = URL(string: String(header[0])) else { throw CNUpdateError.invalidManifest }
        var files: [String: CNIntegrityFile] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 3, let size = Int64(parts[1]), !parts[2].isEmpty,
                  let path = try? normalizePath(String(parts[0])) else { continue }
            files[path] = CNIntegrityFile(size: size, md5: String(parts[2]))
        }
        guard !files.isEmpty else { throw CNUpdateError.invalidManifest }
        return CNIntegrityManifest(appID: String(header[1]), baseURL: baseURL, dataVersion: String(header[2]), files: files)
    }

    static func resolveDataVersion(gameVersion: String, remote: CNGameRemoteVersion) -> String {
        let normalized = normalizeVersionView(gameVersion)
        return remote.packages.first { normalizeVersionView($0.versionView) == normalized }?.to ?? ""
    }

    static func resolveGameVersion(dataVersion: String, remote: CNGameRemoteVersion) -> String {
        if let package = remote.packages.first(where: { $0.to == dataVersion }) { return normalizeVersionView(package.versionView) }
        return normalizeVersionView(remote.areas.first(where: { $0.must == dataVersion || $0.max == dataVersion })?.view ?? "")
    }

    static func findPackagePath(_ packages: [CNGameVersionPackage], from: String, to: String) throws -> [CNGameVersionPackage] {
        if from == to { return [] }
        var queue = [from]
        var visited: Set<String> = [from]
        var predecessors: [String: (String, CNGameVersionPackage)] = [:]
        while !queue.isEmpty {
            let version = queue.removeFirst()
            for package in packages where package.from == version && !package.to.isEmpty && !visited.contains(package.to) {
                visited.insert(package.to)
                predecessors[package.to] = (version, package)
                if package.to == to {
                    var path: [CNGameVersionPackage] = []
                    var cursor = to
                    while cursor != from {
                        guard let predecessor = predecessors[cursor] else { throw CNUpdateError.missingUpdatePath(from, to) }
                        path.append(predecessor.1); cursor = predecessor.0
                    }
                    return path.reversed()
                }
                queue.append(package.to)
            }
        }
        throw CNUpdateError.missingUpdatePath(from, to)
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CNUpdateError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    private func downloadStream(_ url: URL, to destination: URL,
                                progress: ((Int64, Int64) -> Void)?) async throws {
        let downloader = CNStreamingDownloader(destination: destination, progress: progress)
        try await downloader.download(url: url)
    }

    private static func checkDiskSpace(for bytes: Int64, at root: URL) throws {
        guard bytes > 0 else { return }
        let probe = FileManager.default.fileExists(atPath: root.path) ? root : root.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        let reserve: Int64 = 512 * 1024 * 1024
        guard available >= bytes + reserve else { throw CNUpdateError.insufficientDiskSpace(bytes + reserve, available) }
    }

    /// Activates one verified file without exposing a delete-before-move gap.
    /// If activation fails, the previous Managed or External game file is put
    /// back before the error reaches the UI.
    static func activateDownloadedFile(_ temporary: URL, at destination: URL,
                                       fileManager: FileManager = .default) throws {
        let backup = destination.appendingPathExtension("xivcn-backup")
        if fileManager.fileExists(atPath: backup.path) {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: backup)
            } else {
                try fileManager.moveItem(at: backup, to: destination)
            }
        }
        let hadDestination = fileManager.fileExists(atPath: destination.path)
        if hadDestination { try fileManager.moveItem(at: destination, to: backup) }
        do {
            try fileManager.moveItem(at: temporary, to: destination)
            if hadDestination { try? fileManager.removeItem(at: backup) }
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if hadDestination, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private static func resolveURL(_ value: String, relativeTo base: URL) throws -> URL {
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        guard let resolved = URL(string: value, relativeTo: base)?.absoluteURL else { throw CNUpdateError.invalidPackageList }
        return resolved
    }

    private static func normalizePath(_ path: String) throws -> String {
        let value = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !value.isEmpty, !value.split(separator: "/").contains("..") else { throw CNUpdateError.invalidManifest }
        return value
    }

    /// The CN CDN does not serve the integrity list as plain files. It uses
    /// the same timestamped MD5 path signer as Atmo's Windows V3 installer.
    private static func signedCDNURL(for normalizedPath: String, manifest: CNIntegrityManifest) throws -> URL {
        // Atmo trims the leading separator before deriving the CDN file key.
        let windowsPath = normalizedPath.replacingOccurrences(of: "/", with: "\\")
        let fileKeyInput = "\(manifest.appID)_\(manifest.dataVersion)_\(windowsPath)"
        let fileKey = md5(data: fileKeyInput.data(using: .utf16LittleEndian) ?? Data()).uppercased()
        let directory = normalizedPath.split(separator: "/").dropLast().joined(separator: "/")
        let unsignedPath = [manifest.baseURL.path, directory, fileKey].filter { !$0.isEmpty }.joined(separator: "/").replacingOccurrences(of: "//", with: "/")
        guard let scheme = manifest.baseURL.scheme,
              let host = manifest.baseURL.host,
              let unsigned = URL(string: "\(scheme)://\(host)\(unsignedPath)") else {
            throw CNUpdateError.invalidManifest
        }
        return try signedURL(unsigned)
    }

    private static func signedURL(_ url: URL) throws -> URL {
        let timestamp = String(format: "%x", Int(Date().timeIntervalSince1970))
        let signInput = "EKUWRI5KXXAIDlQ0mBNLa7XkjU1JNFuL\(url.path)\(timestamp)"
        let sign = md5(data: signInput.data(using: .utf8) ?? Data())
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CNUpdateError.invalidPackageList
        }
        components.path = "/\(sign)/\(timestamp)\(url.path)"
        guard let signed = components.url else { throw CNUpdateError.invalidPackageList }
        return signed
    }

    private static func normalizeVersionView(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "_").first.map(String.init) ?? ""
    }

    private static func md5(data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func md5(handle: FileHandle) throws -> String {
        var hash = Insecure.MD5()
        while true {
            try Task<Never, Never>.checkCancellation()
            let data = autoreleasepool { try? handle.read(upToCount: 4 * 1024 * 1024) }
            guard let data, !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum CNUpdateError: LocalizedError {
    case invalidRemoteVersion, invalidManifest, invalidPackageList, fileNotInManifest, missingGameVersionFile, metadataChanged
    case integrityMismatch(String), unsupportedGameVersion(String), missingUpdatePath(String, String), httpStatus(Int)
    case insufficientDiskSpace(Int64, Int64), gameSelectionChanged

    var errorDescription: String? {
        switch self {
        case .invalidRemoteVersion: return "国服 ver2.dat 格式无效。"
        case .missingGameVersionFile: return "找不到国服游戏版本文件 ffxivgame.ver，已停止启动以避免使用错误版本。"
        case .invalidManifest: return "国服更新清单格式无效。"
        case .metadataChanged: return "国服更新元数据正在切换版本，请重试以获取一致的版本与文件清单。"
        case .invalidPackageList: return "国服 V3 更新包清单格式无效。"
        case .fileNotInManifest: return "请求的文件不在国服完整性清单中。"
        case .integrityMismatch(let path): return "国服更新文件校验失败: \(path)"
        case .unsupportedGameVersion(let version): return "无法从国服 ver2.dat 识别当前游戏版本: \(version)"
        case .missingUpdatePath(let from, let to): return "国服 V3 没有可用更新路径: \(from) -> \(to)"
        case .httpStatus(let code): return "国服更新源返回 HTTP \(code)。"
        case .insufficientDiskSpace(let required, let available):
            return "磁盘空间不足，需要 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))，可用 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))。"
        case .gameSelectionChanged:
            return "游戏下载期间当前来源发生变化，已停止操作以避免写入错误目录。"
        }
    }
}

final class CNStreamingDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: ((Int64, Int64) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var response: URLResponse?
    private var movedFile = false
    private var cancelled = false
    private var lastProgressDate = Date.distantPast
    private let finishLock = NSLock()

    init(destination: URL, progress: ((Int64, Int64) -> Void)?) {
        self.destination = destination
        self.progress = progress
    }

    func download(url: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        finishLock.withLock {
            cancelled = false
            movedFile = false
            response = nil
            lastProgressDate = .distantPast
        }
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 24 * 60 * 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

                self.finishLock.lock()
                guard !self.cancelled, !Task<Never, Never>.isCancelled else {
                    self.finishLock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.session = session
                self.finishLock.unlock()
                session.downloadTask(with: url).resume()
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let shouldReport = finishLock.withLock {
            let now = Date()
            guard now.timeIntervalSince(lastProgressDate) >= 0.1 else { return false }
            lastProgressDate = now
            return true
        }
        if shouldReport { progress?(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        finishLock.lock()
        let shouldMove = !cancelled && continuation != nil
        finishLock.unlock()
        guard shouldMove else { return }
        response = downloadTask.response
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            movedFile = true
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(CNUpdateError.httpStatus(-1))); return
        }
        guard (200..<300).contains(http.statusCode), movedFile else {
            finish(.failure(CNUpdateError.httpStatus(http.statusCode))); return
        }
        finish(.success(()))
    }

    private func finish(_ result: Result<Void, Error>) {
        finishLock.lock()
        guard let continuation else { finishLock.unlock(); return }
        let session = self.session
        self.continuation = nil
        self.session = nil
        finishLock.unlock()
        if case .failure = result { try? FileManager.default.removeItem(at: destination) }
        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }

    private func cancel() {
        finishLock.lock()
        cancelled = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        finishLock.unlock()
        guard continuation != nil || session != nil else { return }
        session?.invalidateAndCancel()
        try? FileManager.default.removeItem(at: destination)
        continuation?.resume(throwing: CancellationError())
    }
}
