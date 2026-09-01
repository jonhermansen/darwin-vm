# Build natively inside a Linux VM from a macOS host.
#
# Two interfaces:
#   runInLinuxVM { name; script; }  — run a raw shell script in the VM
#   buildNatively target             — build a nixpkgs derivation natively
#
# The host's /nix/store is shared read-only via 9p. A writable 9p
# share carries the build script in and output out. QEMU runs under
# TCG (software emulation) so no hypervisor entitlements are needed
# inside the nix build sandbox.

{ pkgs, kernel, busyboxStatic, lib }:

let
  isAarch64 = pkgs.stdenv.hostPlatform.isAarch64;

  arch =
    if isAarch64 then {
      qemu = "aarch64";
      machine = "virt";
      imageName = "Image";
    } else {
      qemu = "x86_64";
      machine = "q35";
      imageName = "bzImage";
    };

  initScript = pkgs.writeText "init-native-build" ''
    #!/bin/busybox sh
    /bin/busybox --install -s /bin

    mount -t proc none /proc
    mount -t sysfs none /sys
    mount -t devtmpfs none /dev

    mkdir -p /nix/store /share /tmp /etc /root

    echo 'root:x:0:0:root:/root:/bin/sh' > /etc/passwd
    echo 'root:x:0:' > /etc/group

    mount -t 9p -o trans=virtio,version=9p2000.L,ro nix-store /nix/store
    mount -t 9p -o trans=virtio,version=9p2000.L,rw,cache=none share /share

    export HOME=/root
    export TZ=UTC
    export TMPDIR=/tmp
    export out=/share/out
    mkdir -p "$out"

    if [ -f /share/build.sh ]; then
      chmod +x /share/build.sh
      if /share/build.sh > /share/build.log 2>&1; then
        echo 0 > /share/exit-code
      else
        echo 1 > /share/exit-code
      fi
    else
      echo "ERROR: /share/build.sh not found" > /share/build.log
      echo 1 > /share/exit-code
    fi

    sync
    poweroff -f
  '';

  buildInitramfs = pkgs.runCommand "build-initramfs.cpio.gz" {
    nativeBuildInputs = [ pkgs.cpio pkgs.gzip ];
  } ''
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT"/{bin,dev,proc,sys,nix/store,share,tmp,etc,root}
    cp ${busyboxStatic}/bin/busybox "$ROOT/bin/busybox"
    chmod +x "$ROOT/bin/busybox"
    install -m 0755 ${initScript} "$ROOT/init"
    (cd "$ROOT" && find . | cpio -H newc -o 2>/dev/null | gzip -9 > $out)
  '';

  # Shared QEMU invocation for both interfaces
  qemuCmd = ''
    qemu-system-${arch.qemu} \
      -machine ${arch.machine} \
      -cpu max \
      -accel tcg \
      -smp 2 \
      -m 2048 \
      -nographic \
      -no-reboot \
      -kernel ${kernel}/${arch.imageName} \
      -initrd ${buildInitramfs} \
      -fsdev local,id=nixstore,path=/nix/store,security_model=none,readonly=on \
      -device virtio-9p-pci,fsdev=nixstore,mount_tag=nix-store \
      -fsdev local,id=share,path="$SHARE",security_model=none \
      -device virtio-9p-pci,fsdev=share,mount_tag=share \
      -append "console=hvc0 panic=-1"
  '';

  checkResult = ''
    if [ ! -f "$SHARE/exit-code" ]; then
      echo "ERROR: VM did not produce an exit code" >&2
      cat "$SHARE/build.log" 2>/dev/null || true
      exit 1
    fi

    EXIT_CODE=$(cat "$SHARE/exit-code")
    if [ "$EXIT_CODE" != "0" ]; then
      echo "ERROR: Build failed (exit code $EXIT_CODE)" >&2
      cat "$SHARE/build.log" 2>/dev/null || true
      exit 1
    fi
  '';

