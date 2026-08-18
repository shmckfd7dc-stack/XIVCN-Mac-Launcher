using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using XIVLauncher.Common;
using XIVLauncher.Common.Dalamud;
using XIVLauncher.Common.Game;
using XIVLauncher.Common.Game.Patch.Acquisition;
using XIVLauncher.Common.PlatformAbstractions;
using XIVLauncher.Common.Unix;
using XIVLauncher.Common.Unix.Compatibility;

namespace XIVLauncherCN.CoreBridge;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static async Task<int> Main()
    {
        try
        {
            var request = await JsonSerializer.DeserializeAsync<BridgeRequest>(Console.OpenStandardInput(), JsonOptions)
                          ?? throw new BridgeException("请求为空。");
            await Execute(request);
            return 0;
        }
        catch (Exception exception)
        {
            Write(new BridgeEvent("error", Message: GetSafeMessage(exception)));
            return 1;
        }
    }

    private static async Task Execute(BridgeRequest request)
    {
        var settings = new BridgeSettings(request);
        var launcher = new Launcher(Array.Empty<byte>(), new MemoryUniqueIdCache(), settings, request.FrontierUrl ?? string.Empty);

        switch (request.Command)
        {
            case "probe":
                Write(new BridgeEvent(
                    "ready",
                    Message: $"old-core-direct:{launcher.GetType().Assembly.GetName().Version}"));
                break;
            case "probeCompatibilityTools":
            {
                var tools = CreateCompatibilityTools(request);
                Write(new BridgeEvent(
                    "ready",
                    Message: $"old-core-factory:{tools.GetType().AssemblyQualifiedName}"));
                break;
            }
            case "loginStatic":
                Require(request.Account, "账号");
                Require(request.Password, "密码");
                WriteLogin(await launcher.LoginBySdoStatic(request.Account!, request.Password!, null!));
                break;
            case "loginSession":
                Require(request.Account, "账号");
                Require(request.SessionKey, "快速续登凭据");
                WriteLogin(await launcher.LoginBySessionKey(request.Account!, request.SessionKey!, null!));
                break;
            case "loginWeGame":
                Require(request.Account, "账号");
                Require(request.Token, "WeGame Token");
                WriteLogin(await launcher.LoginByWeGameToken(request.Account!, request.Token!, request.AutoLogin, null!));
                break;
            case "loginQr":
            {
                using var cancellation = new CancellationTokenSource();
                WriteLogin(await launcher.LoginByScanQrCode(request.AutoLogin, cancellation,
                    image => Write(new BridgeEvent("qrCode", Data: Convert.ToBase64String(image))), null!));
                break;
            }
            case "loginSlide":
            {
                Require(request.Account, "账号");
                using var cancellation = new CancellationTokenSource();
                WriteLogin(await launcher.LoginBySlide(request.Account!, request.AutoLogin, cancellation,
                    code => Write(new BridgeEvent("verificationCode", Data: code)), null!));
                break;
            }
            case "getSessionId":
                Require(request.Tgt, "TGT");
                Require(request.Guid, "GUID");
                Write(new BridgeEvent("sessionId", Data: await launcher.GetSessionId(request.Tgt!, request.Guid!)));
                break;
            case "getDcTravelSessionId":
                Require(request.Tgt, "TGT");
                Require(request.Guid, "GUID");
                Write(new BridgeEvent("sessionId", Data: await launcher.GetDcTravelSessionId(request.Tgt!, request.Guid!)));
                break;
            case "launch":
                await Launch(launcher, request);
                break;
            default:
                throw new BridgeException($"未知命令：{request.Command}");
        }
    }

    private static async Task Launch(Launcher launcher, BridgeRequest request)
    {
        Require(request.SessionId, "SessionID");
        Require(request.SndaId, "SndaID");
        Require(request.AreaId, "AreaID");
        Require(request.LobbyHost, "LobbyHost");
        Require(request.GmHost, "GMHost");
        Require(request.DbHost, "SaveDataBankHost");
        Require(request.GamePath, "游戏路径");
        Require(request.WineBinPath, "Wine bin 路径");
        Require(request.PrefixPath, "Wine Prefix 路径");
        Require(request.ToolsPath, "旧 Core tools 路径");
        Require(request.LogPath, "Wine 日志路径");

        // The GUI owns the selected runtime and prefix.  Keep the old Core's
        // CompatibilityTools/UnixGameRunner implementation, but construct it
        // from the explicit XOM paths instead of loading ~/.xlcore_cn.  The
        // latter also applies the legacy Win7 workaround and can silently
        // select a different Wine/DXMT installation.
        var tools = CreateCompatibilityTools(request);

        Write(new BridgeEvent(
            "diagnostic",
            Message: $"runtime wineBin={request.WineBinPath} prefix={request.PrefixPath} " +
                     $"tools={request.ToolsPath} game={request.GamePath} " +
                     $"dxmt=true msync={request.MSync == true} " +
                     $"modernMvk={request.ModernMvk == true} win7=false"));

        var temp = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "xivcn-core-bridge"));
        await tools.EnsureTool(temp);

        var additionalArguments = request.AdditionalArguments ?? string.Empty;
        // Keep AdditionalArgs exactly as supplied. The verified old-Core
        // caller passes an empty string here; adding UserPath changes the
        // client's login/config input and is not part of that baseline.

        IGameRunner runner = request.DalamudEnabled
            ? new BridgeDalamudGameRunner(tools, request)
            : new UnixGameRunner(tools, null!, false);
        var process = launcher.LaunchGameSdo(
            runner,
            request.SessionId!,
            request.SndaId!,
            request.DcTravelPort,
            request.AreaId!,
            request.LobbyHost!,
            request.GmHost!,
            request.DbHost!,
            request.AreasInfo ?? string.Empty,
            additionalArguments,
            new DirectoryInfo(request.GamePath!),
            false,
            DpiAwareness.Unaware);

        Write(new BridgeEvent("launched", Pid: process?.Id));
    }

    private static CompatibilityTools CreateCompatibilityTools(BridgeRequest request)
    {
        Require(request.WineBinPath, "Wine bin 路径");
        Require(request.PrefixPath, "Wine Prefix 路径");
        Require(request.ToolsPath, "Core tools 路径");
        Require(request.LogPath, "Wine 日志路径");

        var logFile = new FileInfo(request.LogPath!);
        logFile.Directory?.Create();
        var prefix = new DirectoryInfo(request.PrefixPath!);
        prefix.Create();
        var settings = new WineSettings(
            WineStartupType.Custom,
            request.WineBinPath!,
            request.WineDebug ?? "-all",
            logFile,
            prefix,
            request.ESync ?? false,
            request.FSync ?? false,
            request.MSync ?? true,
            request.ModernMvk ?? true,
            request.WineEnvironment ?? string.Empty);

        // The source-built CompatibilityTools is DXMT-only.
        return new CompatibilityTools(
            settings,
            request.FrameLimit,
            new DirectoryInfo(request.ToolsPath!),
            request.MetalFx ?? false,
            request.MetalFxFactor ?? 1.0);
    }

    private static void WriteLogin(Launcher.LoginResult result)
    {
        var login = result.OauthLogin ?? throw new BridgeException("旧 Core 未返回登录会话。");
        Write(new BridgeEvent(
            "loginResult",
            Login: new LoginPayload(
                result.State.ToString(),
                login.InputUserId,
                login.SessionId,
                login.SndaId,
                login.Tgt,
                login.Guid,
                login.AutoLoginSessionKey,
                login.LoginType.ToString(),
                result.UniqueId,
                result.DcTravelPort,
                result.Area is null ? null : AreaPayload.From(result.Area),
                result.Areas?.Select(AreaPayload.From).ToArray())));
    }

    private static void Write(BridgeEvent value)
    {
        Console.Out.WriteLine(JsonSerializer.Serialize(value, JsonOptions));
        Console.Out.Flush();
    }

    private static void Require(string? value, string name)
    {
        if (string.IsNullOrWhiteSpace(value))
            throw new BridgeException($"缺少{name}。");
    }

    private static string GetSafeMessage(Exception exception)
    {
        while (exception.InnerException is not null)
            exception = exception.InnerException;
        return exception.Message;
    }
}

