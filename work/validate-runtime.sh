#!/bin/sh
set -eu
test "$(uname -m)" = arm64
grep -q 'launcher.LoginBySdoStatic' work/core-bridge/Program.cs
grep -q 'launcher.LoginByScanQrCode' work/core-bridge/Program.cs
grep -q 'launcher.LoginBySlide' work/core-bridge/Program.cs
grep -q 'launcher.LoginBySessionKey' work/core-bridge/Program.cs
grep -q 'launcher.LaunchGameSdo' work/core-bridge/Program.cs
grep -q 'OldCoreBridge.execute(request)' Sources/XIVLauncherCNMac/CoreBackend.swift
grep -q 'OldCoreBridge.execute' Sources/XIVLauncherCNMac/CNCoreLoginBackend.swift
grep -q 'core-tools' Sources/XIVLauncherCNMac/CoreBackend.swift
if rg -n 'CNArgumentBuilder|CNLoginClient.*json|runInPrefix|createCompatToolsInstance' \
  Sources/XIVLauncherCNMac/CoreBackend.swift Sources/XIVLauncherCNMac/CNCoreLoginBackend.swift >/dev/null; then
  echo "duplicate Core protocol implementation found" >&2
  exit 1
fi
if rg -n 'resetWineServerIfIdle|probeMSync|runWineDebugger|Process\(\).*wine|winedbg.*info proc|wineserver.*-[kw]' Sources/XIVLauncherCNMac >/dev/null; then
  echo "forbidden Wine control path found" >&2
  exit 1
fi
if rg -n 'managedGameDownloadShouldAutoLaunch|autoLaunchAfterInstall' Sources/XIVLauncherCNMac >/dev/null; then
  echo "managed game auto-launch path found" >&2
  exit 1
fi
grep -q 'managedGameDownloadCompletionMessage' Sources/XIVLauncherCNMac/XIVLauncherCNMacApp.swift
grep -q 'updateCompletionMessage' Sources/XIVLauncherCNMac/XIVLauncherCNMacApp.swift
if rg -n 'RuntimeController\.(installDXMT|installGraphicsBackend|runtimeDiagnostics|environment)' Sources/XIVLauncherCNMac >/dev/null; then
  echo "legacy runtime controller found" >&2
  exit 1
fi
grep -q 'wineVersion = "5.4.2"' Sources/XIVLauncherCNMac/BundledRuntime.swift
grep -q 'dxmtVersion = "5.4.2"' Sources/XIVLauncherCNMac/BundledRuntime.swift
if rg -n 'RuntimeUpdateCatalog|FFXIVCNRuntimeCatalog|runtime-catalog' Sources scripts Package.swift >/dev/null; then
  echo "legacy runtime catalog found" >&2
  exit 1
fi
if rg -n 's3[.]ffxiv[.]wang/xlcore/deps/(wine|dxmt|dxvk)|DownloadTool|DownloadDxmt|DownloadDxvk' \
  ../../legacy-core/source/XIVLauncher.Common.Unix >/dev/null; then
  echo "old Core runtime downloader found" >&2
  exit 1
fi
if rg -n 'Dxvk|DXVK|wineD3D|WineD3D' ../../legacy-core/source/XIVLauncher.Common.Unix work/core-bridge >/dev/null; then
  echo "forbidden graphics backend found" >&2
  exit 1
fi
if rg -n 'XIVLauncher[.]Core' work/core-bridge/CoreBridge.csproj scripts/build-old-core.sh >/dev/null; then
  echo "old GUI Core assembly found" >&2
  exit 1
fi
if rg -n 'XOMNativeAOT|CNArgumentCrypto' Package.swift Sources/XIVLauncherCNMac >/dev/null; then
  echo "duplicate native backend found" >&2
  exit 1
fi
if rg -n 'prepareOffline|offlineArchive|offlineManifest|offlineDirectory' Sources/XIVLauncherCNMac >/dev/null; then
  echo "offline Dalamud fallback found" >&2
  exit 1
fi
if rg -n 'dalamud-26-08-09-01|dalamud-china-15[.]0[.]3[.]1|dotnet-runtime-win-x64|windowsdesktop-runtime-win-x64|dalamud-assets/' scripts/build-dmg.sh >/dev/null; then
  echo "offline Dalamud resource is still packaged" >&2
  exit 1
fi
if rg -n 'waitUntilExit' Sources/XIVLauncherCNMac/CNDalamudUpdater.swift Sources/XIVLauncherCNMac/CNWindowsRuntimeInstaller.swift >/dev/null; then
  echo "blocking non-cancellable Dalamud extraction found" >&2
  exit 1
fi
grep -q 'CNCancellableProcess.run' Sources/XIVLauncherCNMac/CNDalamudUpdater.swift
grep -q 'CNCancellableProcess.run' Sources/XIVLauncherCNMac/CNWindowsRuntimeInstaller.swift
test -f work/bundled/sdologinentry64.dll
test "$(shasum -a 256 work/bundled/sdologinentry64.dll | awk '{print $1}')" = "a7ae15660d00eb0b15e76902736721d2cc7450fed811dfbde879a07336ae65cd"
test -x scripts/verify-xom-loader-chain.sh
sh -n scripts/verify-xom-loader-chain.sh
if rg -n 'source-xom-tc/|runtime-inspect/wine\.tar\.gz|xom-tc-dxmt|6d89fc397f55ecb178c8ed816267f7d6d06dcc4fb64d825f0abe1ad9cdae6702|ea19fcfe4f9056b02a5fd636fce1650b8b34c8c1455ce661ff9655331165813a' Sources scripts UPSTREAMS.json NOTICE >/dev/null; then
  echo "forbidden non-international runtime reference found" >&2
  exit 1
fi
grep -q 'case managed, external' Sources/XIVLauncherCNMac/Models.swift
grep -q 'Retina 高清分辨率模式' Sources/XIVLauncherCNMac/SettingsView.swift
grep -q 'externalGameCannotBeRemoved' Sources/XIVLauncherCNMac/GameInstallManager.swift
grep -q 'casPrimaryDomain = "cas.sdo.com"' Sources/XIVLauncherCNMac/Models.swift
grep -q 'lobbyPort = 54994' Sources/XIVLauncherCNMac/Models.swift
grep -q 'dalamudDistributionURL = "https://dalamud-dis.atmoomen.top"' Sources/XIVLauncherCNMac/Models.swift
echo "runtime validation passed"
