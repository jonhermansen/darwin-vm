{
  description = "Minimal Linux VM (kernel + initramfs + k3s) cross-built from Darwin";

  inputs = {
    nixpkgs.url = "github:jonhermansen/nixpkgs/jon/darwin";

    # Kernel source as a non-flake input — we only need the tree, the build
    # recipe lives here.
    linux = {
      url = "github:jonhermansen/linux/jon/darwin";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, linux }:
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
        import ./nix {
          inherit pkgs pkgsCrossLinux;
          lib = nixpkgs.lib;
          # Path into the kernel tree fetched as the `linux` flake input.
          root = linux;
        };
    in
    {
      packages = forAllSystems (s:
        let p = perSystem s; in {
          default = p.run;
          kernel = p.kernel;
          initramfs = p.initramfs;
          run = p.run;
        });

      apps = forAllSystems (s:
        let p = perSystem s; in {
          default = {
            type = "app";
            program = "${p.run}/bin/run-kernel";
          };
        });
    };
}
