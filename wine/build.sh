#!/bin/bash -e

green='\033[0;32m'
red='\033[0;31m'
yellow='\033[0;33m'
nocolor='\033[0m'

PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$PACKAGE_DIR")"
WORKDIR="$PACKAGE_DIR/workdir"
PKG_NAME="wine"

WINE_REPO=$(yq ".${PKG_NAME}.repo" "$ROOT_DIR/packages.yml")
WINE_BRANCH=$(yq ".${PKG_NAME}.branch" "$ROOT_DIR/packages.yml")
LLVM_MINGW_VER=$(yq ".${PKG_NAME}.mingw_ver" "$ROOT_DIR/packages.yml")
SDK_VER=$(yq ".${PKG_NAME}.sdk_ver" "$ROOT_DIR/packages.yml")

PRESET=$(yq ".${PKG_NAME}.preset" "$ROOT_DIR/packages.yml")
CPU_FLAGS=""
CXX_EXTRA=""
LD_EXTRA=""
if [ -n "$PRESET" ] && [ "$PRESET" != "null" ]; then
    PRESET_FILE="$ROOT_DIR/presets/${PRESET}.yml"
    if [ -f "$PRESET_FILE" ]; then
        CPU_FLAGS=$(yq ".cflags" "$PRESET_FILE")
        CXX_EXTRA=$(yq ".cxxflags" "$PRESET_FILE")
        LD_EXTRA=$(yq ".ldflags" "$PRESET_FILE")
        echo -e "${green}Preset: $PRESET${nocolor}"
    else
        echo -e "${yellow}Preset file not found: $PRESET_FILE${nocolor}"
    fi
fi

echo -e "${green}=== Wine 11 ARM64 Proton Builder ===${nocolor}"

HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" = "aarch64" ]; then
    IS_AARCH64=1
else
    IS_AARCH64=0
fi

# --- llvm-mingw toolchain ---
LLVM_MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VER}/llvm-mingw-${LLVM_MINGW_VER}-ucrt-ubuntu-22.04-${HOST_ARCH}.tar.xz"
TOOLCHAIN_DIR="$WORKDIR/toolchain"

if [ -x "$ROOT_DIR/fexcore/workdir/toolchain/bin/aarch64-w64-mingw32-clang" ]; then
    TOOLCHAIN_DIR="$ROOT_DIR/fexcore/workdir/toolchain"
elif command -v aarch64-w64-mingw32-clang &>/dev/null; then
    TOOLCHAIN_DIR="$(dirname "$(dirname "$(command -v aarch64-w64-mingw32-clang)")")"
fi

TOOLCHAIN_BIN="$TOOLCHAIN_DIR/bin"
if [ ! -x "$TOOLCHAIN_BIN/aarch64-w64-mingw32-clang" ]; then
    echo "Downloading llvm-mingw ${LLVM_MINGW_VER}..."
    mkdir -p "$TOOLCHAIN_DIR"
    curl -sL "$LLVM_MINGW_URL" | xz -d | tar -C "$TOOLCHAIN_DIR" --strip-components=1 -xf -
    echo -e "${green}llvm-mingw cached${nocolor}"
fi

export PATH="$TOOLCHAIN_BIN:$PATH"
if [ ! -x "$TOOLCHAIN_BIN/dlltool" ]; then
    ln -sf llvm-dlltool "$TOOLCHAIN_BIN/dlltool" 2>/dev/null || true
fi
export DLLTOOL="$TOOLCHAIN_BIN/llvm-dlltool"

# --- NDK compiler setup ---
NDK_CLANG="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
export TOOLCHAIN="$NDK_CLANG"
export TARGET="aarch64-linux-android${SDK_VER}"

export CC="${TOOLCHAIN}/${TARGET}-clang"
export AS="$CC"
export CXX="${TOOLCHAIN}/${TARGET}-clang++"
export AR="${TOOLCHAIN}/llvm-ar"
export LD="${TOOLCHAIN}/ld"
export RANLIB="${TOOLCHAIN}/llvm-ranlib"
export STRIP="${TOOLCHAIN}/llvm-strip"

export DEPS="${DEPS:-}"
if [ -z "$DEPS" ] && [ -f "$WORKDIR/termux-rootfs/data/data/com.termux/files/usr/.deps-ready" ]; then
    export DEPS="$WORKDIR/termux-rootfs/data/data/com.termux/files/usr"
    echo -e "${green}Using cached Termux deps: $DEPS${nocolor}"
fi
export RUNTIME_PATH="/data/data/com.termux/files/usr"
export install_dir="$WORKDIR/wine-install"

export PKG_CONFIG_LIBDIR="${DEPS:+$DEPS/lib/pkgconfig:$DEPS/share/pkgconfig}"
export ACLOCAL_PATH="${DEPS:+$DEPS/lib/aclocal:$DEPS/share/aclocal}"
SYSROOT_FLAGS="--sysroot=${TOOLCHAIN}/../sysroot"
export CPPFLAGS="${DEPS:+-I$DEPS/include }${SYSROOT_FLAGS}"

C_OPTS="-Wno-declaration-after-statement -Wno-implicit-function-declaration -Wno-int-conversion"
if [ -n "$CPU_FLAGS" ]; then
    C_OPTS="$C_OPTS $CPU_FLAGS"
fi

export CFLAGS="$C_OPTS"
export CXXFLAGS="${CXX_EXTRA:-$C_OPTS}"
export LDFLAGS="${DEPS:+-L$DEPS/lib }${LD_EXTRA} -Wl,-rpath=${RUNTIME_PATH}/lib"

if [ -n "$DEPS" ]; then
    export FREETYPE_CFLAGS="-I$DEPS/include/freetype2"
    export PULSE_CFLAGS="-I$DEPS/include/pulse"
    export PULSE_LIBS="-L$DEPS/lib/pulseaudio -lpulse"
    export SDL2_CFLAGS="-I$DEPS/include/SDL2"
    export SDL2_LIBS="-L$DEPS/lib -lSDL2"
    export FONTCONFIG_LIBS="-L$DEPS/lib -lfontconfig -lfreetype -lexpat"
    export X_CFLAGS="-I$DEPS/include"
    export X_LIBS="-lX11 -lXext -landroid-sysvshm"
    export GSTREAMER_CFLAGS="-I$DEPS/include/gstreamer-1.0 -I$DEPS/include/glib-2.0 -I$DEPS/lib/glib-2.0/include -I$DEPS/glib-2.0/include -I$DEPS/lib/gstreamer-1.0/include"
    export GSTREAMER_LIBS="-L$DEPS/lib -lgstgl-1.0 -lgstapp-1.0 -lgstvideo-1.0 -lgstaudio-1.0 -lglib-2.0 -lgobject-2.0 -lgio-2.0 -lgsttag-1.0 -lgstbase-1.0 -lgstreamer-1.0"
