#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$root/outputs"
app_name="XIVCN Mac Launcher"
dmg_basename="XIVCN-Mac-Launcher-arm64"
build="$out/$app_name.app"
scratch="/private/tmp/xivcn-dmg-build"
handover_root=$(CDPATH= cd -- "$root/../.." && pwd)
dotnet_default="$handover_root/toolchain/dotnet-sdk-x64/dotnet"
if test ! -x "$dotnet_default"; then
  dotnet_default="/private/tmp/xivcn-dotnet-sdk-x64/dotnet"
fi
dotnet_x64="${XIVCN_DOTNET_X64:-$dotnet_default}"

# Fail before touching an App/DMG when the runtime-source or loader contract
# no longer matches the pinned international XOM baseline.
(cd "$root" && sh work/validate-runtime.sh)

launcher_version="${XIVCN_LAUNCHER_VERSION:-$(tr -d '[:space:]' < "$root/VERSION")}"
case "$launcher_version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "Invalid launcher version: $launcher_version" >&2; exit 1 ;;
esac
rm -rf "$scratch" "$build"
rm -rf "$out/XIVLauncherCNMac.app"
mkdir -p "$scratch" "$out" "$build/Contents/MacOS" "$build/Contents/Resources"

# Build only the old Core assemblies used by the Bridge. An explicit
# XIVCN_OLD_CORE_ROOT remains available for controlled dependency comparison.
if test -n "${XIVCN_OLD_CORE_ROOT:-}"; then
  old_core_root="$XIVCN_OLD_CORE_ROOT"
else
  old_core_root="$scratch/old-core-bundle"
  XIVCN_DOTNET_X64="$dotnet_x64" sh "$root/scripts/build-old-core.sh" "$old_core_root" >/dev/null
fi

# Bundle only the audited international XOM 5.4.2 runtime. The old
# legacy WineCX archive and every non-international regional path are
# intentionally excluded.
# d3d11/dxgi are copied in the exact XOM 5.4.2 Resources/dxmt layout. The
# complete Wine tree (including winemetal) stays under Resources/wine.
# The game itself is never copied.
runtime_archive="$root/work/runtime-inspect/xom-5.4.2-wine.tar.gz"
test -f "$runtime_archive"
test "$(shasum -a 256 "$runtime_archive" | awk '{print $1}')" = "b07e12962d993d62d13f58a8b0b80e6aa4b816684c37f51de886a253dea9ff16"
dxmt_source="$root/work/runtime-inspect/xom-5.4.2-dxmt"
test -f "$dxmt_source/d3d11.dll"
test -f "$dxmt_source/dxgi.dll"
test "$(shasum -a 256 "$dxmt_source/d3d11.dll" | awk '{print $1}')" = "617cf79d79d14b7d4041446aa3ec4658a257945d4bab127626eb5973f9da5b18"
test "$(shasum -a 256 "$dxmt_source/dxgi.dll" | awk '{print $1}')" = "d26b51f7c662a9189377952a6ca6d427fdb108a4302c5877b1253aef0cfc8849"
mkdir -p "$build/Contents/Resources/dxmt" \
  "$build/Contents/Resources/core-tools/dxmt/dxmt" \
  "$build/Contents/Resources/wine"
# Keep the exact XOM Wine directory layout in the App. The archive is a build
# input only and is not duplicated in the final bundle.
wine_staging="$scratch/xom-wine"
mkdir -p "$wine_staging"
tar -xzf "$runtime_archive" -C "$wine_staging"
wine_root=$(find "$wine_staging" -type f -path '*/bin/wine' -print -quit | sed 's#/bin/wine$##')
test -n "$wine_root"
cp -R "$wine_root/." "$build/Contents/Resources/wine/"
test -x "$build/Contents/Resources/wine/bin/wine"
# XIVLauncher.Common.Unix from the old Core names the custom loader wine64;
# XOM 5.4.2 ships the same x86_64 loader as wine. Keep the original binary
# and expose only the compatibility name expected by old Core.
ln -s wine "$build/Contents/Resources/wine/bin/wine64"
for dll in d3d11.dll dxgi.dll; do
  source="$dxmt_source/$dll"
  test -f "$source"
  cp "$source" "$build/Contents/Resources/dxmt/$dll"
  cp "$source" "$build/Contents/Resources/core-tools/dxmt/dxmt/$dll"
done
# Online Dalamud packages still use the bundled extractor. Core, Assets and
# Windows Runtime packages are downloaded from their current CN feeds.
test -x "$root/work/bundled/7zz"
cp "$root/work/bundled/7zz" "$build/Contents/Resources/7zz"
cp "$root/source-xom/XIV on Mac/FFXIV-MacDefault.cfg" "$build/Contents/Resources/FFXIV-MacDefault.cfg"
# XOM installs this compiler backend into the active Wine Prefix before
# launching the game. Keep the exact reviewed XOM asset in the App so the
# launcher can reproduce that step for an external FFXIV installation.
graphics_backend="$root/source-xom/XIV on Mac/d3dcompiler/d3dcompiler_47.dll"
test -f "$graphics_backend"
test "$(shasum -a 256 "$graphics_backend" | awk '{print $1}')" = \
  "e994847e01a6f1e4cbdc5a864616ac262f67ee4f14db194984661a8d927ab7f4"
