#!/bin/bash -e
# Build the DXVK recovery test .exe using the same llvm-mingw toolchain
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TOOLCHAIN_BIN="$ROOT_DIR/fexcore/workdir/toolchain/bin"

CC=""
if [ -x "$TOOLCHAIN_BIN/aarch64-w64-mingw32-clang" ]; then
    CC="$TOOLCHAIN_BIN/aarch64-w64-mingw32-clang"
elif command -v aarch64-w64-mingw32-clang &>/dev/null; then
    CC="$(command -v aarch64-w64-mingw32-clang)"
else
    echo "aarch64-w64-mingw32-clang not found"
    exit 1
fi

echo "CC = $CC"
echo "Building test_recovery.exe ..."

$CC -O2 -target aarch64-w64-mingw32 \
    -D_WIN32_WINNT=0x0601 \
    -DUNICODE -D_UNICODE \
    -o "$SCRIPT_DIR/test_recovery.exe" \
    "$SCRIPT_DIR/test_recovery.c" \
    -ld3d9 -ldxguid -lgdi32 -luser32

echo "Done: $SCRIPT_DIR/test_recovery.exe"
file "$SCRIPT_DIR/test_recovery.exe"
ls -lh "$SCRIPT_DIR/test_recovery.exe"
