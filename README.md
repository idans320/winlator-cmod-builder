# Winlator CMOD Multi-Builder

> ⚠️ **Active development.** Currently tuned and tested only for **Snapdragon 8 Elite X** (Oryon-1 CPU).

Nix-based cross-compilation build system that produces custom component packages (CMODs) for [Winlator](https://winlator.org/) — an Android app that runs Windows x86/x86_64 applications on ARM64 Android devices.

## What is Winlator CMOD?

Winlator CMOD is a modular variant of Winlator where components (Wine, graphics drivers, CPU emulators) are distributed as installable `.wcp`/`.zip` packages. This builder cross-compiles four upstream open-source projects for ARM64 Android/Windows-on-ARM targets with aggressive Qualcomm Oryon-1 CPU tuning, producing ready-to-install CMOD packages.

All builds are optimized for the **Snapdragon 8 Elite X** platform (`-mcpu=oryon-1`, tuned Config.json presets) and may require adjustments for other SoCs.

## Components

| Package | Description |
|---|---|
| **Mesa Turnip** | Freedreno Turnip Vulkan driver for Adreno GPUs, built for Android (Bionic libc) targeting the KGSL kernel interface. Produces `vulkan.turnip.so` with metadata. |
| **FEXCore** | CPU emulation layer (core of FEX-Emu) cross-compiled as Windows ARM64 PE DLLs via llvm-mingw. Provides x86/x86_64 emulation for Wine on ARM64. Ships with a performance-tuned `Config.json`. |
| **Wine 11 Proton** | Valve's Proton fork of Wine, built for ARM64 Linux with ARM64EC support. Multi-architecture: `arm64ec, aarch64, i386, x86_64`. Ships with `Config.json`, `profile.json`, and ELF interpreter patching. |
| **Box64** | x86_64-to-ARM64 dynamic recompiler built as an Android native binary via the NDK. ARM dynarec enabled. |

## Prerequisites

- [Nix](https://nixos.org/download.html) with [flakes](https://nixos.wiki/wiki/Flakes) enabled (`nix.settings.experimental-features = "nix-command flakes"`)
- Git
- Internet connection (fetches Android SDK/NDK, source repos, toolchains)

## Quick Start

Build all packages:

```bash
./build-all.sh
```

Build a single package:

```bash
nix develop .#mesa   --command bash mesa/build.sh
nix develop .#fexcore --command bash fexcore/build.sh
nix develop .#wine    --command bash wine/build.sh
nix develop .#box64   --command bash box64/build.sh
```

## Outputs

| Component | File |
|---|---|
| Mesa Turnip | `mesa-<version>.zip` |
| FEXCore | `fexcore-<version>.wcp` |
| Wine 11 Proton | `wine-arm64-<version>.wcp` |
| Box64 | `box64-<version>.zip` |

These files are the CMOD packages that Winlator loads at runtime.

## Project Structure

```
.
├── build-all.sh            # Orchestrator: iterates packages.yml, runs builds in Nix dev shells
├── packages.yml            # Package manifest (repos, branches, version info)
├── flake.nix               # Nix flake: hermetic build environments, SDK/NDK, toolchains
├── flake.lock              # Pinned Nix inputs for reproducibility
├── mesa/
│   └── build.sh            # Builds Turnip Vulkan driver
├── fexcore/
│   └── build.sh            # Builds FEXCore WOW64 DLLs
├── wine/
│   └── build.sh            # Builds Wine 11 Proton
└── box64/
    └── build.sh            # Builds Box64 emulator
```

## How It Works

1. `packages.yml` defines the four components with source repos, branches, and output filenames.
2. `build-all.sh` reads the manifest and enters each component's Nix dev shell (`nix develop .#<pkg>`).
3. Each Nix dev shell (defined in `flake.nix`) provisions Android SDK/NDK 29, LLVM toolchains, llvm-mingw for PE cross-compilation, and (on ARM64 hosts) QEMU user-mode binfmt registration for x86_64 cross-compilation.
4. Each `build.sh` clones the upstream repository, configures and builds using the native build system (Meson, CMake, Autotools), and packages the output into a `.wcp` or `.zip`.

All tooling is pinned by the Nix flake for fully reproducible builds.

## License

MIT