in {
  # Run a raw shell script inside a Linux VM.
  runInLinuxVM = { name, script }:
    let
      buildScript = pkgs.writeScript "${name}-build.sh" ''
        #!/bin/sh
        set -e
        ${script}
      '';
    in
    derivation {
      inherit name;
      system = pkgs.stdenv.hostPlatform.system;
      builder = "${pkgs.bash}/bin/bash";
      args = [ "-e" (pkgs.writeText "${name}-wrapper.sh" ''
        export PATH="${lib.makeBinPath [ pkgs.qemu pkgs.coreutils ]}:$PATH"

        SHARE="$TMPDIR/vm-share"
        mkdir -p "$SHARE/out"

        cp ${buildScript} "$SHARE/build.sh"

        ${qemuCmd}
        ${checkResult}

        mv "$SHARE/out" "$out"
      '') ];

      __recursive = true;
      requiredSystemFeatures = [ "recursive-nix" ];
    };

  # Build a nixpkgs derivation natively inside a Linux VM.
  #
  # Extracts the builder, args, and env from the target's .drv file,
  # fetches all build inputs from the binary cache, then runs the
  # builder inside the VM. The output lands at $out of the wrapper
  # derivation (NOT the target's original store path).
  #
  # Limitations:
  #   - All build inputs must be substitutable (in a binary cache)
  #   - Self-referencing outputs will have the wrong store path
  #   - Single-output derivations only
  #
  # Usage:
  #   buildNatively pkgsLinux.hello
  buildNatively = target:
    let
      # Depend on the .drv file itself, not on building its outputs.
      targetDrv = builtins.unsafeDiscardOutputDependency target.drvPath;
    in
    derivation {
      name = "native-${target.name or "build"}";
      system = pkgs.stdenv.hostPlatform.system;
      builder = "${pkgs.bash}/bin/bash";
      args = [ "-e" (pkgs.writeText "build-natively-${target.name or "build"}.sh" ''
        export PATH="${lib.makeBinPath [
          pkgs.qemu pkgs.coreutils pkgs.jq pkgs.nix
        ]}:$PATH"

        SHARE="$TMPDIR/vm-share"
        mkdir -p "$SHARE/out"

        TARGET_DRV="${targetDrv}"

        echo "=== buildNatively: $TARGET_DRV ==="

        NIX="nix --extra-experimental-features nix-command"

        if ! DRV_JSON=$($NIX derivation show "$TARGET_DRV" 2>&1); then
          echo "nix derivation show failed: $DRV_JSON" >&2
          exit 1
        fi

        # Fetch all input derivation outputs from the binary cache
        echo "Fetching build inputs..."
        for drv in $(echo "$DRV_JSON" | jq -r 'to_entries[0].value.inputDrvs | keys[]'); do
          echo "  realising $drv"
          nix-store --realise "$drv" 2>&1 | tail -1 || true
        done

        # Also ensure input sources are present
        for src in $(echo "$DRV_JSON" | jq -r 'to_entries[0].value.inputSrcs[]'); do
          echo "  source: $src"
        done

        # Generate the build script from the derivation
        {
          echo '#!/bin/sh'
          echo 'set -e'
          echo 'export out=/share/out'

          # Set all env vars from the derivation (except out, which we override)
          echo "$DRV_JSON" | jq -r '
            to_entries[0].value.env | to_entries[] |
            select(.key != "out") |
            "export " + .key + "=" + (.value | @sh)
          '

          # Invoke the builder with its args
          BUILDER=$(echo "$DRV_JSON" | jq -r 'to_entries[0].value.builder')
          ARGS=$(echo "$DRV_JSON" | jq -r 'to_entries[0].value.args | map(@sh) | join(" ")')
          echo "exec $BUILDER $ARGS"
        } > "$SHARE/build.sh"
        chmod +x "$SHARE/build.sh"

        echo "=== Booting Linux VM ==="

        ${qemuCmd}

        echo "=== VM exited ==="

        ${checkResult}

        mv "$SHARE/out" "$out"
      '') ];

      __recursive = true;
      requiredSystemFeatures = [ "recursive-nix" ];
    };
}