else
    NIX_X11_CFLAGS="$(pkg-config --cflags-only-I x11 2>/dev/null; pkg-config --cflags-only-I xext 2>/dev/null | tr '\n' ' ')"
    XORGPROTO_DIR="$(pkg-config --variable=includedir xorgproto 2>/dev/null || pkg-config --variable=includedir xproto 2>/dev/null || echo "")"
    if [ -n "$XORGPROTO_DIR" ]; then
        X11_COMPAT="$WORKDIR/x11-compat/X11/extensions"
        mkdir -p "$X11_COMPAT"
        ln -sf "$XORGPROTO_DIR/X11/extensions/shm.h" "$X11_COMPAT/XShm.h" 2>/dev/null || true
        ln -sf "$XORGPROTO_DIR/X11/extensions/XI.h" "$X11_COMPAT/XInput.h" 2>/dev/null || true
        ln -sf "$XORGPROTO_DIR/X11/extensions/XI2.h" "$X11_COMPAT/XInput2.h" 2>/dev/null || true
        ln -sf "$XORGPROTO_DIR/X11/extensions/render.h" "$X11_COMPAT/Xrender.h" 2>/dev/null || true
        ln -sf "$XORGPROTO_DIR/X11/extensions/randr.h" "$X11_COMPAT/Xrandr.h" 2>/dev/null || true
        ln -sf "$XORGPROTO_DIR/X11/extensions/shapeproto.h" "$X11_COMPAT/shape.h" 2>/dev/null || true
        echo '#ifndef _XCURSOR_H_' > "$X11_COMPAT/Xcursor.h"
        echo '#define _XCURSOR_H_' >> "$X11_COMPAT/Xcursor.h"
        echo '#endif' >> "$X11_COMPAT/Xcursor.h"
        { echo '#ifndef _XFIXES_H_'; echo '#define _XFIXES_H_'; echo '#include <X11/extensions/xfixeswire.h>'; echo '#include <X11/extensions/xfixesproto.h>'; echo '#endif'; } > "$X11_COMPAT/Xfixes.h"
        { echo '#ifndef _XINERAMA_H_'; echo '#define _XINERAMA_H_'; echo '#include <X11/extensions/panoramiXproto.h>'; echo '#endif'; } > "$X11_COMPAT/Xinerama.h"
        NIX_X11_CFLAGS="$NIX_X11_CFLAGS -I$WORKDIR/x11-compat"
    fi
    if [ -n "$NIX_X11_CFLAGS" ]; then
        export X_CFLAGS="$NIX_X11_CFLAGS"
        export X_LIBS=""
        export CPPFLAGS="$CPPFLAGS $NIX_X11_CFLAGS"
        echo -e "${green}X11 headers resolved via nix (pkg-config)${nocolor}"
    else
        echo -e "${yellow}X11 headers not found in nix store${nocolor}"
    fi
    export ac_cv_have_x="have_x=yes"
fi

export WIN_ARCH="arm64ec,aarch64,i386"
export OUTPUT_DIR="$ROOT_DIR/compiled-files-aarch64"

echo "HOST CC = $($CC --version 2>/dev/null | head -1 || echo "$CC")"
echo "PE CC   = $(aarch64-w64-mingw32-clang --version 2>/dev/null | head -1 || echo aarch64-w64-mingw32-clang)"
if [ -n "$DEPS" ]; then
    echo "DEPS    = $DEPS"
else
    echo -e "${yellow}DEPS not set (no sysroot for --with-* features)${nocolor}"
fi

# --- Argument processing ---
DO_CLONE=0
DO_GENERATE=0
DO_TOOLS=0
DO_CONFIGURE=0
DO_BUILD=0
DO_BUILD_PROGRAMS=0
DO_INSTALL=0
DO_PACKAGE=0
DO_SYSVSHM=0
DO_SETUP_DEPS=0
ENABLE_16KB=0

if [ $# -eq 0 ]; then
    echo "Usage: $0 [--setup] [--setup-deps] [--clone] [--generate] [--build-tools] [--configure] [--build] [--install] [--package] [--build-sysvshm] [--enable-16kb-pages]"
    echo "  --setup      Full pipeline: setup-deps -> clone -> generate -> build-tools -> configure -> build -> build-programs -> package"
    exit 1
fi

for arg in "$@"; do
    case "$arg" in
        --setup)
            DO_SETUP_DEPS=1; DO_CLONE=1; DO_GENERATE=1; DO_TOOLS=1; DO_SYSVSHM=1; DO_CONFIGURE=1; DO_BUILD=1; DO_BUILD_PROGRAMS=1; DO_PACKAGE=1 ;; 
        --setup-deps) DO_SETUP_DEPS=1 ;;
        --clone) DO_CLONE=1 ;;
        --generate) DO_GENERATE=1 ;;
        --build-tools) DO_TOOLS=1 ;;
        --configure) DO_CONFIGURE=1 ;;
        --build) DO_BUILD=1 ;;
        --build-programs) DO_BUILD_PROGRAMS=1 ;;
        --install) DO_INSTALL=1 ;;
        --package) DO_PACKAGE=1 ;; 
        --build-sysvshm) DO_SYSVSHM=1 ;;
        --enable-16kb-pages) ENABLE_16KB=1 ;; 
        *) echo -e "${red}Unknown argument: $arg${nocolor}"; exit 1 ;;
    esac
done

