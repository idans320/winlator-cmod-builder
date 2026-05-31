# WCP Packaging Spec for Winlator CMOD

## Build

- Source: `ValveSoftware/wine`, branch `proton_11.0`
- Compiler: **Android NDK clang** (`aarch64-linux-android35-clang`)
  - Produces bionic binaries with interpreter `/system/bin/linker64`
  - Matches the reference Proton 10-arm64ec package
  - Without NDK: falls back to system clang producing glibc binaries
- Archs: `--enable-archs=arm64ec,aarch64,i386,x86_64`
- Host: `--host=aarch64-linux-gnu`
- CFLAGS: `-target aarch64-linux-gnu -mcpu=oryon-1 -O3 -ffast-math -funroll-loops -fomit-frame-pointer -fwrapv -fno-strict-aliasing -ffunction-sections -fdata-sections -ffixed-x18`
- LDFLAGS: `-target aarch64-linux-gnu -fuse-ld=lld -Wl,--gc-sections`
  - **CRITICAL**: use system's native aarch64 `lld`, not NDK's x86_64 one (`-fuse-ld=/usr/bin/ld.lld` on mixed arch hosts)
- PE cross: llvm-mingw (`aarch64-w64-mingw32-clang` + `i686` + `x86_64` + `arm64ec`)
- Make: `make -j$(nproc)` (full build, 1700-2100 files, ~200-350MB WCP)

## Pre-build (auto-generated headers)

```bash
python3 dlls/winevulkan/make_vulkan
./tools/make_requests
perl tools/make_specfiles
autoreconf -fi
```

## Install

```bash
make install DESTDIR=$PKGDIR -i
```

## Post-install fixes

1. `cp loader/wine-preloader → $PKGDIR/opt/wine/bin/wine-preloader` (not installed by make install)
2. Copy all `dlls/*.so` → `$PKGDIR/opt/wine/lib/wine/aarch64-unix/` (not installed by make install)
3. `patchelf --set-interpreter /system/bin/linker64` on all ELF binaries
4. Strip with `aarch64-w64-mingw32-strip` (PE) + `llvm-strip` (ELF) from llvm-mingw

## Package structure (flat, no opt/wine prefix)

```
wine-arm64-{sha}.wcp:
├── bin/
│   ├── wine              (ELF, interpreter=/system/bin/linker64)
│   ├── wine-preloader    (static-pie)
│   ├── wineserver        (ELF, interpreter=/system/bin/linker64)
│   └── ... (all wine tools, NO symlinks)
├── lib/
│   └── wine/
│       ├── aarch64-unix/      (ELF .so files, ~25 files)
│       ├── aarch64-windows/   (PE .dll files)
│       ├── arm64ec-windows/   (PE .dll files)
│       ├── i386-windows/      (PE .dll files — WOW64 32-bit)
│       └── x86_64-windows/    (PE .dll files — x86_64 emulation)
├── share/
│   └── wine/ (fonts, nls, wine.inf)
├── prefixPack.txz   (minimal .wine/ with empty registry)
└── profile.json
```

## profile.json format (EXACT)

```json
{
  "type": "Wine",
  "versionName": "11-arm64ec",
  "versionCode": 0,
  "description": "Wine 11 Proton ARM64EC (ESYNC/FSYNC, Oryon optimized)",
  "files": [],
  "wine": {
    "binPath": "bin",
    "libPath": "lib",
    "prefixPack": "prefixPack.txz"
  }
}
```

**CRITICAL**: `files` **must** be `[]` (empty). The `wine` object handles path resolution. Using individual file entries triggers `"Cannot be trusted"` validation in Winlator CMOD.

## prefixPack.txz

Minimal `.wine/` directory with empty registry files:

```
.wine/
├── .update-timestamp    (empty file)
├── dosdevices/          (empty directory)
├── drive_c/
│   └── windows/         (empty directory)
├── system.reg           ("WINE REGISTRY Version 2\n")
├── user.reg             ("WINE REGISTRY Version 2\n")
└── userdef.reg          ("WINE REGISTRY Version 2\n")
```

Created with: `tar -cJf prefixPack.txz .wine`

## Compression

```bash
tar --format=gnu --owner=0 --group=0 -cf - \
    ./bin ./lib ./share ./prefixPack.txz ./profile.json \
    | zstd -T1 -3 -o output.wcp
```

- **CRITICAL**: use `./` prefix on paths (matches reference K11MCH1 package format)
- **CRITICAL**: no symlinks — resolve all to copies before packaging
- **CRITICAL**: `--owner=0 --group=0` (root:root, matches reference)
- **CRITICAL**: file count should be 1700-2100 (reference is 1762 files)

## Interpreter verification

```bash
readelf -l bin/wine | grep interpreter
```

Must show: `/system/bin/linker64`

If it shows anything with `imagefs` or `ld-linux-aarch64`, the NDK was not used — rebuild with NDK.

## Reference comparison

```bash
readelf -l bin/wine | grep interpreter    # /system/bin/linker64
readelf -d bin/wine | grep NEEDED         # libc.so (bionic, NOT libc.so.6)
file bin/wine                              # "for Android 28, built by NDK r27"
```

## Known Winlator CMOD bugs

1. **`finishInstallContent()`** — `mkdirs()` before `renameTo()` causes rename to fail (dir exists), but missing `return` after `onFailed` means `onSucceed` fires anyway → install appears to succeed but files stay in temp (cleared on next attempt). Workaround: delete old install dir before each test.

2. **`applyContent()` line 400** — `||` should be `&&` → all content types accidentally process fileList. This is why `files: []` is critical for Wine/Proton types.

3. **`ContentInfoDialog` NPE** — `profile.type.toString()` on null type when `getTypeByName` returns null for unrecognized type strings. Fix: add null check in `readProfile()`.
