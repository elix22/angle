# From-source ANGLE for Apple (macOS/iOS) — Metal backend. (P1.1b / P1.7)
#
# Models the Urho3D reference `Source/ThirdParty/angle/CMakeLists.txt` (elix22, 2019):
# compile a curated ANGLE source set + committed generated files directly with CMake,
# with NO GN. That sidesteps ANGLE's GN limitation that a standalone iOS build "is only
# possible from a Chromium checkout" — we never invoke GN here.
#
# The current ANGLE tree (2.1.x) has drifted far from the 2019 file lists, so this GLOBs
# the live source dirs and excludes the backends/tests we don't build, instead of pinning
# stale explicit lists. Keep the Urho3D structure: per-group sources, Metal `.mm` with ARC
# off, ANGLE_ENABLE_METAL, and the include set.
#
# ── STATUS: builds + runs on macOS and iOS (helmet on-device). One static `angle` lib
#    exposing the same angle::EGL / angle::GLESv2 targets the prebuilt path uses.
#
# ── Inputs (defaulted by the top-level CMake when TNR_ANGLE_FROM_SOURCE=ON):
#    ANGLE_SRC  ANGLE source root = the pinned `thirdparty/angle` submodule (a1c0c7a) with
#               its dep submodules initialised: third_party/{glslang,spirv-cross,spirv-tools,
#               spirv-headers,vulkan-headers}/src + third_party/zlib.
#    ANGLE_GEN  committed generated headers = `cmake/angle/gen` (angle_commit.h,
#               ANGLEShaderProgramVersion.h). The Metal internal shaders compile at runtime
#               (we don't define ANGLE_METAL_HAS_PREBUILT_INTERNAL_SHADERS) — no metallib needed.
cmake_minimum_required(VERSION 3.20)
project(angle C CXX OBJCXX)   # C for the vendored zlib the program cache needs

if(NOT ANGLE_SRC OR NOT EXISTS "${ANGLE_SRC}/src/libANGLE/Context.cpp")
    message(FATAL_ERROR "ANGLE_SRC='${ANGLE_SRC}' invalid — init the submodule: "
                        "git submodule update --init thirdparty/angle && "
                        "git -C thirdparty/angle submodule update --init --depth 1 "
                        "third_party/glslang/src third_party/spirv-cross/src "
                        "third_party/spirv-headers/src third_party/spirv-tools/src "
                        "third_party/vulkan-headers/src third_party/zlib")
endif()
if(NOT ANGLE_GEN OR NOT EXISTS "${ANGLE_GEN}/angle_commit.h")
    message(FATAL_ERROR "ANGLE_GEN='${ANGLE_GEN}' invalid — expected angle_commit.h "
                        "(run tools/gen-angle.sh once to stage thirdparty/angle-gen).")
endif()