# --- 16KB pages ---
if [ "$ENABLE_16KB" -eq 1 ]; then
    echo -e "${yellow}Enabling 16KB page size support...${nocolor}"
    export TARGET="aarch64-linux-android35"
    C_OPTS="$C_OPTS -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES"
    export CFLAGS="$C_OPTS"
    export CXXFLAGS="${CXX_EXTRA:-$C_OPTS}"
    export LDFLAGS="$LDFLAGS -Wl,-z,max-page-size=16384"
    export CC="${TOOLCHAIN}/aarch64-linux-android35-clang"
    export CXX="${TOOLCHAIN}/aarch64-linux-android35-clang++"
    echo -e "${green}16KB page size support enabled${nocolor}"
fi

# --- Setup Termux deps from packages.termux.dev ---
if [ "$DO_SETUP_DEPS" -eq 1 ]; then
    TERMUX_ROOT="$WORKDIR/termux-rootfs"
    TERMUX_PREFIX="$TERMUX_ROOT/data/data/com.termux/files/usr"
    TERMUX_REPO="https://packages.termux.dev/apt/termux-main"
    TERMUX_ARCH="aarch64"
    DEB_CACHE="$WORKDIR/deb-cache"

    if [ -f "$TERMUX_PREFIX/.deps-ready" ]; then
        echo -e "${green}Termux deps already installed at $TERMUX_PREFIX${nocolor}"
    else
        echo "Bootstrapping Termux aarch64 deps into $TERMUX_PREFIX..."
        mkdir -p "$DEB_CACHE" "$TERMUX_PREFIX"

        PKGS_INDEX="$DEB_CACHE/Packages"
        if [ ! -f "$PKGS_INDEX" ]; then
            echo "Fetching package index..."
            curl -sL "$TERMUX_REPO/dists/stable/main/binary-$TERMUX_ARCH/Packages" -o "$PKGS_INDEX"
        fi

        download_pkg() {
            local pkg="$1"
            local deb_file="$DEB_CACHE/${pkg}.deb"
            if [ -f "$deb_file" ]; then
                echo "  $pkg (cached)"
            else
                local url=$(grep -A20 "^Package: $pkg\$" "$PKGS_INDEX" | grep "^Filename:" | head -1 | awk '{print $2}')
                if [ -n "$url" ]; then
                    echo "  $pkg ..."
                    curl -sL "$TERMUX_REPO/$url" -o "$deb_file"
                else
                    echo "  $pkg (not found)"
                fi
            fi
        }

        install_pkg() {
            local pkg="$1"
            local deb_file="$DEB_CACHE/${pkg}.deb"
            [ ! -f "$deb_file" ] && return
            mkdir -p /tmp/termux-extract-$$
            (cd /tmp/termux-extract-$$ && ar x "$deb_file" 2>/dev/null && tar -xf data.tar.* -C "$TERMUX_ROOT" 2>/dev/null) || true
            rm -rf /tmp/termux-extract-$$
        }

        echo "Required Termux packages:"
        TERMUX_PACKAGES=(
            xorgproto libx11 libxext libxrender libxrandr libxfixes libxi libxcursor
            libxcb libxau libxdmcp libandroid-support
            freetype fontconfig libexpat
            alsa-lib pulseaudio gnutls libgnutls libgmp libnettle libidn2 libunistring
            glib gstreamer gst-plugins-base gst-plugins-bad libffi zlib libpng
            libglvnd
        )

        for pkg in "${TERMUX_PACKAGES[@]}"; do
            download_pkg "$pkg"
        done

        echo "Extracting packages..."
        for pkg in "${TERMUX_PACKAGES[@]}"; do
            install_pkg "$pkg"
        done

        # Remove .la files that confuse cross-compilation
        find "$TERMUX_PREFIX" -name "*.la" -delete 2>/dev/null || true
        # Fix any absolute symlinks
        find "$TERMUX_PREFIX" -type l -lname "/data/*" 2>/dev/null | while read link; do
            target=$(readlink "$link")
            new_target="${TERMUX_ROOT}${target}"
            [ -e "$new_target" ] && ln -sf "$new_target" "$link" 2>/dev/null
        done

        touch "$TERMUX_PREFIX/.deps-ready"
        echo -e "${green}Termux deps bootstrap complete${nocolor}"
    fi
    export DEPS="$TERMUX_PREFIX"
    echo -e "${green}DEPS=$DEPS${nocolor}"
fi

if [ -n "$DEPS" ]; then
    export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig:$DEPS/share/pkgconfig"
    export CPPFLAGS="${DEPS:+-I$DEPS/include }$SYSROOT_FLAGS"
    export LDFLAGS="${DEPS:+-L$DEPS/lib }${LD_EXTRA} -Wl,-rpath=${RUNTIME_PATH}/lib"
    export FREETYPE_CFLAGS="-I$DEPS/include/freetype2"
    export PULSE_CFLAGS="-I$DEPS/include/pulse"
    export PULSE_LIBS="-L$DEPS/lib/pulseaudio -lpulse"
    export SDL2_CFLAGS="-I$DEPS/include/SDL2"
    export SDL2_LIBS="-L$DEPS/lib -lSDL2"
    export FONTCONFIG_LIBS="-L$DEPS/lib -lfontconfig -lfreetype -lexpat"
    export X_CFLAGS="-I$DEPS/include"
    export X_LIBS="-lX11 -lXext -landroid-sysvshm"
    export GSTREAMER_CFLAGS="-I$DEPS/include/gstreamer-1.0 -I$DEPS/include/glib-2.0 -I$DEPS/lib/glib-2.0/include -I$DEPS/glib-2.0/include -I$DEPS/lib/gstreamer-1.0/include"
    export GSTREAMER_LIBS="-L$DEPS/lib -lgstgl-1.0 -lgstapp-1.0 -lgstvideo-1.0 -lgstaudio-1.0 -lglib-2.0 -lgobject-2.0 -lgio-2.0 -lgsttag-1.0 -lgstbase-1.0 -lgstreamer-1.0"
fi