mkdir -p "$build/Contents/Resources/d3dcompiler"
cp "$graphics_backend" "$build/Contents/Resources/d3dcompiler/d3dcompiler_47.dll"
# Core's CN SDO entry DLL is a separate game-adaptation asset. It is not part
# of the XOM/Wine/DXMT runtime and is installed into the selected game root at
# launch time after its provenance hash is checked.
sdo_login_entry="$root/work/bundled/sdologinentry64.dll"
test -f "$sdo_login_entry"
test "$(shasum -a 256 "$sdo_login_entry" | awk '{print $1}')" = \
  "a7ae15660d00eb0b15e76902736721d2cc7450fed811dfbde879a07336ae65cd"
mkdir -p "$build/Contents/Resources/sdo"
cp "$sdo_login_entry" "$build/Contents/Resources/sdo/sdologinentry64.dll"
chmod +x "$build/Contents/Resources/7zz"

# The GUI launches this small IPC process, which loads the original Core
# assemblies and calls their public login/LaunchGameSdo methods. It contains
# no CN protocol or Wine implementation of its own.
test -x "$dotnet_x64"
test -f "$old_core_root/XIVLauncher.Common.dll"
test -f "$old_core_root/XIVLauncher.Common.Unix.dll"
bridge_publish="$scratch/core-bridge"
rm -rf "$bridge_publish"
arch -x86_64 "$dotnet_x64" restore "$root/work/core-bridge/CoreBridge.csproj" -r osx-x64
arch -x86_64 "$dotnet_x64" publish "$root/work/core-bridge/CoreBridge.csproj" -c Release -r osx-x64 \
  -p:OldCoreRoot="$old_core_root" --self-contained true -o "$bridge_publish" --no-restore
mkdir -p "$build/Contents/Resources/core-bridge" "$build/Contents/Resources/core-bridge/Resources/binaries"
cp -R "$bridge_publish/." "$build/Contents/Resources/core-bridge/"
cp "$old_core_root/Resources/binaries/sdologinentry64.dll" \
  "$build/Contents/Resources/core-bridge/Resources/binaries/sdologinentry64.dll"
chmod +x "$build/Contents/Resources/core-bridge/XIVLauncherCN.CoreBridge"
compat_probe=$(printf '%s\n' \
  "{\"command\":\"probeCompatibilityTools\",\"wineBinPath\":\"$build/Contents/Resources/wine/bin\",\"prefixPath\":\"$scratch/probe-prefix\",\"toolsPath\":\"$build/Contents/Resources/core-tools\",\"logPath\":\"$scratch/probe.log\"}" | \
  arch -x86_64 "$build/Contents/Resources/core-bridge/XIVLauncherCN.CoreBridge")
printf '%s\n' "$compat_probe" | grep -q 'old-core-factory:XIVLauncher.Common.Unix.Compatibility.CompatibilityTools'
sdk="${XIVCN_SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
test -d "$sdk"
export TMPDIR=/private/tmp/xivcn-tmp
export SDKROOT="$sdk"
export SWIFT_MODULE_CACHE_PATH=/private/tmp/xivcn-module-cache
export CLANG_MODULE_CACHE_PATH=/private/tmp/xivcn-module-cache
export SWIFTPM_ENABLE_CACHING=0
mkdir -p "$TMPDIR" "$SWIFT_MODULE_CACHE_PATH" "$CLANG_MODULE_CACHE_PATH"
product="/private/tmp/xivcn-dmg-release/out/Products/Release/XIVLauncherCNMac"
rm -rf /private/tmp/xivcn-dmg-release
swift build -c release --scratch-path /private/tmp/xivcn-dmg-release --disable-sandbox --sdk "$sdk" \
  -debug-info-format none \
  -Xswiftc -module-cache-path -Xswiftc /private/tmp/xivcn-module-cache
test -x "$product"
cp "$product" "$build/Contents/MacOS/XIVLauncherCNMac"
chmod +x "$build/Contents/MacOS/XIVLauncherCNMac"

iconset="$scratch/XIVCN Mac Launcher.iconset"
mkdir -p "$iconset"
icon_source="${XIVCN_ICON_PATH:-$root/Assets/FFXIVCNMacIconSource.png}"
test -f "$icon_source"
test "$(sips -g hasAlpha "$icon_source" | awk '/hasAlpha/ {print $2}')" = "yes"
# The project asset is a transparent foreground mark with no baked-in rounded
# tile. macOS supplies the only outer icon container, avoiding the undersized
# nested-card appearance produced by the old ICO artwork.
for spec in \
  "16 icon_16x16.png" "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
  set -- $spec
  sips -z "$1" "$1" "$icon_source" --out "$iconset/$2" >/dev/null
