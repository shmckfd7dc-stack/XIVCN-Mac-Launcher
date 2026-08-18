#!/bin/sh
set -eu

if test "$#" -ne 3; then
  echo "usage: $0 /path/to/xom-wine-root /path/to/xom-dxmt-root /path/to/wineprefix" >&2
  exit 2
fi

wine_root=$1
dxmt_root=$2
prefix=$3
wine="$wine_root/bin/wine"
wineserver="$wine_root/bin/wineserver"
windows="$dxmt_root"
unix="$wine_root/lib/wine/x86_64-unix"
system32="$prefix/drive_c/windows/system32"

hash_is() {
  expected=$1
  file=$2
  test -f "$file"
  actual=$(shasum -a 256 "$file" | awk '{print $1}')
  test "$actual" = "$expected" || {
    echo "hash mismatch: $file" >&2
    echo "expected=$expected actual=$actual" >&2
    exit 1
  }
}

test -x "$wine"
test -x "$wineserver"
test -d "$prefix"
mkdir -p "$system32"
# The international XOM graphics step stages the two native overrides in the
# active Prefix before the loader is exercised. This probe performs that same
# fixture setup from the hash-locked Resources/dxmt directory; it does not
# invoke a second Wine backend.
cp "$windows/d3d11.dll" "$system32/d3d11.dll"
cp "$windows/dxgi.dll" "$system32/dxgi.dll"
hash_is 6eab5e116b5de38f4051d2ef8eb474eab98f60cac7456126ae6f97aa90ac1e27 "$wine"
hash_is 73aff10a0325e88ded94e281ef600bde09afc56f6dbf412f18107d611171ac61 "$wineserver"
hash_is 617cf79d79d14b7d4041446aa3ec4658a257945d4bab127626eb5973f9da5b18 "$windows/d3d11.dll"
hash_is d26b51f7c662a9189377952a6ca6d427fdb108a4302c5877b1253aef0cfc8849 "$windows/dxgi.dll"
hash_is 7a566043a042f0aa46cee47a22801bc0969a5aa45bc4a766d3f0397fae6c96a2 "$wine_root/lib/wine/x86_64-windows/winemetal.dll"
hash_is b304461c614cba77072aa4b9ea0693308b39b40cde65322e7134603c8dc0032d "$unix/winemetal.so"
hash_is b0b400afe276e3b726d9313f69ff57f371228da17ce49c7efe2a270f163c7934 "$wine_root/lib/wine/x86_64-unix/winemac.so"
hash_is da408d321f96bde324aaa60872a4911a227820ad3189641fed1090c12fc864de "$wine_root/lib/wine/x86_64-unix/ntdll.so"
hash_is d551db073db0cbb2b80f789ba91142dfddd28c63a35c2b377646efb925e667b8 "$wine_root/lib/wine/x86_64-unix/win32u.so"
hash_is 617cf79d79d14b7d4041446aa3ec4658a257945d4bab127626eb5973f9da5b18 "$system32/d3d11.dll"
hash_is d26b51f7c662a9189377952a6ca6d427fdb108a4302c5877b1253aef0cfc8849 "$system32/dxgi.dll"

# Confirm the PE and Mach-O dependency contracts in the exact files being
# probed.  File names and hashes alone do not prove the loader relationship.
objdump -p "$windows/d3d11.dll" | rg -qi 'DLL Name:[[:space:]]+DXGI[.]DLL'
objdump -p "$windows/d3d11.dll" | rg -qi 'DLL Name:[[:space:]]+winemetal[.]dll'
objdump -p "$windows/dxgi.dll" | rg -qi 'DLL Name:[[:space:]]+winemetal[.]dll'
otool -L "$unix/winemetal.so" | rg -q '@rpath/winemac[.]so'
otool -L "$unix/winemetal.so" | rg -q '@rpath/ntdll[.]so'
otool -L "$wine_root/lib/wine/x86_64-unix/winemac.so" | rg -q '@rpath/win32u[.]so'

probe_log=$(mktemp /private/tmp/xivcn-xom-loader.XXXXXX)
trap 'rm -f "$probe_log"' EXIT HUP INT TERM

# Keep every Wine helper on the same Prefix and the same loader search path.
# In particular, invoking a bare `wineserver -k` would target the user's
# default Prefix instead of this probe Prefix and could leave the real probe
# process alive.
# This is a real Wine loader probe, not a mock process. rundll32 asks Wine to
# load DXMT's d3d11 entry point; DYLD_PRINT_LIBRARIES may record the matching
# Unix winemetal.so that the same Wine process opens. Run it only
# while this Prefix has no active game: the bounded cleanup stops this
# launcher's own probe wineserver and never touches another Prefix.
set +e
env WINEPREFIX="$prefix" \
    WINEMSYNC=1 WINEESYNC=0 WINEFSYNC=0 \
    WINEDLLPATH="$wine_root/lib/wine" \
    WINEDLLOVERRIDES='msquic=,mscoree=n,b;d3d11=n;dxgi=n,b' \
    WINEDEBUG=+loaddll DYLD_PRINT_LIBRARIES=1 \
    "$wine" rundll32.exe d3d11.dll,D3D11CreateDevice >"$probe_log" 2>&1 &
probe_pid=$!
# `wine` can hand the Windows process to wineserver and return before the
# child has emitted its loader trace. Wait for the actual DXMT module marker,
# not only for the wrapper PID, otherwise a valid load can be inspected too
# early and reported as a false negative.
for _ in $(seq 1 150); do
  if rg -qi 'd3d11[.]dll' "$probe_log"; then break; fi
  sleep 0.2
done
env WINEPREFIX="$prefix" WINEMSYNC=1 WINEESYNC=0 WINEFSYNC=0 \
    WINEDLLPATH="$wine_root/lib/wine" \
    "$wineserver" -k >/dev/null 2>&1 || true
env WINEPREFIX="$prefix" WINEMSYNC=1 WINEESYNC=0 WINEFSYNC=0 \
    WINEDLLPATH="$wine_root/lib/wine" \
    "$wineserver" -w >/dev/null 2>&1 || true
wait "$probe_pid"
probe_status=$?
set -e

if rg -q 'err:module:import_dll.*not found|loader_init.*c0000135' "$probe_log"; then
  echo "XOM loader probe failed: a DXMT dependency was not found" >&2
  rg 'import_dll|loader_init' "$probe_log" >&2 || true
  exit 1
fi
for marker in \
  'winemetal[.]dll' \
  'dxgi[.]dll' \
  'd3d11[.]dll' \
  'winemetal[.]so'; do
  # The Windows modules are mandatory loader observations.  The Unix module
  # is loaded lazily by Wine's Metal driver and some Wine builds do not emit a
  # DYLD_PRINT_LIBRARIES line for that dlopen, so its hash/path validation
  # above is authoritative when the trace omits the optional line.
  if test "$marker" = 'winemetal[.]so' && ! rg -qi "$marker" "$probe_log"; then
    echo "XOM loader probe note: winemetal.so was not printed by DYLD; path/hash were verified" >&2
    continue
  fi
  if ! rg -qi "$marker" "$probe_log"; then
    echo "XOM loader probe did not observe $marker" >&2
    echo "--- Wine loader diagnostics ---" >&2
    rg -i 'loaddll|winemetal|dxgi|d3d11|import_dll|loader_init' "$probe_log" >&2 || true
    exit 1
  fi
done

echo "XOM loader probe passed (rundll32 status $probe_status; XOM Resources/dxmt d3d11/dxgi -> Wine winemetal.dll; winemetal.so hash/path verified)"
