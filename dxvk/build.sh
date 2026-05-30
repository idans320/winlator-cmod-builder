#!/bin/bash -e

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$PACKAGE_DIR")"
WORKDIR="$PACKAGE_DIR/workdir"
PKG_NAME="dxvk"

DXVK_REPO=$(yq ".${PKG_NAME}.repo" "$ROOT_DIR/packages.yml")
DXVK_BRANCH=$(yq ".${PKG_NAME}.branch" "$ROOT_DIR/packages.yml")
LLVM_MINGW_VER=$(yq ".${PKG_NAME}.mingw_ver" "$ROOT_DIR/packages.yml")
HOST_ARCH="$(uname -m)"
LLVM_MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VER}/llvm-mingw-${LLVM_MINGW_VER}-ucrt-ubuntu-22.04-${HOST_ARCH}.tar.xz"

echo -e "${green}=== DXVK GPLAsync-LowLatency Builder (aarch64 PE) ===${nocolor}"

# --- Toolchain setup ---
TOOLCHAIN_DIR="$WORKDIR/toolchain"
TOOLCHAIN_BIN="$TOOLCHAIN_DIR/bin"
FEX_TOOLCHAIN="$ROOT_DIR/fexcore/workdir/toolchain/bin"

if [ -x "$FEX_TOOLCHAIN/aarch64-w64-mingw32-clang" ]; then
    TOOLCHAIN_BIN="$FEX_TOOLCHAIN"
    echo -e "${green}llvm-mingw found in fexcore cache${nocolor}"
elif command -v aarch64-w64-mingw32-clang &>/dev/null; then
    TOOLCHAIN_BIN="$(dirname "$(command -v aarch64-w64-mingw32-clang)")"
    echo -e "${green}llvm-mingw found in PATH${nocolor}"
elif [ -x "$TOOLCHAIN_BIN/aarch64-w64-mingw32-clang" ]; then
    echo -e "${green}llvm-mingw found in cache${nocolor}"
else
    echo "Downloading llvm-mingw ${LLVM_MINGW_VER}..."
    mkdir -p "$TOOLCHAIN_DIR"
    curl -sL "$LLVM_MINGW_URL" | xz -d | tar -C "$TOOLCHAIN_DIR" --strip-components=1 -xf -
    echo -e "${green}llvm-mingw cached${nocolor}"
fi

CC="$TOOLCHAIN_BIN/aarch64-w64-mingw32-clang"
CXX="$TOOLCHAIN_BIN/aarch64-w64-mingw32-clang++"
AR="$TOOLCHAIN_BIN/aarch64-w64-mingw32-llvm-ar"
STRIP="$TOOLCHAIN_BIN/aarch64-w64-mingw32-strip"
WINDRES="$TOOLCHAIN_BIN/aarch64-w64-mingw32-windres"

if [ ! -x "$CC" ]; then
    echo -e "${red}aarch64-w64-mingw32-clang not found${nocolor}"
    exit 1
fi

if [ ! -x "$AR" ]; then
    AR="$TOOLCHAIN_BIN/aarch64-w64-mingw32-ar"
fi

echo "CC  = $($CC --version 2>/dev/null | head -1 || echo aarch64-w64-mingw32-clang)"

# --- Clone DXVK ---
mkdir -p "$WORKDIR"
if [ ! -d "$WORKDIR/dxvk" ]; then
    echo "Cloning DXVK GPLAsync-LowLatency (branch: $DXVK_BRANCH)..."
    git clone --recurse-submodules --depth 1 --branch "$DXVK_BRANCH" "$DXVK_REPO" "$WORKDIR/dxvk" 2>&1
fi

DXVK_VERSION=$(cd "$WORKDIR/dxvk" && grep -oP "version\s*:\s*'\K[^']+" meson.build | head -1)
DXVK_VERSION_NAME="${DXVK_VERSION}-arm64ec-gplasync"
echo -e "${green}DXVK version: $DXVK_VERSION_NAME${nocolor}"

# --- Generate Meson cross-file ---
CROSSFILE="$WORKDIR/dxvk-cross-aarch64.txt"
cat > "$CROSSFILE" << CROSSEOF
[binaries]
c     = '$CC'
cpp   = '$CXX'
ar    = '$AR'
strip = '$STRIP'
windres = '$WINDRES'