# ── source groups (glob live tree) ───────────────────────────────────────────────
file(GLOB_RECURSE ANGLE_COMMON ${ANGLE_SRC}/src/common/*.cpp)
file(GLOB_RECURSE ANGLE_IMG    ${ANGLE_SRC}/src/image_util/*.cpp)
file(GLOB_RECURSE ANGLE_CORE   ${ANGLE_SRC}/src/libANGLE/*.cpp)
file(GLOB_RECURSE ANGLE_TR     ${ANGLE_SRC}/src/compiler/translator/*.cpp)
file(GLOB_RECURSE ANGLE_PP     ${ANGLE_SRC}/src/compiler/preprocessor/*.cpp)
file(GLOB         ANGLE_GLES   ${ANGLE_SRC}/src/libGLESv2/*.cpp)
file(GLOB         ANGLE_EGL    ${ANGLE_SRC}/src/libEGL/*.cpp)
# gpu_info_util defines IsAMD/GetPreferredDeviceString/GetVendorIDFromMetalDeviceRegistryID etc.
file(GLOB         ANGLE_GPUINFO ${ANGLE_SRC}/src/gpu_info_util/*.cpp ${ANGLE_SRC}/src/gpu_info_util/*.mm)

# Drop tests/mocks/fuzzers/benchmarks everywhere.
foreach(v ANGLE_COMMON ANGLE_IMG ANGLE_CORE ANGLE_TR ANGLE_PP ANGLE_GLES ANGLE_EGL ANGLE_GPUINFO)
    list(FILTER ${v} EXCLUDE REGEX "_unittest|_mock|_fuzzer|/fuzz/|_perf|_benchmark|test_utils|gmock|gtest|_test\\.")
endforeach()

# Optional features we don't build (each pulls a dep we don't vendor): frame capture/replay
# and JSON serialization (rapidjson), and the Rust-based MSL/WGSL translator IR (generated
# *.rs.h). The Metal backend uses the glslang+spirv-cross (SPIR-V->MSL) path instead. We
# re-add the no-op capture/serialize *stubs* below (core references them). Only the real
# astc-encoder-backed decompressor is dropped — loadimage_astc.cpp + the NoOp stub stay.
foreach(v ANGLE_COMMON ANGLE_IMG ANGLE_CORE ANGLE_TR ANGLE_PP ANGLE_GLES ANGLE_EGL)
    list(FILTER ${v} EXCLUDE REGEX "/capture/|/serializer/|AstcDecompressor\\.cpp")
    # Keep translator/msl/ — the Metal backend's DIRECT MSL translator (defines sh::mtl::*
    # consts ProgramExecutableMtl references). It does NOT use the Rust IR (translator/ir,
    # needs generated *.rs.h) — drop only that and the WGSL/WebGPU translator.
    list(FILTER ${v} EXCLUDE REGEX "/translator/ir/|/translator/wgsl/|TranslatorWGSL")
    list(FILTER ${v} EXCLUDE REGEX "/d3d|HLSL|_d3d")
endforeach()

# gpu_info_util: keep the Apple variants only.
list(FILTER ANGLE_GPUINFO EXCLUDE REGEX "_android|_fuchsia|_linux|_win|_x11|_libpci|_vulkan")
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    list(FILTER ANGLE_GPUINFO EXCLUDE REGEX "_macos")
else()
    list(FILTER ANGLE_GPUINFO EXCLUDE REGEX "_ios")
endif()

# Re-add the no-op capture/serialize stubs the /capture/ + _mock excludes removed. Context.cpp
# and Program.cpp reference SerializeContextToString / FrameCaptureShared unconditionally; the
# mocks satisfy them without rapidjson.
list(APPEND ANGLE_CORE
    ${ANGLE_SRC}/src/libANGLE/capture/FrameCapture_mock.cpp
    ${ANGLE_SRC}/src/libANGLE/capture/serialize_mock.cpp)

# libANGLE core: keep base renderer/ + we add Metal (+null) explicitly below.
# Drop the other backends and the OpenCL/WebGPU paths.
list(FILTER ANGLE_CORE EXCLUDE REGEX "/renderer/(d3d|gl|vulkan|wgpu|cl|metal|null)/")
list(FILTER ANGLE_CORE EXCLUDE REGEX "/renderer/cl_|/renderer/CL|/CL[A-Za-z]+Impl|/renderer/wgpu|dxgi")
# OpenCL front-end objects live directly under libANGLE/ (CLBuffer.cpp, cl_utils.cpp,
# validationCL.cpp, …) — we don't build CL. Also drop the Vulkan ICD helper in common/.
list(FILTER ANGLE_CORE   EXCLUDE REGEX "/libANGLE/CL|/libANGLE/cl_|validationCL")
# common/vulkan (ICD helper) and common/gl (desktop-GL/CGL loaders — CGL needs OpenGL.h,
# absent on iOS) are unused by the Metal backend.
list(FILTER ANGLE_COMMON EXCLUDE REGEX "/common/vulkan/|/common/gl/")

# translator: Metal goes GLSL->SPIR-V(glslang)->MSL(spirv-cross), so keep the SPIR-V/Vulkan
# and MSL outputs; drop the HLSL (D3D) outputs.
list(FILTER ANGLE_TR EXCLUDE REGEX "HLSL")

# libGLESv2/EGL: drop the CL entry points and the .def/rc noise (globbed .cpp only anyway).
list(FILTER ANGLE_GLES EXCLUDE REGEX "entry_points_cl|cl_|/cl/|egl_context_lock")

# common: pick the right Apple system_utils; drop the other OSes.
# system_utils_apple.cpp is the SHARED Apple impl (GetExecutablePath/Directory,
# GetCurrentSystemTime, SetCurrentThreadName) — kept on both macOS and iOS. Only the
# GetSharedLibraryExtension variant differs: system_utils_mac.cpp ("dylib") vs
# system_utils_ios.cpp ("framework"). Drop the other OS's variant here. (The stale
# system_utils_ios.mm — an .mm the *.mm glob picks up below — is handled with ANGLE_MM.)
list(FILTER ANGLE_COMMON EXCLUDE REGEX "system_utils_(win|win32|winuwp|linux|fuchsia)")
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    list(FILTER ANGLE_COMMON EXCLUDE REGEX "system_utils_mac\\.")
else()
    list(FILTER ANGLE_COMMON EXCLUDE REGEX "system_utils_ios")
endif()

# Metal backend (.mm + .cpp) and Apple driver utils (.mm) — ARC OFF (Urho3D flags).
file(GLOB ANGLE_METAL
    ${ANGLE_SRC}/src/libANGLE/renderer/metal/*.mm
    ${ANGLE_SRC}/src/libANGLE/renderer/metal/*.cpp)
list(APPEND ANGLE_METAL
    ${ANGLE_SRC}/src/libANGLE/renderer/driver_utils_mac.mm
    ${ANGLE_SRC}/src/libANGLE/renderer/driver_utils_ios.mm)
# null backend (tiny; ANGLE_ENABLE_NULL) for bring-up.
file(GLOB ANGLE_NULL ${ANGLE_SRC}/src/libANGLE/renderer/null/*.cpp)

# Any translator/common .mm (e.g. TranslatorMSL/Metal bits) need ARC off too.
file(GLOB_RECURSE ANGLE_MM
    ${ANGLE_SRC}/src/compiler/translator/*.mm
    ${ANGLE_SRC}/src/common/*.mm)
# The *.mm glob re-adds the stale system_utils_ios.mm, whose GetExecutablePath/
# GetExecutableDirectory duplicate the shared system_utils_apple.cpp (kept above on both
# OSes) — that's the "duplicate symbol" the linker hits. Its GetSharedLibraryExtension also
# clashes with system_utils_ios.cpp, and its only unique symbol (GetCurrentTime) isn't in
# system_utils.h. Drop it on both platforms so the .mm set matches the OS-filtered .cpp set.
list(FILTER ANGLE_MM EXCLUDE REGEX "system_utils_ios")
# The .mm/null globs need the same test/mock exclusion as the .cpp groups above.
foreach(v ANGLE_METAL ANGLE_NULL ANGLE_MM)
    list(FILTER ${v} EXCLUDE REGEX "_unittest|_mock|_fuzzer|_perf|_benchmark|gmock|gtest|_test\\.")
endforeach()
set(ANGLE_APPLE_MM ${ANGLE_METAL} ${ANGLE_MM} ${ANGLE_GPUINFO})   # gpu_info has SystemInfo_apple/macos.mm
set_source_files_properties(${ANGLE_APPLE_MM} PROPERTIES COMPILE_FLAGS
    "-fno-objc-arc -Wno-unguarded-availability -Wno-nullability-completeness")

# ── vendored deps for the Metal shader path (GLSL->SPIR-V->MSL) ──────────────────
file(GLOB SPIRV_CROSS ${ANGLE_SRC}/third_party/spirv-cross/src/*.cpp)
list(FILTER SPIRV_CROSS EXCLUDE REGEX "/main\\.cpp$|_test|_fuzz")   # drop the CLI/tests
file(GLOB_RECURSE GLSLANG
    ${ANGLE_SRC}/third_party/glslang/src/glslang/*.cpp
    ${ANGLE_SRC}/third_party/glslang/src/SPIRV/*.cpp
    ${ANGLE_SRC}/third_party/glslang/src/OGLCompilersDLL/*.cpp)
list(FILTER GLSLANG EXCLUDE REGEX "OSDependent/Windows|OSDependent/Web|StandAlone|SpvTools|/HLSL/")

# glslang needs a generated version header "glslang/build_info.h" (from build_info.py).
set(GLSLANG_GEN ${CMAKE_CURRENT_BINARY_DIR}/glslang-gen)
add_custom_command(
    OUTPUT  ${GLSLANG_GEN}/glslang/build_info.h
    COMMAND ${CMAKE_COMMAND} -E make_directory ${GLSLANG_GEN}/glslang
    COMMAND python3 ${ANGLE_SRC}/third_party/glslang/src/build_info.py
            ${ANGLE_SRC}/third_party/glslang/src
            -i ${ANGLE_SRC}/third_party/glslang/src/build_info.h.tmpl
            -o ${GLSLANG_GEN}/glslang/build_info.h
    VERBATIM)

# ANGLE's program-blob cache compresses with chromium-zlib. Compile the vendored zlib
# (portable C path — exclude the SIMD TUs that need arch macros) + the portable wrapper.
file(GLOB ZLIB ${ANGLE_SRC}/third_party/zlib/*.c)
list(FILTER ZLIB EXCLUDE REGEX "_simd|crc_folding|infcover|minigzip|example|/test/|/contrib/")
list(APPEND ZLIB ${ANGLE_SRC}/third_party/zlib/google/compression_utils_portable.cc)
# xxhash (program-cache hashing, XXH3_*) is a .c the *.cpp globs miss.
list(APPEND ZLIB ${ANGLE_SRC}/src/common/third_party/xxhash/xxhash.c)

# ── the library ──────────────────────────────────────────────────────────────────
add_library(angle STATIC
    ${ANGLE_COMMON} ${ANGLE_IMG} ${ANGLE_CORE} ${ANGLE_TR} ${ANGLE_PP}
    ${ANGLE_GLES} ${ANGLE_EGL} ${ANGLE_GPUINFO} ${ANGLE_METAL} ${ANGLE_NULL} ${ANGLE_MM}
    ${SPIRV_CROSS} ${GLSLANG} ${ZLIB}
    ${GLSLANG_GEN}/glslang/build_info.h)   # generated header (ties the custom command)

target_compile_definitions(angle PRIVATE
    ANGLE_STANDALONE_BUILD
    ANGLE_ENABLE_METAL ANGLE_ENABLE_NULL
    ANGLE_ENABLE_ESSL ANGLE_ENABLE_GLSL          # ESSL/GLSL translator paths
    ANGLE_ENABLE_APPLE_QUARTZ_CORE
    # We link statically and call gl*/egl* directly — neuter the DLL export/import macros.
    "GL_APICALL=" "GL_APIENTRY=" "EGLAPI=" "EGLAPIENTRY="
    "ANGLE_EXPORT=" "ANGLE_UTIL_EXPORT=" "ANGLE_PLATFORM_EXPORT=")

