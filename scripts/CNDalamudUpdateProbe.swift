import Foundation

@main
private enum CNDalamudUpdateProbe {
    static func main() async throws {
        guard (2...3).contains(CommandLine.arguments.count) else {
            throw ProbeError.usage
        }
        let extractor = URL(fileURLWithPath: CommandLine.arguments[1])
        let variant: DalamudVariant
        switch CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "soil" {
        case "china": variant = .china
        case "soil": variant = .soil
        default: throw ProbeError.usage
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFXIV-CN-MAC-dalamud-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let updater = try CNDalamudUpdater(variant: variant)
        let prepared = try await updater.prepareLocalOrRemote(in: root, sevenZip: extractor)
        let assets = try await updater.prepareAssets(in: root, sevenZip: extractor)
        guard FileManager.default.fileExists(atPath: prepared.injector.path),
              CNDalamudUpdater.activeVersion(in: root) == prepared.release.version,
              CNDalamudUpdater.activeAssetVersion(in: root) == assets.version,
              CNDalamudUpdater.activeInstallationIsHealthy(in: root) else {
            throw ProbeError.activationFailed
        }
        print("\(variant.title) release: \(prepared.release.version)")
        print("\(variant.title) assets: \(assets.version)")
        print("Core/Assets download + hashes + ACTIVE switch: OK")
    }
}

private enum ProbeError: LocalizedError {
    case usage, activationFailed

    var errorDescription: String? {
        switch self {
        case .usage: return "usage: CNDalamudUpdateProbe <7zz-path> [china|soil]"
        case .activationFailed: return "Dalamud probe did not activate a verified Injector"
        }
    }
}
