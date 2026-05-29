#!/bin/bash -e

green='\033[0;32m'
red='\033[0;31m'
yellow='\033[0;33m'
nocolor='\033[0m'

PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$PACKAGE_DIR")"
WORKDIR="$PACKAGE_DIR/workdir"

# --- Source config ---
# Valve's wine with Proton patches (ESYNC, FSYNC, LAA, game fixes)
WINE_REPO="https://github.com/ValveSoftware/wine.git"
WINE_BRANCH="proton_11.0"

LLVM_MINGW_VER="20260519"
HOST_ARCH="$(uname -m)"
LLVM_MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VER}/llvm-mingw-${LLVM_MINGW_VER}-ucrt-ubuntu-22.04-${HOST_ARCH}.tar.xz"

echo -e "${green}=== Wine 11 ARM64 Proton Builder ===${nocolor}"

# --- Toolchain ---
TOOLCHAIN_DIR=""

if [ -x "$ROOT_DIR/fexcore/workdir/toolchain/bin/aarch64-w64-mingw32-clang" ]; then
    TOOLCHAIN_DIR="$ROOT_DIR/fexcore/workdir/toolchain"
elif command -v aarch64-w64-mingw32-clang &>/dev/null; then
    TOOLCHAIN_DIR="$(dirname "$(dirname "$(command -v aarch64-w64-mingw32-clang)")")"
else
    TOOLCHAIN_DIR="$WORKDIR/toolchain"
fi

TOOLCHAIN_BIN="$TOOLCHAIN_DIR/bin"

if [ ! -x "$TOOLCHAIN_BIN/aarch64-w64-mingw32-clang" ]; then
    echo "Downloading llvm-mingw ${LLVM_MINGW_VER}..."
    mkdir -p "$TOOLCHAIN_DIR"
    curl -sL "$LLVM_MINGW_URL" | xz -d | tar -C "$TOOLCHAIN_DIR" --strip-components=1 -xf -
    echo -e "${green}llvm-mingw cached${nocolor}"
fi

export PATH="$TOOLCHAIN_BIN:$PATH"

# winebuild needs 'dlltool' (not just llvm-dlltool) for PE import libraries
if [ ! -x "$TOOLCHAIN_BIN/dlltool" ]; then
    ln -sf llvm-dlltool "$TOOLCHAIN_BIN/dlltool" 2>/dev/null || true
fi
export DLLTOOL="$TOOLCHAIN_BIN/llvm-dlltool"

HOST_CC="${HOST_CC:-clang}"
HOST_CXX="${HOST_CXX:-clang++}"