internal sealed class BridgeSettings(BridgeRequest request) : ISettings
{
    public string AcceptLanguage => request.AcceptLanguage ?? "zh-CN,zh;q=0.9";
    public ClientLanguage? ClientLanguage => XIVLauncher.Common.ClientLanguage.ChineseSimplified;
    public bool? KeepPatches => true;
    public DirectoryInfo PatchPath => new(request.PatchPath ?? Path.Combine(Path.GetTempPath(), "xivcn-patch"));
    public DirectoryInfo GamePath => new(request.GamePath ?? Directory.GetCurrentDirectory());
    public AcquisitionMethod? PatchAcquisitionMethod => AcquisitionMethod.Aria;
    public long SpeedLimitBytes => 0;
    public int DalamudInjectionDelayMs => request.DalamudInjectionDelayMs;
}

internal sealed class MemoryUniqueIdCache : IUniqueIdCache
{
    private readonly Dictionary<string, IUniqueIdCache.CachedUid> values = new(StringComparer.Ordinal);

    public bool HasValidCache(string name) => values.ContainsKey(name);

    public void Add(string name, string uid, int region, int maxExpansion) =>
        values[name] = new IUniqueIdCache.CachedUid
        {
            UniqueId = uid,
            Region = region,
            MaxExpansion = maxExpansion,
        };