[properties]
needs_exe_wrapper = true

[built-in options]
c_args = ['-mcpu=oryon-1', '-O3', '-ffast-math', '-funroll-loops', '-fomit-frame-pointer', '-ffunction-sections', '-fdata-sections']
cpp_args = ['-mcpu=oryon-1', '-O3', '-ffast-math', '-funroll-loops', '-fomit-frame-pointer', '-ffunction-sections', '-fdata-sections', '-std=c++17']
c_link_args = ['-fuse-ld=lld', '-Wl,--gc-sections']
cpp_link_args = ['-fuse-ld=lld', '-Wl,--gc-sections']

[host_machine]
system = 'windows'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
CROSSEOF

echo "Cross-file: $CROSSFILE"

# --- Configure & Build ---
BUILD_DIR="$WORKDIR/build"
INSTALL_DIR="$WORKDIR/install"

if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    echo "Configuring Meson (aarch64-w64-mingw32)..."
    meson setup "$BUILD_DIR" "$WORKDIR/dxvk" \
        --cross-file "$CROSSFILE" \
        --buildtype release \
        --strip \
        --prefix "$INSTALL_DIR" \
        --bindir "x64" \
        --libdir "x64" \
        -Db_ndebug=if-release \
        &> "$WORKDIR/meson_log"
fi

echo "Building..."
set -o pipefail
ninja -C "$BUILD_DIR" -j"$(nproc)" 2>&1 | tee "$WORKDIR/build_log"
BUILD_RC=${PIPESTATUS[0]}
set +o pipefail
if [ "$BUILD_RC" -ne 0 ]; then
    echo -e "${red}Build failed (exit code $BUILD_RC)${nocolor}"
    echo "Check $WORKDIR/build_log"
    exit 1
fi

ninja -C "$BUILD_DIR" install

# --- Package ---
echo "Packaging..."
PKGDIR="$WORKDIR/package"
mkdir -p "$PKGDIR/system32"

cp -v "$INSTALL_DIR/x64/"*.dll "$PKGDIR/system32/"

DLL_COUNT=$(find "$PKGDIR/system32" -name "*.dll" 2>/dev/null | wc -l)
if [ "$DLL_COUNT" -eq 0 ]; then
    echo -e "${red}Build failed: no DLLs found in build output${nocolor}"
    echo "Check $WORKDIR/build_log"
    exit 1
fi
echo -e "${green}Found $DLL_COUNT DLL(s)${nocolor}"
ls -la "$PKGDIR/system32/"

# --- Config.json ---
cat > "$PKGDIR/Config.json" << 'CONFEOF'
{
  "DXVK_LOG_LEVEL": "none",
  "DXVK_ASYNC": "1",
  "DXVK_FRAME_PACE": "low-latency"
}
CONFEOF

# --- profile.json ---
DLL_FILES=""
COUNTER=0
TOTAL=$(find "$PKGDIR/system32" -name "*.dll" | wc -l)
for dll in "$PKGDIR/system32"/*.dll; do
    [ -f "$dll" ] || continue
    COUNTER=$((COUNTER + 1))
    dll_name="$(basename "$dll")"
    COMMA=","
    [ "$COUNTER" -eq "$TOTAL" ] && COMMA=""
    DLL_FILES+=$'\n'"    {\"source\": \"system32/$dll_name\", \"target\": \"\${system32}/$dll_name\"}$COMMA"
done

cat > "$PKGDIR/profile.json" << PROEOF
{
  "type": "DXVK",
  "versionName": "$DXVK_VERSION_NAME",
  "versionCode": 0,
  "description": "DXVK GPLAsync-LowLatency $DXVK_VERSION — Oryon optimized (aarch64 PE)",
  "files": [$DLL_FILES
  ]
}
PROEOF

OUTPUT_FILE=$(yq ".${PKG_NAME}.output" "$ROOT_DIR/packages.yml" | sed "s/{version}/$DXVK_VERSION/")
WCP_FILE="$ROOT_DIR/$OUTPUT_FILE"
cd "$PKGDIR" && tar -cf - system32/ profile.json Config.json | xz -9e > "$WCP_FILE"
echo -e "${green}Package created: $WCP_FILE${nocolor}"
ls -lh "$WCP_FILE"
