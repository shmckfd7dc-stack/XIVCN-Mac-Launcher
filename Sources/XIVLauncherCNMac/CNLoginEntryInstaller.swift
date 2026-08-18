import CryptoKit
import Foundation

enum CNLoginEntryError: LocalizedError {
    case bundledResourceMissing
    case bundledResourceIntegrityMismatch
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledResourceMissing:
            return "应用包缺少 Core 国服 SDO 登录组件。"
        case .bundledResourceIntegrityMismatch:
            return "Core 国服 SDO 登录组件校验失败，已停止启动。"
        case .installFailed(let detail):
            return "无法准备国服 SDO 登录组件：\(detail)"
        }
    }
}

/// Minimal CN adaptation from XIVLauncher.Core's EnsureLoginEntry behavior.
/// XOM remains responsible for Wine, Prefix and process execution; this helper
/// only prepares the game-owned SDO entry DLL before the handoff.
enum CNLoginEntryInstaller {
    static let coreSHA256 = "a7ae15660d00eb0b15e76902736721d2cc7450fed811dfbde879a07336ae65cd"

    static func ensureLoginEntry(gameRoot: URL, bundle: Bundle = .main,
                                 verifyIntegrity: Bool = false,
                                 fileManager: FileManager = .default) throws {
        guard let bundled = bundle.url(forResource: "sdologinentry64",
                                       withExtension: "dll", subdirectory: "sdo") else {
            throw CNLoginEntryError.bundledResourceMissing
        }
        let directory = gameRoot.appendingPathComponent("sdo/sdologin", isDirectory: true)
        let target = directory.appendingPathComponent("sdologinentry64.dll")
        let backup = directory.appendingPathComponent("sdologinentry64.sdo.dll")
        let marker = directory.appendingPathComponent(".sdologinentry64.core.sha256")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !verifyIntegrity,
               fileManager.fileExists(atPath: target.path),
               (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == coreSHA256 {
                return
            }
            if verifyIntegrity {
                guard try sha256(of: bundled).caseInsensitiveCompare(coreSHA256) == .orderedSame else {
                    throw CNLoginEntryError.bundledResourceIntegrityMismatch
                }
            }

            // The old Core only creates this backup at the moment it first
            // replaces the game's DLL. If a previous launch backed up the
            // Core shim itself, the old Core sees an already-correct target
            // and never repairs the poisoned backup. Recover the original
            // game DLL from the install's Launcher3Modules tree before the
            // bridge starts the Windows client.
            let targetHash = hashIfPresent(target, fileManager: fileManager)
            let backupHash = hashIfPresent(backup, fileManager: fileManager)
            if backupHash == nil || backupHash == coreSHA256 {
                let original = originalGameEntry(gameRoot: gameRoot,
                                                 target: target,
                                                 fileManager: fileManager)
                if let original, hashIfPresent(original, fileManager: fileManager) != coreSHA256 {
                    if fileManager.fileExists(atPath: backup.path) {
                        let archived = directory.appendingPathComponent(
                            "sdologinentry64.sdo.dll.invalid.\(UUID().uuidString)")
                        try fileManager.moveItem(at: backup, to: archived)
                    }
                    try atomicCopy(from: original, to: backup,
                                   fileManager: fileManager)
                }
            }

            // Preserve a real game DLL before replacing the active entry.
            // This is the same operation as old Core's EnsureLoginEntry, but
            // it also handles a stale shim backup left by an earlier build.
            if targetHash != coreSHA256,
               !fileManager.fileExists(atPath: backup.path),
               fileManager.fileExists(atPath: target.path) {
                try atomicCopy(from: target, to: backup, fileManager: fileManager)
            }

            if hashIfPresent(target, fileManager: fileManager) != coreSHA256 {
                try atomicCopy(from: bundled, to: target, fileManager: fileManager)
            }
            try coreSHA256.write(to: marker, atomically: true, encoding: .utf8)
        } catch {
            throw CNLoginEntryError.installFailed(error.localizedDescription)
        }
    }

    private static func originalGameEntry(gameRoot: URL, target: URL,
                                          fileManager: FileManager) -> URL? {
        let launcherModules = gameRoot
            .appendingPathComponent("Launcher3Modules", isDirectory: true)
            .appendingPathComponent("sdologinentry64.dll")
        if fileManager.fileExists(atPath: launcherModules.path) {
            return launcherModules
        }
        // A valid pre-existing target is the same source old Core would have
        // backed up on its first launch when Launcher3Modules is unavailable.
        if fileManager.fileExists(atPath: target.path) {
            return target
        }
        return nil
    }

    private static func hashIfPresent(_ file: URL, fileManager: FileManager) -> String? {
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        return try? sha256(of: file)
    }

    private static func atomicCopy(from source: URL, to destination: URL,
                                   fileManager: FileManager) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func sha256(of file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
