{
  description = "Minimal Linux VM (kernel + initramfs + k3s) cross-built from Darwin";

  inputs = {
    nixpkgs.url = "github:jonhermansen/nixpkgs/jon/darwin";

    # Kernel source is fetched as a tarball directly inside nix/default.nix
    # (so the build can re-extract specific entries by exact case to
    # neutralize APFS case-fold races). It is *not* declared as a flake
    # input — flake input materialization extracts to the case-insensitive
    # store, which is exactly the race we're trying to avoid.
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      perSystem = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          hostCpu = pkgs.stdenv.hostPlatform.parsed.cpu.name;
          # Cross-built Linux package set — same CPU as the host, Linux
          # kernel, glibc. Works for any CPU nixpkgs supports without
          # enumeration. We use this for *all* Linux-targeted derivations
          # so there's a single, consistent build mode.
          pkgsCrossLinux = import nixpkgs {
            inherit system;
            crossSystem = {
              config = "${hostCpu}-unknown-linux-gnu";
            };
          };
          hostTarget = import ./default.nix {
            inherit pkgs pkgsCrossLinux;
            lib = nixpkgs.lib;
          };
          # Target-specific view of default.nix for a given CPU (gives us
          # that target's kernelSrc, kernelConfigFragment, linuxRev).
          targetView = cpu: import ./default.nix {
            inherit pkgs pkgsCrossLinux;
            lib = nixpkgs.lib;
            targetCpu = cpu;
          };
          pkgsLinux = nixpkgs.legacyPackages."${hostCpu}-linux";
          isDarwin = nixpkgs.lib.hasSuffix "-darwin" system;
          # Build a kernel for `cpu`:
          #   - cpu == hostCpu: direct build (hostTarget.kernel already).
          #   - cpu != hostCpu && darwin host: pure cross hits darwin
          #     host-tool portability holes (vdso2c <endian.h>, Mach-O/ELF
          #     linker confusion). Route through recursive-nix: boot the
          #     host-arch Linux VM under HVF, build the cross kernel inside
          #     where host tools see real Linux headers.
          #   - cpu != hostCpu && linux host: LLVM=1 cross directly works.
          kernelForCpu = cpu:
            if cpu == hostCpu then hostTarget.kernel
            else if !isDarwin then (targetView cpu).kernel
            else let
              tv = targetView cpu;
              tools = with pkgsLinux; [
                gnumake flex bison bc
                llvmPackages.clang-unwrapped llvm lld
                openssl perl python3 gcc
                coreutils gnutar gzip xz gawk findutils gnused
                pahole
              ];
              toolsPath = nixpkgs.lib.concatStringsSep ":"
                (map (p: "${p}/bin") tools);
              elfutils = pkgsLinux.elfutils;
              archMap = { x86_64 = "x86_64"; aarch64 = "arm64"; };
              imageMap = {
                x86_64 = "arch/x86/boot/bzImage";
                aarch64 = "arch/arm64/boot/Image";
              };
              imageNameMap = { x86_64 = "bzImage"; aarch64 = "Image"; };
            in hostTarget.runInLinuxVM {
              name = "linux-${tv.linuxRev}-${cpu}";
              script = ''
                mkdir -p $out
                export PATH=${toolsPath}:/bin
                export C_INCLUDE_PATH=${elfutils.dev}/include
                export LIBRARY_PATH=${elfutils.out}/lib
                cd /build
                tar -xzf ${tv.kernelSrc}
                cd linux-${tv.linuxRev}
                MAKE_FLAGS="ARCH=${archMap.${cpu}} LLVM=1 HOSTCC=gcc HOSTLD=ld"
                make $MAKE_FLAGS tinyconfig
                ./scripts/kconfig/merge_config.sh -m .config ${tv.kernelConfigFragment}
                make $MAKE_FLAGS olddefconfig
                cp .config $out/config
                # Fail loud on silently-dropped CONFIG_*=y requests.
                awk -F= '/^CONFIG_[A-Z0-9_]+=y$/{print $1"=y"}' ${tv.kernelConfigFragment} \
                  | sort -u > /tmp/wanted
                awk -F= '/^CONFIG_[A-Z0-9_]+=y$/{print $1"=y"}' .config \
                  | sort -u > /tmp/got
                missing=$(comm -23 /tmp/wanted /tmp/got)
                if [ -n "$missing" ]; then
                  echo "ERROR: dropped by olddefconfig:" >&2
                  echo "$missing" >&2
                  exit 1
                fi
                make $MAKE_FLAGS -j"$(nproc)" ${imageNameMap.${cpu}}
                cp ${imageMap.${cpu}} $out/${imageNameMap.${cpu}}
                cp vmlinux $out/vmlinux
              '';
            };
        in
        hostTarget // {
          kernel = hostTarget.kernel // {
            aarch64 = kernelForCpu "aarch64";
            x86_64 = kernelForCpu "x86_64";
          };
        };
    in
    {
      packages = forAllSystems (s:
        let
          p = perSystem s;
          # vfkit is darwin-only and uses Apple's Virtualization Framework,
          # which can virtualize aarch64 on aarch64 hosts and x86_64 on
          # x86_64 hosts (no emulation). On Linux hosts, use qemu.
          preferredRunner =
            if nixpkgs.lib.hasSuffix "-darwin" s then p.run-vfkit else p.run;
        in {
          default = preferredRunner;
          kernel = p.kernel;
          initramfs = p.initramfs;
          run = p.run;
          run-vfkit = p.run-vfkit;
          test-native-build = p.runInLinuxVM {
            name = "test-native-build";
            script = ''
              uname -a > $out/uname.txt
              echo "Hello from native Linux VM build!" > $out/hello.txt
            '';
          };
          test-build-natively = p.buildNatively
            nixpkgs.legacyPackages.aarch64-linux.hello;
        });

      apps = forAllSystems (s:
        let
          p = perSystem s;
          preferredRunner =
            if nixpkgs.lib.hasSuffix "-darwin" s then p.run-vfkit else p.run;
          preferredBin =
            if nixpkgs.lib.hasSuffix "-darwin" s
            then "${p.run-vfkit}/bin/run-kernel-vfkit"
            else "${p.run}/bin/run-kernel";
        in {
          default = {
            type = "app";
            program = preferredBin;
          };
          run = {
            type = "app";
            program = "${p.run}/bin/run-kernel";
          };
          run-vfkit = {
            type = "app";
            program = "${p.run-vfkit}/bin/run-kernel-vfkit";
          };
        });
    };
}
