import Foundation

enum WinePrefixConfigurationError: LocalizedError {
    case registryCommandFailed(String, Int32)
    case registryCommandTimedOut(String)
    case unsafePrefixPath(URL)

    var errorDescription: String? {
        switch self {
        case .registryCommandFailed(let value, let status):
            return "无法写入 Wine 图形/键盘设置 \(value)（状态码 \(status)）。"
        case .registryCommandTimedOut(let value):
            return "Wine 图形/键盘设置 \(value) 超时，已停止本次启动准备。"
        case .unsafePrefixPath(let url):
            return "Wine Prefix 路径不在启动器管理目录中，已拒绝重置：\(url.path)"
        }
    }
}

/// Applies the XOM macOS driver settings to the selected Prefix immediately
/// before launch. The old XOM UI wrote these values through its native registry
/// helper; the Swift UI must keep the same Prefix-level contract.
enum WinePrefixConfiguration {
    private static let registryKey = "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver"
    private static let cacheName = ".xivcn-mac-driver-settings.json"

    private struct Snapshot: Codable, Equatable {
        let values: [String: String]
    }

    private static func registryValues(settings: LauncherSettings) -> [(String, String)] {
        [
            ("RetinaMode", settings.retinaEnabled ? "y" : "n"),
            ("LeftOptionIsAlt", settings.leftOptionIsAlt ? "y" : "n"),
            ("RightOptionIsAlt", settings.rightOptionIsAlt ? "y" : "n"),
            ("LeftCommandIsCtrl", settings.leftCommandIsControl ? "y" : "n"),
            ("RightCommandIsCtrl", settings.rightCommandIsControl ? "y" : "n")
        ]
    }

    static func needsApply(settings: LauncherSettings, prefix: URL,
                           fileManager: FileManager = .default) -> Bool {
        let expected = Snapshot(values: Dictionary(
            uniqueKeysWithValues: registryValues(settings: settings)))
        let cache = prefix.appendingPathComponent(cacheName)
        guard let data = try? Data(contentsOf: cache),
              let current = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return true
        }
        return current != expected
    }

    static func apply(settings: LauncherSettings, wine: URL, prefix: URL,
                      fileManager: FileManager = .default) throws {
        guard fileManager.isExecutableFile(atPath: wine.path) else { return }
        try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)
        let values = registryValues(settings: settings)
        let snapshot = Snapshot(values: Dictionary(uniqueKeysWithValues: values))
        let cache = prefix.appendingPathComponent(cacheName)
        let previous = (try? Data(contentsOf: cache))
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        let pending = values.filter { previous?.values[$0.0] != $0.1 }
        guard !pending.isEmpty else { return }

        for (name, value) in pending {
            let process = Process()
            process.executableURL = wine
            process.arguments = ["reg", "add", registryKey, "/v", name,
                                 "/d", value, "/f"]
            var environment = ProcessInfo.processInfo.environment
            environment["WINEPREFIX"] = prefix.path
            environment["WINEDEBUG"] = "-all"
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            // A fresh Prefix may initialize wineserver on the first registry
            // command. Keep the operation bounded without treating that
            // normal first-run window as an immediate launch failure.
            guard finished.wait(timeout: .now() + 30) == .success else {
                if process.isRunning { process.terminate() }
                throw WinePrefixConfigurationError.registryCommandTimedOut(name)
            }
            guard process.terminationStatus == 0 else {
                throw WinePrefixConfigurationError.registryCommandFailed(name,
                                                                          process.terminationStatus)
            }
        }
        try? JSONEncoder().encode(snapshot).write(to: cache, options: .atomic)
    }
}
