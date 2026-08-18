#!/bin/sh
set -eu

app=${1:?usage: verify-runtime-provenance.sh /path/to/FFXIV\ CN\ MAC.app}
resources="$app/Contents/Resources"
dxmt="$resources/dxmt"

hash_is() {
  expected=$1
  file=$2
  test -f "$file"
  actual=$(shasum -a 256 "$file" | awk '{print $1}')
  test "$actual" = "$expected" || {
    echo "runtime provenance mismatch: $file" >&2
    echo "expected=$expected" >&2
    echo "actual=$actual" >&2
    exit 1
  }
}

hash_is 617cf79d79d14b7d4041446aa3ec4658a257945d4bab127626eb5973f9da5b18 "$dxmt/d3d11.dll"
hash_is d26b51f7c662a9189377952a6ca6d427fdb108a4302c5877b1253aef0cfc8849 "$dxmt/dxgi.dll"
hash_is e994847e01a6f1e4cbdc5a864616ac262f67ee4f14db194984661a8d927ab7f4 "$resources/d3dcompiler/d3dcompiler_47.dll"
hash_is a7ae15660d00eb0b15e76902736721d2cc7450fed811dfbde879a07336ae65cd "$resources/sdo/sdologinentry64.dll"

# The executable must consume the original XOM tree in-place. An archive
# alone is insufficient because a launcher could silently unpack or substitute
# another runtime at startup.
app_wine="$resources/wine"
hash_is 6eab5e116b5de38f4051d2ef8eb474eab98f60cac7456126ae6f97aa90ac1e27 "$app_wine/bin/wine"
hash_is 73aff10a0325e88ded94e281ef600bde09afc56f6dbf412f18107d611171ac61 "$app_wine/bin/wineserver"
hash_is 7a566043a042f0aa46cee47a22801bc0969a5aa45bc4a766d3f0397fae6c96a2 "$app_wine/lib/wine/x86_64-windows/winemetal.dll"
hash_is b304461c614cba77072aa4b9ea0693308b39b40cde65322e7134603c8dc0032d "$app_wine/lib/wine/x86_64-unix/winemetal.so"
hash_is b0b400afe276e3b726d9313f69ff57f371228da17ce49c7efe2a270f163c7934 "$app_wine/lib/wine/x86_64-unix/winemac.so"
hash_is da408d321f96bde324aaa60872a4911a227820ad3189641fed1090c12fc864de "$app_wine/lib/wine/x86_64-unix/ntdll.so"
hash_is d551db073db0cbb2b80f789ba91142dfddd28c63a35c2b377646efb925e667b8 "$app_wine/lib/wine/x86_64-unix/win32u.so"

echo "international XOM 5.4.2 runtime provenance verified"
