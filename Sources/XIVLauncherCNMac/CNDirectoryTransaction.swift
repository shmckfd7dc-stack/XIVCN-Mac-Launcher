import Foundation

enum CNDirectoryTransaction {
    private static let backupPrefix = ".replacement-backup-"

    static func backupURL(for final: URL) -> URL {
        final.deletingLastPathComponent()
            .appendingPathComponent(backupPrefix + final.lastPathComponent, isDirectory: true)
    }

    static func recover(final: URL, backup: URL, currentIsValid: () -> Bool) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backup.path) else { return }
        if fileManager.fileExists(atPath: final.path), currentIsValid() {
            try fileManager.removeItem(at: backup)
            return
        }
        if fileManager.fileExists(atPath: final.path) {
            try fileManager.removeItem(at: final)
        }
        try fileManager.moveItem(at: backup, to: final)
    }

    static func recoverBackups(in directory: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil) else { return }
        for backup in entries where backup.lastPathComponent.hasPrefix(backupPrefix) {
            let name = String(backup.lastPathComponent.dropFirst(backupPrefix.count))
            guard !name.isEmpty else { continue }
            let final = directory.appendingPathComponent(name, isDirectory: true)
            try? recover(final: final, backup: backup) {
                fileManager.fileExists(atPath: final.path)
            }
        }
    }

    static func replace(staging: URL, final: URL,
                        validate: () throws -> Void,
                        activate: () throws -> Void) throws {
        let fileManager = FileManager.default
        let backup = backupURL(for: final)
        try recover(final: final, backup: backup) {
            fileManager.fileExists(atPath: final.path)
        }
        let hadExisting = fileManager.fileExists(atPath: final.path)
        if hadExisting {
            try fileManager.moveItem(at: final, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: final)
            try validate()
            try activate()
        } catch {
            try? fileManager.removeItem(at: final)
            if hadExisting, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: final)
            }
            throw error
        }
        if hadExisting {
            try? fileManager.removeItem(at: backup)
        }
    }
}
