#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sdk="${XIVCN_SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
scratch="${XIVCN_TEST_SCRATCH:-/private/tmp/xivcn-test-build}"
frameworks="$scratch/out/Products/Debug/PackageFrameworks"

test -d "$sdk"
rm -rf "$scratch"
mkdir -p /private/tmp/xivcn-test-tmp /private/tmp/xivcn-module-cache "$frameworks"

export SDKROOT="$sdk"
export TMPDIR=/private/tmp/xivcn-test-tmp
export SWIFT_MODULE_CACHE_PATH=/private/tmp/xivcn-module-cache
export CLANG_MODULE_CACHE_PATH=/private/tmp/xivcn-module-cache
export SWIFTPM_ENABLE_CACHING=0

cd "$root"
swift build --build-tests --scratch-path "$scratch" --disable-sandbox --sdk "$sdk" \
  -Xswiftc -target -Xswiftc arm64-apple-macos26.0 \
  -Xswiftc -module-cache-path -Xswiftc /private/tmp/xivcn-module-cache \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing

# Command Line Tools ships Swift Testing outside the system dyld cache. Full
# Xcode resolves this automatically; copy the two CLT runtime pieces only when
# they are available so the same tests run in either environment.
testing_framework=/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework
testing_interop=/Library/Developer/CommandLineTools/Library/Developer/usr/lib/lib_TestingInterop.dylib
if test -d "$testing_framework"; then
  rm -rf "$frameworks/Testing.framework"
  cp -R "$testing_framework" "$frameworks/Testing.framework"
fi
if test -f "$testing_interop"; then
  cp "$testing_interop" "$scratch/out/Products/Debug/lib_TestingInterop.dylib"
fi

swift test --skip-build --scratch-path "$scratch" --disable-sandbox --sdk "$sdk" \
  -Xswiftc -target -Xswiftc arm64-apple-macos26.0 \
  -Xswiftc -module-cache-path -Xswiftc /private/tmp/xivcn-module-cache