target_include_directories(angle
    PUBLIC  ${ANGLE_SRC}/include
    PRIVATE ${ANGLE_SRC}/src
            ${ANGLE_GEN}                          # angle_commit.h, ANGLEShaderProgramVersion.h, mtl metallib hdr
            ${GLSLANG_GEN}                         # generated glslang/build_info.h
            ${ANGLE_SRC}/src/common/base
            ${ANGLE_SRC}/src/common/third_party/xxhash
            ${ANGLE_SRC}/third_party/zlib             # zlib.h for the vendored zlib + wrapper
            ${ANGLE_SRC}/third_party/zlib/google
            ${ANGLE_SRC}/third_party/spirv-cross/src
            ${ANGLE_SRC}/third_party/glslang/src
            ${ANGLE_SRC}/third_party/spirv-headers/src/include
            ${ANGLE_SRC}/third_party/spirv-tools/src/include
            ${ANGLE_SRC}/third_party/vulkan-headers/src/include)

# ANGLE 2.1.x requires C++20 (common/span.h uses std::same_as etc.).
set_target_properties(angle PROPERTIES
    CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON
    OBJCXX_STANDARD 20)
# Frameworks the Metal backend + gpu_info pull in (propagated to consumers via PUBLIC).
# c++ so our C hosts (tri_egl.c etc.) pull in libc++ when linking this C++ static lib.
target_link_libraries(angle PUBLIC
    "-framework Metal" "-framework QuartzCore" "-framework IOSurface"
    "-framework Foundation" "-framework CoreGraphics" "-framework Accelerate" objc c++)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    target_link_libraries(angle PUBLIC "-framework UIKit")
else()
    target_link_libraries(angle PUBLIC "-framework Cocoa" "-framework IOKit" "-framework CoreServices")
endif()

# Consumer-facing targets identical to cmake/angle-prebuilt.cmake, so nothing downstream
# changes when switching between prebuilt and from-source ANGLE.
add_library(angle::GLESv2 ALIAS angle)
add_library(angle::EGL    ALIAS angle)