done
icon_file="FFXIVCNMac-${launcher_version}.icns"
icon_path="$build/Contents/Resources/$icon_file"
if ! iconutil -c icns "$iconset" -o "$icon_path" 2>/dev/null; then
  # Some Command Line Tools builds reject otherwise valid legacy iconsets.
  # Build the same representations through a multi-image TIFF as the system
  # fallback, then convert that container to a real ICNS file.
  icon_tiffs="$scratch/icon-tiffs"
  mkdir -p "$icon_tiffs"
  for name in icon_16x16 icon_16x16@2x icon_32x32@2x icon_128x128 icon_128x128@2x icon_256x256@2x icon_512x512@2x; do
    sips -s format tiff "$iconset/$name.png" --out "$icon_tiffs/$name.tiff" >/dev/null
  done
  tiffutil -cat \
    "$icon_tiffs/icon_16x16.tiff" "$icon_tiffs/icon_16x16@2x.tiff" \
    "$icon_tiffs/icon_32x32@2x.tiff" "$icon_tiffs/icon_128x128.tiff" \
    "$icon_tiffs/icon_128x128@2x.tiff" "$icon_tiffs/icon_256x256@2x.tiff" \
    "$icon_tiffs/icon_512x512@2x.tiff" -out "$scratch/XIVLauncherCNMac.tiff" >/dev/null
  tiff2icns "$scratch/XIVLauncherCNMac.tiff" "$icon_path"
fi
test -f "$icon_path"

cat > "$build/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>XIVLauncherCNMac</string>
<key>CFBundleIdentifier</key><string>cn.xivlaunchermac</string>
<key>CFBundleName</key><string>$app_name</string>
<key>CFBundleDisplayName</key><string>$app_name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$launcher_version</string>
<key>CFBundleShortVersionString</key><string>$launcher_version</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSRequiresNativeExecution</key><true/>
<key>CFBundleIconFile</key><string>$icon_file</string>
</dict></plist>
PLIST

/usr/bin/plutil -lint "$build/Contents/Info.plist" >/dev/null

# Sign the x86_64 bridge and its self-contained runtime dylibs before sealing
# the arm64 GUI bundle. Rosetta launches this nested helper at login/launch.
find "$build/Contents/Resources/core-bridge" -type f \( -name '*.dylib' -o -name 'XIVLauncherCN.CoreBridge' \) \
  -exec /usr/bin/codesign --force --sign - --timestamp=none {} \;

# Refuse to sign an App whose runtime no longer matches the international XOM
# 5.4.2 golden files.
"$root/scripts/verify-runtime-provenance.sh" "$build"

# Seal the complete local test bundle so Info.plist and resources are covered.
# Formal distribution will replace this ad-hoc identity with Developer ID and
# notarization only after the user explicitly approves release.
/usr/bin/codesign --force --sign - --timestamp=none "$build"
/usr/bin/codesign --verify --deep --strict "$build"

# CI/local audit mode stops after the signed App. It is intentionally used
# before the real CN game test so a DMG cannot be mistaken for a validated
# release artifact.
if test "${XIVCN_BUILD_APP_ONLY:-0}" = "1"; then
  echo "$build"
  exit 0
fi

rm -f "$out/$dmg_basename.dmg"
staging_dmg="$scratch/dmg-root"
mkdir -p "$staging_dmg"
ln -s "/Applications" "$staging_dmg/Applications"
cp -R "$build" "$staging_dmg/$app_name.app"
cp "$icon_path" "$staging_dmg/.VolumeIcon.icns"
/usr/bin/SetFile -a V "$staging_dmg/.VolumeIcon.icns"
/usr/bin/SetFile -a C "$staging_dmg"
cp "$root/docs/卸载说明.txt" "$staging_dmg/卸载说明.txt"
rw_dmg="$scratch/$dmg_basename-rw.dmg"
dmg_mount="$scratch/dmg-mount"
mkdir -p "$dmg_mount"
dmg_attached=0
trap 'if test "$dmg_attached" = "1"; then hdiutil detach "$dmg_mount" >/dev/null 2>&1 || true; fi' EXIT HUP INT TERM
if hdiutil create -volname "$app_name" -srcfolder "$staging_dmg" -ov -format UDRW "$rw_dmg" >/dev/null 2>&1; then
  hdiutil attach -nobrowse -readwrite -mountpoint "$dmg_mount" "$rw_dmg" >/dev/null
  dmg_attached=1
  # Runtime hashes were verified before the App bundle was sealed. Do not
  # repeat pre-signature byte comparisons after the DMG is mounted.
  /usr/bin/SetFile -a V "$dmg_mount/.VolumeIcon.icns"
  /usr/bin/SetFile -a C "$dmg_mount"
  hdiutil detach "$dmg_mount" >/dev/null
  dmg_attached=0
  hdiutil convert "$rw_dmg" -ov -format UDZO -o "$out/$dmg_basename.dmg" >/dev/null
  echo "$out/$dmg_basename.dmg"
else
  echo "hdiutil is unavailable in this sandbox; App bundle created at $build" >&2
fi
