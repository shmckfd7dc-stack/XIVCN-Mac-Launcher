import Foundation

/// Product-owned runtime metadata. Wine and DXMT are immutable App resources;
/// there is intentionally no downloader, catalog, installer, or rollback API.
enum BundledRuntime {
    static let wineVersion = "5.4.2"
    static let dxmtVersion = "5.4.2"
}

enum BundledRuntimeError: LocalizedError {
    case missingRuntime
    case missingDXMT
    case graphicsBackendInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRuntime:
            return "应用包缺少内置 Wine/DXMT Runtime，请重新安装启动器。"
        case .missingDXMT:
            return "应用包缺少内置 DXMT 文件，请重新安装启动器。"
        case .graphicsBackendInstallFailed(let detail):
            return "无法准备内置 DXMT 图形文件：\(detail)"
        }
    }
}