    public bool TryGet(string userName, out IUniqueIdCache.CachedUid cached) =>
        values.TryGetValue(userName, out cached!);

    public void Reset() => values.Clear();
}

internal sealed record BridgeRequest
{
    public string Command { get; init; } = string.Empty;
    public string? Account { get; init; }
    public string? Password { get; init; }
    public string? SessionKey { get; init; }
    public string? Token { get; init; }
    public string? Tgt { get; init; }
    public string? Guid { get; init; }
    public bool AutoLogin { get; init; } = true;
    public string? FrontierUrl { get; init; }
    public string? AcceptLanguage { get; init; }
    public string? PatchPath { get; init; }
    public string? GamePath { get; init; }
    public string? SessionId { get; init; }
    public string? SndaId { get; init; }
    public int DcTravelPort { get; init; }
    public string? AreaId { get; init; }
    public string? LobbyHost { get; init; }
    public string? GmHost { get; init; }
    public string? DbHost { get; init; }
    public string? AreasInfo { get; init; }
    public string? AdditionalArguments { get; init; }
    public string? UserPath { get; init; }
    public string? WineBinPath { get; init; }
    public string? PrefixPath { get; init; }
    public string? ToolsPath { get; init; }
    public string? LogPath { get; init; }
    public string? WineDebug { get; init; }
    public string? WineEnvironment { get; init; }
    public bool? ESync { get; init; } = true;
    public bool? FSync { get; init; } = false;
    public bool? MSync { get; init; } = true;
    public bool? ModernMvk { get; init; } = true;
    public int FrameLimit { get; init; }
    public bool? MetalFx { get; init; } = false;
    public double? MetalFxFactor { get; init; } = 1.0;
    public bool DalamudEnabled { get; init; }
    public string? DalamudInjectorPath { get; init; }
    public string? DalamudRuntimePath { get; init; }
    public string? DalamudAssetsPath { get; init; }
    public string? DalamudConfigPath { get; init; }
    public string? DalamudPluginPath { get; init; }
    public string? DalamudLogPath { get; init; }
    public int DalamudInjectionDelayMs { get; init; }
    public bool NoThirdPartyPlugins { get; init; }
}