# --- Build sysvshm ---
if [ "$DO_SYSVSHM" -eq 1 ]; then
    if [ -z "$DEPS" ]; then
        echo -e "${red}DEPS not set, skipping sysvshm build${nocolor}"
    else
        if [ ! -d "$WORKDIR/wine/android/android_sysvshm" ] && [ "$DO_CLONE" -eq 1 ]; then
            echo -e "${yellow}Cloning wine first for sysvshm source...${nocolor}"
            mkdir -p "$WORKDIR"
            git clone --depth 1 --branch "$WINE_BRANCH" "$WINE_REPO" "$WORKDIR/wine" 2>/dev/null
        fi
        if [ -d "$WORKDIR/wine/android/android_sysvshm" ]; then
            echo "Building android_sysvshm library..."
            export CC="$TARGET-clang"
            export PATH="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"
            SYSVSHM_DIR="$WORKDIR/wine/android/android_sysvshm"
            $CC -Wall -std=gnu99 -shared -fPIC -I"$SYSVSHM_DIR" -o "$SYSVSHM_DIR/libandroid-sysvshm.so" "$SYSVSHM_DIR/android_sysvshm.c"
            SYSVSHM_SO="$SYSVSHM_DIR/libandroid-sysvshm.so"
            if [ -f "$SYSVSHM_SO" ]; then
                mkdir -p "$DEPS/lib"
                cp "$SYSVSHM_SO" "$DEPS/lib/"
                echo -e "${green}android_sysvshm built -> $DEPS/lib/${nocolor}"
            fi
        else
            echo -e "${red}android_sysvshm not found in wine source${nocolor}"
        fi
    fi
fi

# --- Clone ---
if [ "$DO_CLONE" -eq 1 ]; then
    mkdir -p "$WORKDIR"
    if [ -d "$WORKDIR/wine" ]; then
        echo -e "${yellow}Wine source already exists, skipping clone${nocolor}"
    else
        echo "Cloning Valve wine (branch: $WINE_BRANCH)..."
        git clone --depth 1 --branch "$WINE_BRANCH" "$WINE_REPO" "$WORKDIR/wine"
    fi
    WINE_VERSION=$(cd "$WORKDIR/wine" && git rev-parse --short HEAD)
    echo -e "${green}Wine version: $WINE_VERSION${nocolor}"
fi

# --- Generate ---
if [ "$DO_GENERATE" -eq 1 ]; then
    if [ ! -d "$WORKDIR/wine" ]; then
        echo -e "${red}Wine source not found. Run --clone first.${nocolor}"
        exit 1
    fi
    cd "$WORKDIR/wine"
    echo "Generating auto-generated sources..."
    echo "  -> server_protocol.def patch..."
    if [ -f "android/patches/server_protocol.def.patch" ]; then
        patch -p1 -s < android/patches/server_protocol.def.patch 2>/dev/null && echo "     server_protocol.def patched" || echo "     server_protocol.def patch SKIPPED"
    fi
    echo "  -> make_vulkan..."
    python3 dlls/winevulkan/make_vulkan 2>&1 || echo "  make_vulkan completed with warnings"
    echo "  -> make_requests..."
    ./tools/make_requests 2>&1 || true
    echo "  -> make_specfiles..."
    perl tools/make_specfiles 2>&1 || true
    echo "  -> autoreconf..."
    autoreconf -fi 2>&1 || { autoconf 2>&1 || true; autoheader 2>&1 || true; }
    if [ ! -f "include/drm.h" ] && [ ! -f "include/drm/drm.h" ]; then
        mkdir -p include/drm
        touch include/drm/drm.h include/drm/drm_mode.h include/drm/drm_fourcc.h
        ln -sf ../include/drm/drm.h include/drm.h
    fi
    echo -e "${green}Source generation complete${nocolor}"
fi

# --- Build native Wine tools ---
if [ "$DO_TOOLS" -eq 1 ]; then
    if [ ! -d "$WORKDIR/wine" ]; then
        echo -e "${red}Wine source not found. Run --clone first.${nocolor}"
        exit 1
    fi
    if [ "$IS_AARCH64" -eq 1 ]; then
        echo -e "${green}Native build on aarch64 host (no wine-tools needed)${nocolor}"
    else
        echo "Building native Wine tools..."
        rm -rf "$WORKDIR/wine-tools"
        mkdir -p "$WORKDIR/wine-tools"
        cd "$WORKDIR/wine-tools"
        (
            unset CC CXX AR AS LD RANLIB STRIP DLLTOOL
            unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
            unset TARGET TOOLCHAIN install_dir WIN_ARCH
            unset PKG_CONFIG_LIBDIR ACLOCAL_PATH
            unset FREETYPE_CFLAGS PULSE_CFLAGS PULSE_LIBS SDL2_CFLAGS SDL2_LIBS
            unset FONTCONFIG_LIBS X_CFLAGS X_LIBS GSTREAMER_CFLAGS GSTREAMER_LIBS
            unset FFMPEG_CFLAGS FFMPEG_LIBS
            unset DEPS RUNTIME_PATH
            "$WORKDIR/wine/configure" \
                --enable-win64 --disable-tests \
                --enable-archs=x86_64 \
                --without-x --without-fontconfig \
                --without-opengl --without-wayland --without-dbus \
                --without-udev --without-cups --without-sane \
                --without-gstreamer --without-coreaudio --without-capi \
                --without-gphoto --without-inotify --without-krb5 \
                --without-opencl --without-oss --without-pcap \
                --without-sdl --without-usb --without-v4l2 \
                --without-pcsclite --without-ffmpeg \
                --without-pthread \
                2>&1 | tee "$WORKDIR/tools_configure_log"
            make tools tools/winebuild/winebuild tools/winegcc/winegcc \
                tools/wrc/wrc tools/widl/widl tools/wmc/wmc \
                tools/wine/wine tools/sfnt2fon/sfnt2fon tools/make_xftmpl \
                2>&1 | tee "$WORKDIR/tools_build_log"
        )
        echo -e "${green}Native tools build complete${nocolor}"
    fi
fi

