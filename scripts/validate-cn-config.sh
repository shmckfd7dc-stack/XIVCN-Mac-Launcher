#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rg -q 'cas\.sdo\.com|n1\.cas\.sdo\.com' "$root/Sources/XIVLauncherCNMac/Models.swift"
rg -q '100001900|791000814|8847|54994' "$root/Sources/XIVLauncherCNMac/Models.swift"
rg -q 'dalamud-dis\.atmoomen\.top' "$root/Sources/XIVLauncherCNMac/Models.swift"
if rg -n -i 'dxvk' "$root/Sources/XIVLauncherCNMac"; then
  echo 'DXVK control leaked into product sources' >&2
  exit 1
fi
if rg -n -i 'patch-dl\.ffxiv\.com|frontier\.ffxiv\.com|goatcorp.*dalamud|dalamud\.official' "$root/Sources/XIVLauncherCNMac"; then
  echo 'international endpoint leaked into CN runtime' >&2
  exit 1
fi
echo 'CN endpoint validation passed'
