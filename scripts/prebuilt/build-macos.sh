#!/usr/bin/env bash
# Build ANGLE (Metal backend) for macOS: STATIC, UNIVERSAL (arm64 + x86_64), Release.
#
# Part of the threejs-native-runtime prebuilt-SDK pipeline (phase 9). Uses the runtime's
# proven no-GN CMake build (scripts/prebuilt/cmake — a synced copy of the runtime's
# cmake/angle/CMakeLists.txt): a curated ANGLE source subset compiled with plain CMake,
# sidestepping GN/depot_tools/Chromium entirely. CI publishes the result as a GitHub
# Release asset; the runtime's fetch-libs step downloads it into gitignored libs/.
# Users can run this locally for the identical output.
#
#   scripts/prebuilt/build-macos.sh [<angle-src-dir>] [<out-dir>]
#     angle-src-dir  defaults to this script's repo root
#     out-dir        defaults to <angle-src-dir>/out-prebuilt
#
# Output: <out-dir>/angle-macos-universal-static-Release.tar.gz
#   containing lib/libangle.a (universal) + include/ (ANGLE public headers).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$(cd "$HERE/../.." && pwd)}"
OUT="${2:-$SRC/out-prebuilt}"
BUILD="$OUT/build-macos"
STAGE="$OUT/stage-macos"
rm -rf "$BUILD" "$STAGE"

# The curated build needs only these dep submodules — NOT the full gclient tree.
git -C "$SRC" submodule update --init --depth 1 \
  third_party/glslang/src third_party/spirv-cross/src third_party/spirv-headers/src \
  third_party/spirv-tools/src third_party/vulkan-headers/src third_party/zlib

cmake -S "$HERE/cmake" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DANGLE_SRC="$SRC" \
  -DANGLE_GEN="$HERE/cmake/gen"
cmake --build "$BUILD" --parallel

LIB="$BUILD/libangle.a"
[ -f "$LIB" ] || { echo "FAIL: $LIB missing after build"; exit 1; }
ARCHS=$(lipo -archs "$LIB")
echo "libangle.a archs: $ARCHS"
case "$ARCHS" in *arm64*) ;; *) echo "FAIL: arm64 slice missing"; exit 1 ;; esac
case "$ARCHS" in *x86_64*) ;; *) echo "FAIL: x86_64 slice missing"; exit 1 ;; esac

mkdir -p "$STAGE/lib"
cp "$LIB" "$STAGE/lib/libangle.a"
cp -R "$SRC/include" "$STAGE/include"
{ echo "source-commit: $(git -C "$SRC" rev-parse HEAD)"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "config: Release static universal (arm64;x86_64), Metal backend, no-GN CMake"
} > "$STAGE/MANIFEST.txt"

tar -C "$STAGE" -czf "$OUT/angle-macos-universal-static-Release.tar.gz" .
echo "artifact: $OUT/angle-macos-universal-static-Release.tar.gz ($(du -h "$OUT/angle-macos-universal-static-Release.tar.gz" | cut -f1))"