# --- Configure ---
if [ "$DO_CONFIGURE" -eq 1 ]; then
    if [ ! -d "$WORKDIR/wine" ]; then
        echo -e "${red}Wine source not found. Run --clone first.${nocolor}"
        exit 1
    fi
    cd "$WORKDIR/wine"

    WINE_TOOLS_OPT=""
    if [ "$IS_AARCH64" -eq 0 ]; then
        if [ -d "$WORKDIR/wine-tools" ]; then
            WINE_TOOLS_OPT="--with-wine-tools=$WORKDIR/wine-tools"
        fi
    fi

    echo "Configuring Wine (aarch64-linux-android)..."
    ./configure \
        --enable-archs=$WIN_ARCH \
        --host=$TARGET \
        --prefix $install_dir \
        --bindir $install_dir/bin \
        --libdir $install_dir/lib \
        --exec-prefix $install_dir \
        --with-mingw=clang \
        $WINE_TOOLS_OPT \
        --enable-win64 \
        --disable-win16 \
        --enable-nls \
        --disable-amd_ags_x64 \
        --enable-wineandroid_drv=no \
        --disable-tests \
        --with-alsa \
        --without-capi \
        --without-coreaudio \
        --without-cups \
        --without-dbus \
        --without-ffmpeg \
        --with-fontconfig \
        --with-freetype \
        --without-gcrypt \
        --without-gettext \
        --with-gettextpo=no \
        --without-gphoto \
        --with-gnutls \
        --without-gssapi \
        --with-gstreamer \
        --without-inotify \
        --without-krb5 \
        --without-netapi \
        --without-opencl \
        --with-opengl \
        --without-osmesa \
        --without-oss \
        --without-pcap \
        --without-pcsclite \
        --without-piper \
        --with-pthread \
        --with-pulse \
        --without-sane \
        --without-sdl \
        --without-udev \
        --without-unwind \
        --without-usb \
        --without-v4l2 \
        --without-vosk \
        --with-vulkan \
        --without-wayland \
        --without-xcomposite \
        --without-xfixes \
        --without-xinerama \
        --without-xrandr \
        --without-xrender \
        --without-xshape \
        --with-xshm \
        --without-xxf86vm \
        2>&1 | tee "$WORKDIR/configure_log"

    echo -e "${green}Configure complete${nocolor}"

    echo "Applying patches..."

    PATCHES=(
        "dlls_advapi32_advapi.c.patch"
        "dlls_amd_ags_x64_unixlib.c.patch"

        "dlls_dnsapi_libresolv.c.patch"
        "dlls_dnsapi_record.c.patch"

        "dlls_midimap_Makefile.in.patch"
        "dlls_midimap_midimap.c.patch"

        "dlls_nsiproxy.sys_nsi_common.h.patch"
        "dlls_nsiproxy.sys_ip.c.patch"
        "dlls_nsiproxy.sys_ndis.c.patch"

        "dlls_ntdll_Makefile.in.patch"
        "dlls_ntdll_unix_fsync.c.patch"
        "dlls_ntdll_unix_loader.c.patch"
        "dlls_ntdll_unix_server.c.patch"
        "dlls_ntdll_unix_sync.c.patch"
        "dlls_ntdll_unix_virtual.c.patch"
        "dlls_ntdll_unix_signal_x86_64.c.patch"

        "dlls_opengl32_unix_wgl.c.patch"

        "dlls_user32_Makefile.in.patch"
        "dlls_win32u_clipboard.c.patch"

        "dlls_winebus.sys_bus_sdl.c.patch"
        "dlls_winepulse.drv_pulse.c.patch"

        "dlls_winex11.drv_bitblt.c.patch"
        "dlls_winex11.drv_keyboard.c.patch"
        "dlls_winex11.drv_mouse.c.patch"
        "dlls_winex11.drv_opengl.c.patch"
        "dlls_winex11.drv_window.c.patch"
        "dlls_winex11.drv_x11drv.h.patch"
        "dlls_winex11.drv_x11drv_main.c.patch"

        "dlls_wow64_syscall.c.patch"

        "loader_preloader.c.patch"

        "programs_explorer_desktop.c.patch"
        "programs_wineboot_wineboot.c.patch"
        "programs_winebrowser_Makefile.in.patch"
        "programs_winebrowser_main.c.patch"
        "programs_winemenubuilder_winemenubuilder.c.patch"

        "server_Makefile.in.patch"
        "server_fsync.c.patch"
        "server_inproc_sync.c.patch"
        "server_main.c.patch"
        "server_thread.c.patch"
        "server_unicode.c.patch"

        "dlls_ntdll_unix_esync.c.patch"
        "dlls_ntdll_unix_esync.h.patch"
        "server_esync.c.patch"
        "server_esync.h.patch"
    )

    PATCH_DIR="$WORKDIR/wine/android/patches"
    for patch in "${PATCHES[@]}"; do
        echo "----------------------------------------"
        echo "Applying: $patch"

        if [ -f "$PATCH_DIR/$patch" ]; then
            CHECK_OUT=$(git apply --check "$PATCH_DIR/$patch" 2>&1)
            if [ $? -eq 0 ]; then
                if git apply "$PATCH_DIR/$patch"; then
                    echo "SUCCESS: $patch applied"
                    continue
                fi
                echo "FAILED: error applying $patch"
                continue
            fi
            if grep -q "^new file\|^--- /dev/null\|already exists" "$PATCH_DIR/$patch" 2>/dev/null; then
                DST_FILE=$(grep "^+++ b/" "$PATCH_DIR/$patch" | head -1 | sed 's|^+++ b/||' | sed 's/\t.*//')
                if [ -n "$DST_FILE" ] && [ -e "$DST_FILE" ]; then
                    rm -f "$DST_FILE"
                fi
                if patch -p1 -s < "$PATCH_DIR/$patch" 2>/dev/null; then
                    echo "SUCCESS: $patch applied (new file)"
                    continue
                fi
            fi
            echo "SKIPPED: $patch does not apply cleanly"
        else
            echo "NOT FOUND: $patch (check android/patches/)"
        fi
    done

    echo "----------------------------------------"
    echo -e "${green}Done applying patches.${nocolor}"

    echo "Adding bundled-lib RUNPATH to Makefile..."
    sed -i 's|-Wl,-rpath=${RUNTIME_PATH}/lib|-Wl,-rpath=${RUNTIME_PATH}/lib -Wl,-rpath=\$$ORIGIN/../../lib|g' Makefile

    echo "Adding esync.h include to server.c..."
    sed -i '/^#include "fsync.h"/a #include "esync.h"' dlls/ntdll/unix/server.c

    echo "Disabling winedmo Unix build (no ffmpeg)..."
    sed -i '/dlls\/winedmo\/winedmo.so:/,/^$/d' Makefile
    sed -i '/winedmo\/winedmo.so/d' Makefile

    echo "Fixing preloader LDFLAGS for LLD 21..."
    sed -i 's|-Wl,-Ttext=0x7d400000||g' Makefile
