{
  description = "Winlator CMOD Multi-Builder — Mesa Turnip, FEXCore, Wine 10 Proton, Box64";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };

        androidComposition = pkgs.androidenv.composeAndroidPackages {
          cmdLineToolsVersion = "13.0";
          toolsVersion = null;
          platformToolsVersion = "35.0.2";
          buildToolsVersions = [ "35.0.0" ];
          includeEmulator = false;
          platformVersions = [ "35" ];
          includeSources = false;
          includeSystemImages = false;
          abiVersions = [ "arm64-v8a" ];
          includeCmake = true;
          cmakeVersions = [ "3.31.6" ];
          includeNDK = true;
          ndkVersions = [ "29.0.14206865" ];
          useGoogleAPIs = false;
          useGoogleTVAddOns = false;
          includeExtras = [ ];
        };

        androidSdk = androidComposition.androidsdk;
        ndkDir = "${androidSdk}/libexec/android-sdk/ndk/29.0.14206865";

        isAarch64Linux = system == "aarch64-linux";
        qemuUser = pkgs.qemu-user;
        x86Glibc  = pkgs.pkgsCross.gnu64.glibc;
        x86Zlib   = pkgs.pkgsCross.gnu64.zlib;
        x86GccLib = pkgs.pkgsCross.gnu64.stdenv.cc.cc.lib;

        x86Sysroot = pkgs.runCommandLocal "x86_64-qemu-sysroot" {} ''
          mkdir -p $out/lib $out/lib64
          for f in ${x86Glibc}/lib/libc*.so*   \
                   ${x86Glibc}/lib/libm*.so*   \
                   ${x86Glibc}/lib/libpthread*.so* \
                   ${x86Glibc}/lib/librt*.so*  \
                   ${x86Glibc}/lib/libdl*.so*; do
            cp -L "$f" $out/lib/ 2>/dev/null || true
          done
          cp -L ${x86Glibc}/lib64/ld-linux-x86-64.so.2 $out/lib64/
          for f in ${x86Zlib}/lib/libz*.so*; do
            cp -L "$f" $out/lib/ 2>/dev/null || true
          done
          for f in ${x86GccLib}/lib/libgcc_s*.so*; do
            cp -L "$f" $out/lib/ 2>/dev/null || true
          done
          cd $out/lib
          for real in *.so.*.*; do
            minor="''${real%.*}"; major="''${minor%.*}"
            [ -e "$minor" ] || ln -sf "$real" "$minor"
            [ -e "$major" ] || ln -sf "$real" "$major"
          done
        '';

        commonEnv = {
          ANDROID_HOME    = "${androidSdk}/libexec/android-sdk";
          ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
          NDK             = ndkDir;
        } // pkgs.lib.optionalAttrs isAarch64Linux {
          QEMU_LD_PREFIX  = x86Sysroot;
          LD_LIBRARY_PATH = "${x86Zlib}/lib:${x86GccLib}/lib";
        };

        commonHook = ''
          echo "Winlator CMOD build environment ready"
          echo "  NDK: $NDK"
          echo "  SDK: $ANDROID_HOME"
        '' + pkgs.lib.optionalString isAarch64Linux ''
          if ! [ -f /proc/sys/fs/binfmt_misc/qemu-x86_64 ]; then
            if mountpoint -q /proc/sys/fs/binfmt_misc 2>/dev/null || \
               sudo mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null; then
              echo ":qemu-x86_64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:${qemuUser}/bin/qemu-x86_64:F" \
                | sudo tee /proc/sys/fs/binfmt_misc/register >/dev/null 2>&1 && \
                echo "  binfmt: qemu-x86_64 registered" || \
                echo "  binfmt: already registered or no permission"
            fi
          else
            echo "  binfmt: qemu-x86_64 already registered"
          fi
        '';

        androidPkgs = [ androidSdk ];
        basePkgs = [ pkgs.python3 pkgs.git pkgs.zip ] ++ pkgs.lib.optionals isAarch64Linux [ qemuUser ];

      in {
        devShells = {
          default = pkgs.mkShell {
            name = "winlator-cmod-all";
            packages = androidPkgs ++ basePkgs ++ [
              pkgs.meson pkgs.ninja pkgs.cmake
              pkgs.patchelf pkgs.glslang pkgs.pkg-config
              pkgs.bison pkgs.flex
              pkgs.libxml2 pkgs.libarchive
              pkgs.python3Packages.mako
              pkgs.python3Packages.pyyaml
            ] ++ pkgs.lib.optionals (!pkgs.stdenv.isDarwin) [
              pkgs.mingw-w64
            ];
            env = commonEnv;
            shellHook = commonHook;
          };

          mesa = pkgs.mkShell {
            name = "winlator-cmod-mesa";
            packages = androidPkgs ++ basePkgs ++ [
              pkgs.meson pkgs.ninja
              pkgs.patchelf pkgs.glslang pkgs.pkg-config
              pkgs.bison pkgs.flex
              pkgs.libxml2 pkgs.libarchive
              pkgs.python3Packages.mako
              pkgs.python3Packages.pyyaml
            ];
            env = commonEnv;
            shellHook = commonHook;
          };

          fexcore = pkgs.mkShell {
            name = "winlator-cmod-fexcore";
            packages = [
              pkgs.cmake pkgs.ninja
              pkgs.python3 pkgs.python3Packages.pyyaml
              pkgs.git pkgs.curl
              pkgs.xz pkgs.zip
            ] ++ pkgs.lib.optionals isAarch64Linux [ qemuUser ];
            env = {
            } // pkgs.lib.optionalAttrs isAarch64Linux {
              QEMU_LD_PREFIX  = x86Sysroot;
              LD_LIBRARY_PATH = "${x86Zlib}/lib:${x86GccLib}/lib";
            };
            shellHook = ''
              echo "Winlator CMOD — FEXCore build environment ready"
            '' + pkgs.lib.optionalString isAarch64Linux ''
              if ! [ -f /proc/sys/fs/binfmt_misc/qemu-x86_64 ]; then
                if mountpoint -q /proc/sys/fs/binfmt_misc 2>/dev/null || \
                   sudo mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null; then
                  echo ":qemu-x86_64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:${qemuUser}/bin/qemu-x86_64:F" \
                    | sudo tee /proc/sys/fs/binfmt_misc/register >/dev/null 2>&1 && \
                    echo "  binfmt: qemu-x86_64 registered" || \
                    echo "  binfmt: already registered or no permission"
                fi
              else
                echo "  binfmt: qemu-x86_64 already registered"
              fi
            '';
          };

          wine = pkgs.mkShell {
            name = "winlator-cmod-wine";
            packages = androidPkgs ++ [
              pkgs.clang pkgs.lld
              pkgs.cmake pkgs.ninja
              pkgs.bison pkgs.flex
              pkgs.autoconf pkgs.automake pkgs.libtool
              pkgs.gnumake pkgs.patchelf
              pkgs.pkg-config
              pkgs.python3 pkgs.python3Packages.pyyaml
              pkgs.git pkgs.curl
              pkgs.xz pkgs.zip
            ] ++ pkgs.lib.optionals isAarch64Linux [ qemuUser ];
            env = {
              ANDROID_HOME    = "${androidSdk}/libexec/android-sdk";
              ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
              NDK             = ndkDir;
            } // pkgs.lib.optionalAttrs isAarch64Linux {
              QEMU_LD_PREFIX  = x86Sysroot;
              LD_LIBRARY_PATH = "${x86Zlib}/lib:${x86GccLib}/lib";
            };
            shellHook = ''
              echo "Winlator CMOD — Wine 11 Proton build environment ready"
              echo "  NDK: $NDK"
              echo "  SDK: $ANDROID_HOME"
            '' + pkgs.lib.optionalString isAarch64Linux ''
              if ! [ -f /proc/sys/fs/binfmt_misc/qemu-x86_64 ]; then
                if mountpoint -q /proc/sys/fs/binfmt_misc 2>/dev/null || \
                   sudo mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null; then
                  echo ":qemu-x86_64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:${qemuUser}/bin/qemu-x86_64:F" \
                    | sudo tee /proc/sys/fs/binfmt_misc/register >/dev/null 2>&1 && \
                    echo "  binfmt: qemu-x86_64 registered" || \
                    echo "  binfmt: already registered or no permission"
                fi
              else
                echo "  binfmt: qemu-x86_64 already registered"
              fi
            '';
          };

          box64 = pkgs.mkShell {
            name = "winlator-cmod-box64";
            packages = androidPkgs ++ basePkgs ++ [
              pkgs.cmake pkgs.ninja
              pkgs.python3Packages.pyyaml
            ];
            env = commonEnv;
            shellHook = commonHook;
          };
        };
      }
    );
}