# If Android NDK is available, use it. NDK clang with -target aarch64-linux-gnu
# still produces Android (bionic) binaries with /system/bin/linker64.
if [ -n "$NDK" ] && [ -x "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]; then
    NDK_CLANG="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
    HOST_CC="$NDK_CLANG/clang"
    HOST_CXX="$NDK_CLANG/clang++"
    HOST_TARGET="aarch64-linux-gnu"
    HOST_INTERP="/system/bin/linker64"
    echo -e "${green}Using Android NDK compiler (bionic)${nocolor}"
else
    HOST_TARGET="aarch64-linux-gnu"
    HOST_INTERP="/data/data/com.winlator.cmod/files/imagefs/lib/ld-linux-aarch64.so.1"
fi

if ! command -v "$HOST_CC" &>/dev/null; then
    echo -e "${red}Host compiler $HOST_CC not found${nocolor}"
    exit 1
fi

echo "HOST CC = $($HOST_CC --version | head -1)"
echo "PE CC   = $(aarch64-w64-mingw32-clang --version | head -1)"

# --- Clone Wine (Valve + Proton patches) ---
mkdir -p "$WORKDIR"
if [ ! -d "$WORKDIR/wine" ]; then
    echo "Cloning Valve wine (branch: $WINE_BRANCH)..."
    git clone --depth 1 --branch "$WINE_BRANCH" "$WINE_REPO" "$WORKDIR/wine" 2>&1
fi

WINE_VERSION=$(cd "$WORKDIR/wine" && git rev-parse --short HEAD)
echo -e "${green}Wine Proton version: $WINE_VERSION${nocolor}"

# --- Generate auto-generated files ---
GEN_MARKER="$WORKDIR/.generated"
if [ ! -f "$GEN_MARKER" ]; then
    cd "$WORKDIR/wine"
    echo "Generating auto-generated sources..."

    # 1. Vulkan headers + loader thunks (from Vulkan-Headers XML)
    echo "  → make_vulkan..."
    python3 dlls/winevulkan/make_vulkan 2>&1 || echo "  make_vulkan completed with warnings"

    # 2. Server protocol headers
    echo "  → make_requests..."
    ./tools/make_requests 2>&1 || true

    # 3. Syscall headers — auto-generated from wine spec files
    echo "  → make_specfiles..."
    perl tools/make_specfiles 2>&1 || true

    # 4. Regenerate configure + Makefile.in via autoconf
    echo "  → autoreconf..."
    autoreconf -fi 2>&1 || { autoconf 2>&1 || true; autoheader 2>&1 || true; }

    # 5. AMD AGS needs drm.h — create stub in include path
    if [ ! -f "include/drm.h" ] && [ ! -f "include/drm/drm.h" ]; then
        mkdir -p include/drm
        touch include/drm/drm.h
        touch include/drm/drm_mode.h
        touch include/drm/drm_fourcc.h
        ln -sf ../include/drm/drm.h include/drm.h
    fi

    touch "$GEN_MARKER"
    echo -e "${green}Source generation complete${nocolor}"
fi

# --- Configure ---
CONF_MARKER="$WORKDIR/.configured"

if [ ! -f "$CONF_MARKER" ]; then
    echo "Configuring Wine (aarch64-linux-gnu)..."
    cd "$WORKDIR/wine"

    ORYON_FLAGS="-mcpu=oryon-1 -O3 -ffast-math -funroll-loops -fomit-frame-pointer"
    ORYON_FLAGS="$ORYON_FLAGS -fwrapv -fno-strict-aliasing"
    ORYON_FLAGS="$ORYON_FLAGS -ffunction-sections -fdata-sections"
    ORYON_FLAGS="$ORYON_FLAGS -ffixed-x18"

    ./configure \
        --host=aarch64-linux-gnu \
        --enable-archs=arm64ec,aarch64,i386,x86_64 \
        --with-mingw=clang \
        --prefix=/opt/wine \
        --disable-win16 \
        --disable-tests \
        --enable-build-id \
        --without-x \
        --without-opengl \
        --without-wayland \
        --without-dbus \
        --without-udev \
        --without-cups \
        --without-sane \
        --without-gstreamer \
        --without-freetype \
        --without-fontconfig \
        --without-coreaudio \
        --without-capi \
        --without-gphoto \
        --without-inotify \
        --without-krb5 \
        --without-opencl \
        --without-oss \
        --without-pcap \
        --without-sdl \
        --without-usb \
        --without-v4l2 \
        --without-pcsclite \
        --without-ffmpeg \
        CC="$HOST_CC" \
        CXX="$HOST_CXX" \
        CFLAGS="-target $HOST_TARGET $ORYON_FLAGS" \
        CXXFLAGS="-target $HOST_TARGET $ORYON_FLAGS -std=c++17" \
        LDFLAGS="-target $HOST_TARGET -fuse-ld=/usr/bin/ld.lld -Wl,--gc-sections" \
        &> "$WORKDIR/configure_log"

    touch "$CONF_MARKER"
    echo -e "${green}Configure complete${nocolor}"
fi

# --- Build Wine ---
echo "Building Wine..."
cd "$WORKDIR/wine"
set -o pipefail
# Use reduced parallelism for triple-arch builds to avoid OOM
WINE_JOBS="${WINE_JOBS:-1}"
make -j"$WINE_JOBS" -k 2>&1 | tee "$WORKDIR/build_log"
BUILD_RC=${PIPESTATUS[0]}
set +o pipefail
if [ "$BUILD_RC" -ne 0 ]; then
    echo -e "${yellow}Wine build completed with some errors (exit $BUILD_RC)${nocolor}"
    echo "Checking for critical binaries..."
fi

# Check critical binaries
if [ ! -f "tools/wine/wine" ] && [ ! -f "wine" ] && [ ! -f "loader/wine" ]; then
    echo -e "${red}Build failed: wine binary not found${nocolor}"
    exit 1
fi
echo -e "${green}Wine binary built successfully${nocolor}"

# --- Install ---
echo "Installing..."
PKGDIR="$WORKDIR/package"
make install DESTDIR="$PKGDIR" -i 2>&1 | tee "$WORKDIR/install_log"

if [ ! -f "$PKGDIR/opt/wine/bin/wine" ] && [ ! -f "$PKGDIR/opt/wine/bin/wine64" ]; then
    echo -e "${red}Install failed: wine binary not found${nocolor}"
    exit 1
fi
echo -e "${green}Install complete${nocolor}"

# --- Patch ELF interpreter ---
echo "Patching ELF interpreter..."
ROOTFS_INTERP="${WINE_INTERP:-$HOST_INTERP}"
find "$PKGDIR" -type f -executable 2>/dev/null | while read -r elf; do
    [ -f "$elf" ] || continue
    if file "$elf" 2>/dev/null | grep -q "ELF"; then
        patchelf --set-interpreter "$ROOTFS_INTERP" "$elf" 2>/dev/null || true
    fi
done

# --- Strip binaries ---
echo "Stripping..."
find "$PKGDIR" -type f \( -name "*.exe" -o -name "*.dll" -o -name "*.sys" \) 2>/dev/null | while read -r pe; do
    [ -f "$pe" ] || continue
    "$TOOLCHAIN_BIN/aarch64-w64-mingw32-strip" "$pe" 2>/dev/null || true
done
find "$PKGDIR" -type f -executable 2>/dev/null | while read -r elf; do
    [ -f "$elf" ] || continue
    if file "$elf" 2>/dev/null | grep -q "ELF"; then
        "$TOOLCHAIN_BIN/llvm-strip" "$elf" 2>/dev/null || true
    fi
done

# --- Config.json (runtime tuning) ---
cat > "$PKGDIR/Config.json" << 'CONFEOF'
{
  "env": {
    "WINEESYNC": "1",
    "WINEFSYNC": "1",
    "WINE_LARGE_ADDRESS_AWARE": "1",
    "PROTON_USEWOW64": "1",
    "WINEDEBUG": "-all",
    "WINE_CPU_TOPOLOGY": "8:0,1,2,3,4,5,6,7",
    "WINE_FULLSCREEN_FSR": "1",
    "WINE_FULLSCREEN_FSR_STRENGTH": "2",
    "DXVK_LOG_LEVEL": "none",
    "DXVK_ASYNC": "1",
    "VKD3D_DEBUG": "none",
    "VKD3D_SHADER_DEBUG": "none",
    "VKD3D_CONFIG": "no_upload_hvv"
  }
}
CONFEOF

# --- profile.json ---
cat > "$PKGDIR/profile.json" << PROEOF
{
  "type": "Wine",
  "versionName": "Wine 11 Proton",
  "versionCode": $(cd "$WORKDIR/wine" && git log -1 --format=%ct 2>/dev/null || date +%s),
  "description": "Wine 11 Proton $WINE_VERSION — Oryon optimized, ESYNC/FSYNC, ARM64EC",
  "files": [
    {"source": "opt/wine/bin", "target": "\${wine}/bin"},
    {"source": "opt/wine/lib", "target": "\${wine}/lib"},
    {"source": "opt/wine/share", "target": "\${wine}/share"}
  ]
}
PROEOF

# --- Package ---
WCP_FILE="$ROOT_DIR/wine-arm64-${WINE_VERSION}.wcp"
echo "Packaging..."
cd "$PKGDIR" && tar -cf - opt/ profile.json Config.json | xz -9e > "$WCP_FILE"
echo -e "${green}Package created: $WCP_FILE${nocolor}"
ls -lh "$WCP_FILE"
