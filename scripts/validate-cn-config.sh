#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
grep -Eq 'cas\.sdo\.com|n1\.cas\.sdo\.com' "$root/Sources/XIVLauncherCNMac/Models.swift"
grep -Eq '100001900|791000814|8847|54994' "$root/Sources/XIVLauncherCNMac/Models.swift"
grep -Eq 'dalamud-dis\.atmoomen\.top' "$root/Sources/XIVLauncherCNMac/Models.swift"
if grep -REin 'dxvk' "$root/Sources/XIVLauncherCNMac"; then
  echo 'DXVK control leaked into product sources' >&2
  exit 1
fi
if grep -REin 'patch-dl\.ffxiv\.com|frontier\.ffxiv\.com|goatcorp.*dalamud|dalamud\.official' "$root/Sources/XIVLauncherCNMac"; then
  echo 'international endpoint leaked into CN runtime' >&2
  exit 1
fi
echo 'CN endpoint validation passed'
