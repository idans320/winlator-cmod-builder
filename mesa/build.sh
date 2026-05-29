#!/bin/bash -e

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$PACKAGE_DIR")"
WORKDIR="$PACKAGE_DIR/workdir"
PKG_NAME="mesa"

MESA_REPO="https://github.com/whitebelyash/mesa-unified.git"
MESA_BRANCH="turnip/gen8"
SDK_VER="35"
NDK_CLANG="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
DRIVER_SO="$WORKDIR/mesa/build-android/src/freedreno/vulkan/libvulkan_freedreno.so"

echo -e "${green}=== Mesa Turnip Builder ===${nocolor}"

if [ -z "$NDK" ] || [ -z "$ANDROID_HOME" ]; then
    echo -e "${red}Not inside Nix dev shell. Run: nix develop /app/mesa-builder#mesa${nocolor}"
    exit 1
fi

if [ ! -d "$NDK_CLANG" ]; then
    echo -e "${red}NDK toolchain not found at $NDK_CLANG${nocolor}"
    exit 1
fi

mkdir -p "$WORKDIR"
if [ ! -d "$WORKDIR/mesa" ]; then
    echo "Cloning Mesa (branch: $MESA_BRANCH)..."
    git clone --depth 1 --branch "$MESA_BRANCH" "$MESA_REPO" "$WORKDIR/mesa" 2>&1
fi
MESA_VERSION=$(cat "$WORKDIR/mesa/VERSION")
echo -e "${green}Mesa version: $MESA_VERSION${nocolor}"

if [ ! -f "$WORKDIR/mesa/build-android/build.ninja" ]; then
    echo "Creating cross-file..."
    cat > "$WORKDIR/android-aarch64.txt" << CROSSEOF
[binaries]
c = ['$NDK_CLANG/aarch64-linux-android${SDK_VER}-clang', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression']
cpp = ['$NDK_CLANG/aarch64-linux-android${SDK_VER}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression', '-Wno-c++11-narrowing']
ar = '$NDK_CLANG/llvm-ar'
strip = '$NDK_CLANG/llvm-strip'
c_ld = '$NDK_CLANG/ld.lld'
cpp_ld = '$NDK_CLANG/ld.lld'
pkg-config = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
CROSSEOF

    echo "Configuring build..."
    cd "$WORKDIR/mesa"
    meson setup build-android \
        --cross-file "$WORKDIR/android-aarch64.txt" \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version="$SDK_VER" \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dspirv-tools=disabled \
        -Dzstd=disabled \
        -Dstrip=true &> "$WORKDIR/meson_log"
fi

echo "Building..."
cd "$WORKDIR/mesa"
if [ -f "$DRIVER_SO" ]; then
    echo -e "${green}Driver already built, skipping...${nocolor}"
else
    ninja -C build-android 2>&1 | tee "$WORKDIR/ninja_log"
fi

if [ ! -f "$DRIVER_SO" ]; then
    echo -e "${red}Build failed: libvulkan_freedreno.so not found${nocolor}"
    exit 1
fi
echo -e "${green}Build successful${nocolor}"

echo "Fixing SONAME with patchelf..."
patchelf --set-soname vulkan.turnip.so "$DRIVER_SO"

ICD_JSON=$(ls "$WORKDIR/mesa/build-android/src/freedreno/vulkan/freedreno_icd."*.json 2>/dev/null | head -1)
if [ -z "$ICD_JSON" ]; then
    VK_API_VERSION=$(strings "$DRIVER_SO" | grep -oP '1\.\d+\.\d+' | sort -u | tail -1)
else
    VK_API_VERSION=$(python3 -c "import json; print(json.load(open('$ICD_JSON'))['ICD']['api_version'])")
fi
echo -e "${green}Vulkan API version: $VK_API_VERSION${nocolor}"

echo "Packaging..."
PKGDIR="$WORKDIR/package"
mkdir -p "$PKGDIR"
cp "$DRIVER_SO" "$PKGDIR/vulkan.turnip.so"

cat > "$PKGDIR/meta.json" << METAEOF
{
  "schemaVersion": 1,
  "name": "Mesa Turnip Driver $MESA_VERSION",
  "description": "Freedreno Turnip Vulkan driver for Android — Mesa $MESA_VERSION, Vulkan $VK_API_VERSION, KGSL",
  "author": "Mesa",
  "packageVersion": "$MESA_VERSION",
  "vendor": "Mesa",
  "driverVersion": "Vulkan $VK_API_VERSION",
  "minApi": 27,
  "libraryName": "vulkan.turnip.so"
}
METAEOF

WCP_FILE="$ROOT_DIR/mesa-${MESA_VERSION}.zip"
zip -j "$WCP_FILE" "$PKGDIR/vulkan.turnip.so" "$PKGDIR/meta.json"
echo -e "${green}Package created: $WCP_FILE${nocolor}"
ls -lh "$WCP_FILE"
