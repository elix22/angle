#!/usr/bin/env bash
# Build ANGLE (Metal backend) for iOS: STATIC xcframework, Release.
#
# Part of the threejs-native-runtime prebuilt-SDK pipeline (phase 9). Two builds of the
# same proven no-GN CMake subset (scripts/prebuilt/cmake) — device (arm64) and simulator
# (arm64 + x86_64) — packaged with `xcodebuild -create-xcframework` into ONE static
# ANGLE.xcframework (§0.2: static slices keep dead-stripping and the on-device-proven
# `libangle.a` linking; the xcframework is just the container).
#
#   scripts/prebuilt/build-ios.sh [<angle-src-dir>] [<out-dir>]
#
# Output: <out-dir>/angle-ios-static-Release.tar.gz
#   containing ANGLE.xcframework/{ios-arm64,ios-arm64_x86_64-simulator}/{libangle.a,Headers}
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$(cd "$HERE/../.." && pwd)}"
OUT="${2:-$SRC/out-prebuilt}"
STAGE="$OUT/stage-ios"
rm -rf "$STAGE" "$OUT/build-ios-device" "$OUT/build-ios-sim"

git -C "$SRC" submodule update --init --depth 1 \
  third_party/glslang/src third_party/spirv-cross/src third_party/spirv-headers/src \
  third_party/spirv-tools/src third_party/vulkan-headers/src third_party/zlib

# Memory, not cores, bounds these builds (same lesson as build-macos.sh: unbounded
# --parallel OOM-killed the 7 GB hosted runner). The simulator build compiles two
# arches per clang job; keep the same conservative mem/3GB bound for both.
NCPU=$(sysctl -n hw.ncpu)
MEMGB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
JOBS="${ANGLE_BUILD_JOBS:-$(( MEMGB / 3 < NCPU ? MEMGB / 3 : NCPU ))}"
[ "$JOBS" -ge 1 ] || JOBS=1
echo "build-ios: ${NCPU} cpus, ${MEMGB} GB ram -> ${JOBS} parallel jobs"

# build <builddir> <sysroot> <archs>  — one static Release libangle.a per SDK.
build_slice() {
  local dir="$1" sysroot="$2" archs="$3"
  cmake -S "$HERE/cmake" -B "$dir" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$archs" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DANGLE_SRC="$SRC" \
    -DANGLE_GEN="$HERE/cmake/gen"
  cmake --build "$dir" --parallel "$JOBS"
  [ -f "$dir/libangle.a" ] || { echo "FAIL: $dir/libangle.a missing after build"; exit 1; }
}

build_slice "$OUT/build-ios-device" iphoneos            "arm64"
build_slice "$OUT/build-ios-sim"    iphonesimulator     "arm64;x86_64"

# Each slice must actually carry the archs it claims — fail here, not on a user's Mac.
DEV_ARCHS=$(lipo -archs "$OUT/build-ios-device/libangle.a")
SIM_ARCHS=$(lipo -archs "$OUT/build-ios-sim/libangle.a")
echo "device archs: $DEV_ARCHS / simulator archs: $SIM_ARCHS"
case "$DEV_ARCHS" in *arm64*) ;; *) echo "FAIL: device arm64 slice missing"; exit 1 ;; esac
case "$SIM_ARCHS" in *arm64*) ;; *) echo "FAIL: simulator arm64 slice missing"; exit 1 ;; esac
case "$SIM_ARCHS" in *x86_64*) ;; *) echo "FAIL: simulator x86_64 slice missing"; exit 1 ;; esac

mkdir -p "$STAGE"
xcodebuild -create-xcframework \
  -library "$OUT/build-ios-device/libangle.a" -headers "$SRC/include" \
  -library "$OUT/build-ios-sim/libangle.a"    -headers "$SRC/include" \
  -output "$STAGE/ANGLE.xcframework"
# The consumer imports by slice path — pin the layout here so a rename fails CI.
[ -f "$STAGE/ANGLE.xcframework/ios-arm64/libangle.a" ] || { echo "FAIL: device slice path changed"; exit 1; }
[ -f "$STAGE/ANGLE.xcframework/ios-arm64_x86_64-simulator/libangle.a" ] || { echo "FAIL: simulator slice path changed"; exit 1; }

{ echo "source-commit: $(git -C "$SRC" rev-parse HEAD)"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "config: Release static xcframework (device arm64; sim arm64+x86_64), Metal backend, no-GN CMake, min iOS 13.0"
} > "$STAGE/MANIFEST.txt"

tar -C "$STAGE" -czf "$OUT/angle-ios-static-Release.tar.gz" .
echo "artifact: $OUT/angle-ios-static-Release.tar.gz ($(du -h "$OUT/angle-ios-static-Release.tar.gz" | cut -f1))"
