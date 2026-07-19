@echo off
setlocal enabledelayedexpansion
rem Build ANGLE (D3D11 backend) for Windows x64: DLLs + import libs, Release.
rem
rem Part of the threejs-native-runtime prebuilt-SDK pipeline (phase 9). Unlike the
rem Apple builds (no-GN CMake subset), a Windows D3D11 ANGLE needs the official
rem GN + depot_tools build. This script is adapted from mmozeiko/build-angle's
rem battle-tested recipe (MIT) but builds THIS repo's PINNED commit from THIS fork's
rem checkout, so the published binaries' provenance stays entirely in-house.
rem
rem   build-windows.cmd <angle-src-dir> <out-dir>
rem     angle-src-dir  a git checkout of the pinned ANGLE commit
rem     out-dir        scratch + artifact destination
rem
rem Output: <out-dir>\angle-windows-x64-Release.tar.gz
rem   lib\{libEGL.dll,libEGL.dll.lib,libGLESv2.dll,libGLESv2.dll.lib,d3dcompiler_47.dll}
rem   include\{EGL,GLES,GLES2,GLES3,KHR}   — the layout cmake/angle-prebuilt.cmake expects.

set SRC=%~f1
set OUT=%~f2
if "%SRC%" equ "" ( echo usage: build-windows.cmd ^<angle-src-dir^> ^<out-dir^> & exit /b 2 )
if "%OUT%" equ "" ( echo usage: build-windows.cmd ^<angle-src-dir^> ^<out-dir^> & exit /b 2 )
if not exist "%OUT%" mkdir "%OUT%"

set SED="C:\Program Files\Git\usr\bin\sed.exe"

rem ---- depot_tools (GN/gclient/autoninja come from here) --------------------------
set PATH=%OUT%\depot_tools;%PATH%
set DEPOT_TOOLS_WIN_TOOLCHAIN=0
if not exist "%OUT%\depot_tools" (
  call git clone --depth=1 --no-tags --single-branch https://chromium.googlesource.com/chromium/tools/depot_tools.git "%OUT%\depot_tools" || exit /b 1
)

rem ---- deps sync at the pinned commit ---------------------------------------------
pushd "%SRC%"
python.exe scripts\bootstrap.py || exit /b 1
rem Drop the huge deps the D3D11 build never touches (catapult/dawn/llvm/SwiftShader/
rem VK-GL-CTS) — same trim as mmozeiko's recipe; halves the sync.
%SED% -i.bak -e "/'third_party\/catapult'\: /,+3d" -e "/'third_party\/dawn'\: /,+3d" -e "/'third_party\/llvm\/src'\: /,+3d" -e "/'third_party\/SwiftShader'\: /,+3d" -e "/'third_party\/VK-GL-CTS\/src'\: /,+3d" DEPS || exit /b 1
call gclient sync -f -D -R || exit /b 1

rem ---- GN configure: D3D11 only, Release, static CRT ------------------------------
call gn gen out/x64 --args="target_cpu=""x64"" angle_build_all=false is_debug=false angle_has_frame_capture=false angle_enable_gl=false angle_enable_vulkan=false angle_enable_wgpu=false angle_enable_d3d9=false angle_enable_null=false use_siso=false" || exit /b 1
rem /MT: no VC runtime redistribution problem for SDK consumers (proven by the
rem community builds this repo's Windows CI consumed since P5).
%SED% -i.bak -e "s/\/MD/\/MT/" build\config\win\BUILD.gn || exit /b 1
call autoninja --offline -C out/x64 libEGL libGLESv2 || exit /b 1
popd

rem ---- stage + assert --------------------------------------------------------------
set STAGE=%OUT%\stage-windows
if exist "%STAGE%" rmdir /s /q "%STAGE%"
mkdir "%STAGE%\lib" "%STAGE%\include"

for %%F in (libEGL.dll libEGL.dll.lib libGLESv2.dll libGLESv2.dll.lib d3dcompiler_47.dll) do (
  copy /y "%SRC%\out\x64\%%F" "%STAGE%\lib\" 1>nul || ( echo FAIL: %%F missing from the build & exit /b 1 )
)
for %%D in (EGL GLES GLES2 GLES3 KHR) do (
  xcopy /S /I /Q /Y "%SRC%\include\%%D" "%STAGE%\include\%%D" 1>nul || exit /b 1
)
del /Q /S "%STAGE%\include\*.clang-format" "%STAGE%\include\*.md" 1>nul 2>nul

for /f "tokens=*" %%i in ('git -C "%SRC%" rev-parse HEAD') do set SRCCOMMIT=%%i
(
  echo source-commit: %SRCCOMMIT%
  echo config: Release x64 D3D11 DLLs + import libs, /MT, GN build ^(depot_tools^), recipe adapted from mmozeiko/build-angle
) > "%STAGE%\MANIFEST.txt"

tar -C "%STAGE%" -czf "%OUT%\angle-windows-x64-Release.tar.gz" . || exit /b 1
echo artifact: %OUT%\angle-windows-x64-Release.tar.gz