fi

# --- Build ---
if [ "$DO_BUILD" -eq 1 ]; then
    if [ ! -d "$WORKDIR/wine" ]; then
        echo -e "${red}Wine source not found. Run --clone first.${nocolor}"
        exit 1
    fi
    echo "Building Wine..."
    cd "$WORKDIR/wine"
    set -o pipefail
    WINE_JOBS="${WINE_JOBS:-$(nproc)}"
    echo "  -> make depend..."
    make depend 2>&1 | tee -a "$WORKDIR/build_log"
    echo "  -> make all..."
    make -j"$WINE_JOBS" 2>&1 | tee -a "$WORKDIR/build_log"
    BUILD_RC=${PIPESTATUS[0]}
    set +o pipefail

    if [ "$BUILD_RC" -ne 0 ]; then
        echo -e "${red}Build FAILED (make exit code: $BUILD_RC) - check $WORKDIR/build_log${nocolor}"
        exit 1
    fi

    if [ ! -f "loader/wine" ]; then
        echo -e "${red}Build failed: wine binary not found${nocolor}"
        exit 1
    fi
    echo -e "${green}Wine binary built successfully${nocolor}"

    if [ "$IS_AARCH64" -eq 0 ]; then
        echo "Building aarch64-unix libraries..."
        rm -f dlls/ntdll/unix/fsync.o dlls/ntdll/ntdll.so server/fsync.o server/wineserver loader/main.o loader/wine
        make -j"$WINE_JOBS" dlls/ntdll/ntdll.so server/wineserver loader/wine-preloader loader/wine 2>&1 | tee -a "$WORKDIR/build_log"

        for so_target in $(grep "\.so:" Makefile | grep -v "i386-\|x86_64-\|aarch64-windows\|arm64ec-" | awk -F: '{print $1}'); do
            if [ ! -f "$so_target" ]; then
                make -j"$WINE_JOBS" "$so_target" 2>&1 | tee -a "$WORKDIR/build_log" || true
            fi
        done

        if [ ! -f "dlls/winex11.drv/winex11.so" ] && ls dlls/winex11.drv/*.o >/dev/null 2>&1; then
            echo "Linking winex11.so manually..."
            $CC -std=gnu23 -shared -fPIC -Wl,-soname,winex11.so -Wl,-Bsymbolic -Wl,-z,defs \
                -o dlls/winex11.drv/winex11.so dlls/winex11.drv/*.o \
                dlls/ntdll/ntdll.so dlls/win32u/win32u.so \
                $X_LIBS -lm ${LDFLAGS} \
                --sysroot="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/../sysroot" \
                2>&1 | tee -a "$WORKDIR/build_log"
        fi

        if [ ! -f "loader/wine" ]; then
            echo "Building loader/wine manually..."
            $CC -std=gnu23 -c -o loader/main.o loader/main.c -Iloader -Iinclude \
                -D__WINESRC__ -DWINE_UNIX_LIB -fPIE -Wall -pipe \
                -fcf-protection=none -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
                -I$DEPS/include --sysroot="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/../sysroot" \
                $CFLAGS 2>&1 | tee -a "$WORKDIR/build_log"
            $CC -std=gnu23 -o loader/wine loader/main.o \
                -Wl,--export-dynamic -Wl,-pie ${LDFLAGS} \
                2>&1 | tee -a "$WORKDIR/build_log"
        fi

        if [ ! -f "loader/wine-preloader" ] || [ $(stat -c%s "loader/wine-preloader") -gt 1048576 ]; then
            echo "Building loader/wine-preloader (LLD 21 fix)..."
            $CC -std=gnu23 -c -o loader/preloader.o loader/preloader.c -Iloader -Iinclude \
                -D__WINESRC__ -fno-builtin -Wall -pipe \
                -fcf-protection=none -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
                -I$DEPS/include --sysroot="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/../sysroot" \
                $CFLAGS 2>&1 | tee -a "$WORKDIR/build_log"
            cat > /tmp/preloader.ld << 'LINKERSCRIPT'
PHDRS { hdr_load PT_LOAD FILEHDR PHDRS FLAGS(5); text_load PT_LOAD FLAGS(5); data_load PT_LOAD FLAGS(6); }
SECTIONS {
  . = 0x7d400000 + SIZEOF_HEADERS;
  .text : { *(.text*) *(.rodata*) *(.eh_frame*) } :text_load
  .data : { *(.data*) } :data_load
  .bss : { *(.bss*) . = ALIGN(8); _end = .; } :data_load
  /DISCARD/ : { *(.comment) }
}
LINKERSCRIPT
            $CC -std=gnu23 -static -nostartfiles -nodefaultlibs \
                -Wl,-T,/tmp/preloader.ld \
                -o loader/wine-preloader loader/preloader.o \
                2>&1 | tee -a "$WORKDIR/build_log"
        fi

        if [ ! -f "server/wineserver" ]; then
            echo "Building server/wineserver manually..."
            if [ ! -f "server/fsync.o" ]; then
                $CC -std=gnu23 -c -o server/fsync.o server/fsync.c -Iserver -Iinclude \
                    -D__WINESRC__ -DWINE_UNIX_LIB -Wall -pipe \
                    -fcf-protection=none -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
                    -I$DEPS/include --sysroot="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/../sysroot" \
                    $CFLAGS 2>&1 | tee -a "$WORKDIR/build_log"
            fi
            $CC -std=gnu23 -o server/wineserver server/*.o \
                -Wl,-pie ${LDFLAGS} \
                --sysroot="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/../sysroot" \
                2>&1 | tee -a "$WORKDIR/build_log"
        fi

        # Build remaining .so files not covered by Makefile targets
        for pair in \
            "ws2_32:ws2_32.so:dlls/ntdll/ntdll.so" \
            "wineps.drv:wineps.so:dlls/ntdll/ntdll.so dlls/win32u/win32u.so" \
            "winepulse.drv:winepulse.so:dlls/ntdll/ntdll.so -L$DEPS/lib/pulseaudio -lpulse" \
            "winevulkan:winevulkan.so:dlls/ntdll/ntdll.so dlls/win32u/win32u.so" \
            "winspool.drv:winspool.so:dlls/ntdll/ntdll.so" \
        ; do
            dname="${pair%%:*}" rest="${pair#*:}"
            sname="${rest%%:*}" deps="${rest#*:}"
            target="dlls/$dname/$sname"
            if [ ! -f "$target" ] && ls "dlls/$dname"/*.o >/dev/null 2>&1; then
                echo "Linking $target manually..."
                $CC -std=gnu23 -shared -fPIC -Wl,-Bsymbolic -Wl,-soname,$sname -Wl,-z,defs \
                    -o "$target" dlls/$dname/*.o $deps -lm $LDFLAGS \
                    -Wl,-rpath=\$ORIGIN/../../lib \
                    --sysroot="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/../sysroot" \
                    2>&1 | tee -a "$WORKDIR/build_log" || echo "  (non-fatal) $sname skipped"
            fi
        done

        echo -e "${green}Unix libraries build complete${nocolor}"
    fi

    echo "Key binaries:"
    ls -la loader/wine loader/wine-preloader server/wineserver 2>&1
fi

# --- Build Programs (PE .exe files) ---
if [ "$DO_BUILD_PROGRAMS" -eq 1 ]; then
    if [ ! -d "$WORKDIR/wine" ]; then
        echo -e "${red}Wine source not found. Run --clone first.${nocolor}"
        exit 1
    fi
    echo "Building program .exe files..."
    cd "$WORKDIR/wine"

    grep -oP 'programs/\S+/aarch64-windows/\S+\.exe(?=:)' Makefile | sort -u | while IFS= read -r target; do
        [ -f "$target" ] && continue
        make "$target" 2>/dev/null && echo "  $target"
    done
    echo -e "${green}Program .exe files built${nocolor}"
fi

# --- Install ---
if [ "$DO_INSTALL" -eq 1 ]; then
    if [ ! -d "$WORKDIR/wine" ]; then
        echo -e "${red}Wine source not found. Run --clone first.${nocolor}"
        exit 1
    fi
    echo "Installing..."
    cd "$WORKDIR/wine"
    rm -rf "$OUTPUT_DIR/bin" "$OUTPUT_DIR/lib" "$OUTPUT_DIR/share" "$install_dir"
    mkdir -p "$OUTPUT_DIR/bin" "$OUTPUT_DIR/lib" "$OUTPUT_DIR/share" "$install_dir"
    make install -j$(nproc)
    echo "Copying files..."
    cp -r "$install_dir"/bin/wine* "$OUTPUT_DIR/bin" 2>/dev/null || true
    cp -r "$install_dir"/bin/reg* "$OUTPUT_DIR/bin" 2>/dev/null || true
    cp -r "$install_dir"/bin/msi* "$OUTPUT_DIR/bin" 2>/dev/null || true
    cp -r "$install_dir"/bin/notepad "$OUTPUT_DIR/bin" 2>/dev/null || true
    cp -r "$install_dir"/lib/wine "$OUTPUT_DIR/lib" 2>/dev/null || true
    cp -r "$install_dir"/share/wine "$OUTPUT_DIR/share" 2>/dev/null || true
    ln -sf ../lib/wine/aarch64-unix/wine "$install_dir/bin/wine" 2>/dev/null || true
    ln -sf ../lib/wine/aarch64-unix/wine "$OUTPUT_DIR/bin/wine" 2>/dev/null || true
    ln -sf ../lib/wine/aarch64-unix/wine-preloader "$OUTPUT_DIR/bin/wine-preloader" 2>/dev/null || true
    ln -sf ../lib/wine/aarch64-unix/wine-preloader "$install_dir/bin/wine-preloader" 2>/dev/null || true
    echo "Wine loader symlinks:"
    ls -la "$OUTPUT_DIR/bin/wine" "$OUTPUT_DIR/bin/wine-preloader" 2>/dev/null || true
    echo -e "${green}Install complete -> $OUTPUT_DIR${nocolor}"
fi

# --- Package ---
if [ "$DO_PACKAGE" -eq 1 ]; then
    if [ ! -d "$WORKDIR/wine" ]; then
        echo -e "${red}Wine source not found. Run --clone first.${nocolor}"
        exit 1
    fi
    WINE_VERSION=$(cd "$WORKDIR/wine" && git rev-parse --short HEAD)
    echo "Packaging..."
    cd "$WORKDIR/wine"
    PKGDIR="$WORKDIR/package"
    rm -rf "$PKGDIR"
    mkdir -p "$PKGDIR/bin"
    for pe_arch in aarch64 arm64ec i386; do
        mkdir -p "$PKGDIR/lib/wine/${pe_arch}-windows"
        mkdir -p "$PKGDIR/lib/wine/${pe_arch}-unix"
    done

    cp loader/wine "$PKGDIR/lib/wine/aarch64-unix/"
    cp loader/wine-preloader "$PKGDIR/lib/wine/aarch64-unix/" 2>/dev/null || true
    cp server/wineserver "$PKGDIR/bin/" 2>/dev/null || true

    for pe_arch in aarch64 arm64ec i386; do
        arch_dir="${pe_arch}-windows"
        dest="$PKGDIR/lib/wine/$arch_dir"
        for dll_dir in $(find dlls -name "$arch_dir" -type d 2>/dev/null); do
            for f in "$dll_dir"/*; do
                [ -f "$f" ] || continue
                case "$f" in *.dll|*.drv|*.exe|*.ocx|*.cpl|*.acm|*.ax|*.tlb|*.sys) cp "$f" "$dest/" ;; esac
            done
        done
        for lib_dir in $(find libs -name "$arch_dir" -type d 2>/dev/null); do
            for f in "$lib_dir"/*; do
                [ -f "$f" ] || continue
                case "$f" in *.dll|*.drv|*.exe|*.ocx|*.cpl|*.acm|*.ax|*.tlb|*.sys) cp "$f" "$dest/" ;; esac
            done
        done
    done

    for pe_arch in aarch64 arm64ec i386; do
        arch_dir="${pe_arch}-windows"
        dest="$PKGDIR/lib/wine/$arch_dir"
        for f in $(find dlls programs -name "$arch_dir" -type d 2>/dev/null); do
            for dll in "$f"/*.dll; do
                [ -f "$dll" ] || continue
                dllname=$(basename "$dll" .dll)
                # Create symlinks for programs (matching .exe program names)
                # e.g. winecfg -> wine, notepad -> wine, etc.
                case "$dllname" in
                    winecfg|notepad|regedit|winefile|wineconsole|winebrowser|winepath|\
                    winedbg|winemine|msiexec|regsvr32|wineboot|taskmgr|progman|\
                    control|cmd|start|xcopy|uninstaller|explorer|iexplore|\
                    wordpad|write|oleview|write|winhlp32|view|servicemode|\
                    wmic|rundll32|msidb|cscript|wscript|schtasks)
                        ln -sf wine "$PKGDIR/bin/$dllname" 2>/dev/null
                        ;;
                esac
            done
        done
    done

    for f in $(find . -name "*.so" -type f 2>/dev/null); do
        cp "$f" "$PKGDIR/lib/wine/aarch64-unix/"
    done

    for prog_dir in programs/*/aarch64-windows; do
        for exe in "$prog_dir"/*.exe; do
            [ -f "$exe" ] || continue
            cp "$exe" "$PKGDIR/lib/wine/aarch64-windows/"
        done
    done

    mkdir -p "$PKGDIR/share/wine"
    for sub in fonts nls; do
        if [ -d "$sub" ]; then
            cp -a "$sub" "$PKGDIR/share/wine/"
        fi
    done
    if [ -f "wine.inf" ]; then
        cp wine.inf "$PKGDIR/share/wine/"
    elif [ -f "loader/wine.inf" ]; then
        cp loader/wine.inf "$PKGDIR/share/wine/"
    fi

    echo "Fixing data_dir path (nls files)..."
    mkdir -p "$PKGDIR/lib/wine/share/wine/nls"
    cp -a "$PKGDIR/share/wine/nls"/*.nls "$PKGDIR/lib/wine/share/wine/nls/" 2>/dev/null || true
    [ -f "$PKGDIR/share/wine/wine.inf" ] && cp "$PKGDIR/share/wine/wine.inf" "$PKGDIR/lib/wine/share/wine/" 2>/dev/null || true
    [ -d "$PKGDIR/share/wine/fonts" ] && cp -a "$PKGDIR/share/wine/fonts" "$PKGDIR/lib/wine/share/wine/" 2>/dev/null || true

    REF_WCP_URL="https://github.com/GameNative/proton-wine/releases/download/build-p11-20260509-sdk28/proton-11.0-1-arm64ec.wcp"
    REF_PREFIX="$WORKDIR/ref-prefixPack.txz"
    if [ ! -f "$REF_PREFIX" ]; then
        echo "Downloading reference prefixPack.txz..."
        curl -sL "$REF_WCP_URL" | tar -xJ -O prefixPack.txz > "$REF_PREFIX" 2>/dev/null
    fi
    if [ -f "$REF_PREFIX" ] && [ -s "$REF_PREFIX" ]; then
        cp "$REF_PREFIX" "$PKGDIR/prefixPack.txz"
        echo "Using reference prefix pack ($(du -h "$REF_PREFIX" | cut -f1))"
    else
        echo -e "${yellow}Creating minimal prefix pack...${nocolor}"
        PREFIX_DIR="$WORKDIR/prefix"
        rm -rf "$PREFIX_DIR"
        mkdir -p "$PREFIX_DIR/.wine/dosdevices"
        mkdir -p "$PREFIX_DIR/.wine/drive_c/windows"
        touch "$PREFIX_DIR/.wine/.update-timestamp"
        for reg in system.reg user.reg userdef.reg; do
            echo "WINE REGISTRY Version 2" > "$PREFIX_DIR/.wine/$reg"
        done
        tar -cJf "$PKGDIR/prefixPack.txz" -C "$PREFIX_DIR" .wine
        rm -rf "$PREFIX_DIR"
    fi

    if [ -n "$DEPS" ] && [ -d "$DEPS/lib" ]; then
        echo "Bundling X11 runtime libraries..."
        mkdir -p "$PKGDIR/lib"
        for lib in libX11.so libX11.so.6 libXext.so libXext.so.6 \
            libxcb.so libxcb.so.1 libXau.so libXau.so.6 \
            libXdmcp.so libXdmcp.so.6 libandroid-support.so; do
            src="$DEPS/lib/$lib"
            [ -f "$src" ] && cp -a "$src" "$PKGDIR/lib/" 2>/dev/null
        done
    fi

    echo "Skipping strip (debug symbols retained)..."

    echo "Resolving symlinks..."
    for f in $(find "$PKGDIR" -type l 2>/dev/null); do
        target=$(readlink -f "$f" 2>/dev/null)
        if [ -n "$target" ] && ! echo "$target" | grep -q "^$PKGDIR"; then
            if [ -f "$target" ]; then
                rm "$f"
                cp "$target" "$f"
            fi
        fi
    done

    ln -sf ../lib/wine/aarch64-unix/wine "$PKGDIR/bin/wine"
    ln -sf ../lib/wine/aarch64-unix/wine-preloader "$PKGDIR/bin/wine-preloader"

    cat > "$PKGDIR/profile.json" << 'PROEOF'
{
  "type": "Wine",
  "versionName": "11-arm64ec",
  "versionCode": 6,
  "description": "Wine 11 Proton ARM64EC (ESYNC/FSYNC, Oryon optimized)",
  "files": [],
  "wine": {
    "binPath": "bin",
    "libPath": "lib",
    "prefixPack": "prefixPack.txz"
  }
}
PROEOF

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

    OUTPUT_FILE=$(yq ".${PKG_NAME}.output" "$ROOT_DIR/packages.yml" | sed "s/{version}/$WINE_VERSION/")
    WCP_FILE="$ROOT_DIR/$OUTPUT_FILE"
    echo "Compressing package..."
     cd "$PKGDIR" && tar --format=gnu --owner=0 --group=0 -cf - \
        bin lib share prefixPack.txz profile.json Config.json 2>/dev/null \
        | xz -3 -T1 -c > "$WCP_FILE"
    echo -e "${green}Package created: $WCP_FILE ($(find "$PKGDIR" -type f | wc -l) files)${nocolor}"
    ls -lh "$WCP_FILE"

    echo "Verifying interpreter..."
    readelf -l "${PKGDIR}/bin/wine" 2>/dev/null | grep interpreter || true
fi
