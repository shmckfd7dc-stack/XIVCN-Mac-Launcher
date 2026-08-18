import Foundation

@main
private enum CNGameUpdateProbe {
    static func main() async throws {
        let client = try CNGameUpdateClient()
        let update = try await client.fetchLatestUpdate()
        guard update.manifest.files["game/ffxivgame.ver"] != nil else {
            throw ProbeError.versionFileMissing
        }
        let probeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFXIV-CN-MAC-update-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: probeRoot) }
        let versionFile = probeRoot.appendingPathComponent("game/ffxivgame.ver")
        try await client.download(file: "game/ffxivgame.ver", from: update.manifest, to: versionFile)
        let downloaded = try String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard downloaded == update.targetGameVersion else {
            throw ProbeError.versionMismatch(downloaded, update.targetGameVersion)
        }
        print("Data version: \(update.targetDataVersion)")
        print("Game version: \(update.targetGameVersion)")
        print("Manifest files: \(update.manifest.files.count)")
        print("Signed CDN download + size/MD5 verification: OK")
    }
}

private enum ProbeError: LocalizedError {
    case versionFileMissing
    case versionMismatch(String, String)

    var errorDescription: String? {
        switch self {
        case .versionFileMissing: return "国服完整性清单缺少 ffxivgame.ver"
        case .versionMismatch(let downloaded, let expected):
            return "下载版本与 ver2.dat 不一致：\(downloaded) != \(expected)"
        }
    }
}
