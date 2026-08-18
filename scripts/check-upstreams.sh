#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$project_root/UPSTREAMS.json"
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/xivcn-upstream.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT HUP INT TERM
changed=0

json_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$manifest"
}

check_git_head() {
  label=$1
  url=$2
  reviewed=$3
  current=$(git ls-remote "$url" HEAD | awk 'NR == 1 { print $1 }')
  test -n "$current"
  printf '%-22s reviewed=%s upstream=%s\n' "$label" "$reviewed" "$current"
  if test "$current" != "$reviewed"; then changed=1; fi
}

check_git_head "XIV on Mac" "$(json_value base)" "$(json_value xomBaseCommit)"
check_git_head "CN launcher (Atmo)" "$(json_value cnWindowsReference)" "$(json_value cnWindowsReferenceCommit)"
check_git_head "CN launcher (Otter)" "$(json_value cnLauncherReference)" "$(json_value cnLauncherReferenceCommit)"
check_git_head "Global launcher" "$(json_value internationalWindowsReference)" "$(json_value internationalWindowsReferenceCommit)"
check_git_head "XOM Wine" "$(json_value wine.source)" "$(json_value wine.sourceCommit)"

curl -fsSL "https://api.github.com/repos/3Shain/dxmt/releases/latest" -o "$probe_dir/dxmt.json"
dxmt_latest=$(/usr/bin/plutil -extract tag_name raw -o - "$probe_dir/dxmt.json")
dxmt_reviewed=$(json_value dxmt.latestReviewedOfficialRelease)
printf '%-22s reviewed=%s upstream=%s\n' "DXMT release" "$dxmt_reviewed" "$dxmt_latest"
if test "$dxmt_latest" != "$dxmt_reviewed"; then changed=1; fi

if test "$changed" -ne 0; then
  echo "Upstream changes require review. No source or binary was modified automatically." >&2
  exit 2
fi
echo "All tracked upstream revisions match the reviewed manifest."
