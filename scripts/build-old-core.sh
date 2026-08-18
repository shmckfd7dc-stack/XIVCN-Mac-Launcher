#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
handover_root=$(CDPATH= cd -- "$root/../.." && pwd)
source_root="$handover_root/legacy-core/source"
reference_bundle="$handover_root/legacy-core/original-bundle"
output_root="${1:-$root/.old-core-build}"
dotnet_default="$handover_root/toolchain/dotnet-sdk-x64/dotnet"
dotnet_x64="${XIVCN_DOTNET_X64:-$dotnet_default}"

test -x "$dotnet_x64"
test -d "$source_root"
test -d "$reference_bundle"

rm -rf "$output_root"
mkdir -p "$output_root"

# The source projects intentionally retain the original Core reference layout.
# Build them in the same order as the handover validation, then stage the
# source-built assemblies over the audited dependency bundle.
for project in \
  "$source_root/DeviceId/DeviceId.csproj" \
  "$source_root/XIVLauncher.Common/XIVLauncher.Common.csproj" \
  "$source_root/XIVLauncher.Common.Unix/XIVLauncher.Common.Unix.csproj"; do
  arch -x86_64 "$dotnet_x64" build "$project" -c Release --no-restore -v:minimal
done

cp -R "$reference_bundle/." "$output_root/"

for item in \
  "DeviceId:DeviceId" \
  "XIVLauncher.Common:XIVLauncher.Common" \
  "XIVLauncher.Common.Unix:XIVLauncher.Common.Unix"; do
  project=${item%%:*}
  assembly=${item#*:}
  built="$source_root/$project/bin/Release/net10.0/$assembly.dll"
  test -f "$built"
  cp "$built" "$output_root/$assembly.dll"
  if test -f "${built%.dll}.pdb"; then
    cp "${built%.dll}.pdb" "$output_root/$assembly.pdb"
  fi
done

test -f "$output_root/XIVLauncher.Common.dll"
test -f "$output_root/XIVLauncher.Common.Unix.dll"
printf '%s\n' "$output_root"