/// Keeps the proven Core launch argument construction and swaps only the
/// process runner when the user selected one Dalamud variant. Updating and
/// atomic activation remain owned by Swift, so the Bridge never starts a
/// second updater or chooses between China and Soil itself.
internal sealed class BridgeDalamudGameRunner : IGameRunner
{
    private readonly UnixDalamudRunner runner;
    private readonly FileInfo injector;
    private readonly string configPath;
    private readonly string pluginPath;
    private readonly string assetPath;
    private readonly string logPath;
    private readonly int injectionDelayMs;
    private readonly bool noThirdPartyPlugins;

    public BridgeDalamudGameRunner(CompatibilityTools compatibility, BridgeRequest request)
    {
        RequirePath(request.DalamudInjectorPath, "Dalamud Injector", file: true);
        RequirePath(request.DalamudRuntimePath, "Dalamud Runtime", file: false);
        RequirePath(request.DalamudAssetsPath, "Dalamud Assets", file: false);
        Require(request.DalamudConfigPath, "Dalamud 配置路径");
        Require(request.DalamudPluginPath, "Dalamud 插件路径");
        Require(request.DalamudLogPath, "Dalamud 日志路径");

        injector = new FileInfo(request.DalamudInjectorPath!);
        runner = new UnixDalamudRunner(compatibility, new DirectoryInfo(request.DalamudRuntimePath!));
        configPath = request.DalamudConfigPath!;
        pluginPath = request.DalamudPluginPath!;
        assetPath = request.DalamudAssetsPath!;
        logPath = request.DalamudLogPath!;
        injectionDelayMs = Math.Max(0, request.DalamudInjectionDelayMs);
        noThirdPartyPlugins = request.NoThirdPartyPlugins;

        Directory.CreateDirectory(Path.GetDirectoryName(configPath)!);
        Directory.CreateDirectory(pluginPath);
        Directory.CreateDirectory(logPath);
    }

    public Process? Start(string path, string workingDirectory, string arguments,
                          IDictionary<string, string> environment, DpiAwareness dpiAwareness)
    {
        var startInfo = new DalamudStartInfo
        {
            WorkingDirectory = injector.DirectoryName ?? workingDirectory,
            ConfigurationPath = configPath,
            LoggingPath = logPath,
            PluginDirectory = pluginPath,
            AssetDirectory = assetPath,
            Language = ClientLanguage.ChineseSimplified,
            DelayInitializeMs = injectionDelayMs,
            GameVersion = string.Empty,
            TroubleshootingPackData = string.Empty,
            LauncherDirectory = injector.DirectoryName ?? Environment.CurrentDirectory,
        };
        return runner.Run(injector, fakeLogin: false, noPlugins: false, noThirdPartyPlugins,
                          new FileInfo(path), arguments, environment,
                          DalamudLoadMethod.EntryPoint, startInfo);
    }

    private static void Require(string? value, string name)
    {
        if (string.IsNullOrWhiteSpace(value))
            throw new BridgeException($"缺少{name}。");
    }

    private static void RequirePath(string? value, string name, bool file)
    {
        Require(value, name);
        var exists = file ? File.Exists(value) : Directory.Exists(value);
        if (!exists)
            throw new BridgeException($"{name}不存在：{value}");
    }
}

internal sealed record BridgeEvent(string Type, string? Message = null, string? Data = null,
                                   int? Pid = null, LoginPayload? Login = null);

internal sealed record LoginPayload(string State, string Account, string SessionId, string SndaId,
                                    string? Tgt, string? Guid,
                                    string? AutoLoginSessionKey, string LoginType, string? UniqueId,
                                    int DcTravelPort, AreaPayload? Area, AreaPayload[]? Areas);

internal sealed record AreaPayload(string Id, int Status, int Order, string Name, int Type,
                                   string LobbyHost, string GmHost, string PatchHost, string ConfigUploadHost)
{
    public static AreaPayload From(SdoArea area) => new(
        area.Areaid,
        area.AreaStat,
        area.AreaOrder,
        area.AreaName,
        area.Areatype,
        area.AreaLobby,
        area.AreaGm,
        area.AreaPatch,
        area.AreaConfigUpload);
}

internal sealed class BridgeException(string message) : Exception(message);
