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
          # Cross-built Linux package set — same CPU as the host, Linux
          # kernel, glibc. Works for any CPU nixpkgs supports without
          # enumeration. We use this for *all* Linux-targeted derivations
          # so there's a single, consistent build mode.
          pkgsCrossLinux = import nixpkgs {
            inherit system;
            crossSystem = {
              config = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-unknown-linux-gnu";
            };
          };
        in
        import ./default.nix {
          inherit pkgs pkgsCrossLinux;
          lib = nixpkgs.lib;
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
