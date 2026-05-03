{ pkgs, pkgsCrossLinux, lib, root }:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  isAarch64 = pkgs.stdenv.hostPlatform.isAarch64;

  arch =
    if isAarch64 then {
      kernel = "arm64";
      qemu = "aarch64";
      machine = "virt";
      image = "arch/arm64/boot/Image";
      imageName = "Image";
      console = "console=ttyAMA0 earlycon=pl011,0x9000000";
    } else {
      kernel = "x86_64";
      qemu = "x86_64";
      machine = "q35";
      image = "arch/x86/boot/bzImage";
      imageName = "bzImage";
      console = "console=ttyS0 earlycon=uart8250,io,0x3f8";
    };

  accel = if isDarwin then "hvf" else "kvm";

  # Darwin-only host-tool shims for glibc-isms macOS libc lacks.
  hostShims = pkgs.runCommand "kernel-host-shims" { } ''
    mkdir -p $out/include
    cat > $out/include/byteswap.h <<'EOF'
    #ifndef _BYTESWAP_H
    #define _BYTESWAP_H 1
    #define bswap_16(x) __builtin_bswap16(x)
    #define bswap_32(x) __builtin_bswap32(x)
    #define bswap_64(x) __builtin_bswap64(x)
    #endif
    EOF
    cat > $out/include/compat.h <<'EOF'
    #ifndef _DARWIN_LINUX_COMPAT_H
    #define _DARWIN_LINUX_COMPAT_H 1
    #include <string.h>
    static inline char *strchrnul(const char *s, int c) {
      char *p = strchr(s, c);
      return p ? p : (char *)s + strlen(s);
    }
    #endif
    EOF
  '';

  darwinHostCFLAGS = "-isystem ${hostShims}/include -include ${hostShims}/include/compat.h";

  # Arch-neutral options that apply to every target.
  kernelConfigCommon = ''
    # ---- No modules: everything compiled in -------------------------------
    # CONFIG_MODULES is not set

    # ---- Console / serial output ------------------------------------------
    CONFIG_PRINTK=y
    CONFIG_TTY=y
    CONFIG_SERIAL_EARLYCON=y
    # /dev/pts for SSH/PTY allocation (dropbear, screen, tmux).
    CONFIG_UNIX98_PTYS=y

    # ---- Userspace boot prerequisites -------------------------------------
    CONFIG_MULTIUSER=y
    CONFIG_BINFMT_ELF=y
    CONFIG_BINFMT_SCRIPT=y
    # The userspace-API syscalls below are all `default y if EXPERT` —
    # tinyconfig flips them off because allnoconfig sets EXPERT. Modern
    # userspace (Go runtime, container runtimes, libuv, glibc) requires
    # essentially all of them.
    CONFIG_FUTEX=y           # mutexes, condvars, Go scheduler
    CONFIG_FILE_LOCKING=y    # flock, fcntl F_SETLK
    CONFIG_EPOLL=y           # epoll_create/wait — Go netpoll, every event loop
    CONFIG_EVENTFD=y         # eventfd — Go runtime, containerd
    CONFIG_SIGNALFD=y        # signalfd — systemd-style signal handling
    CONFIG_TIMERFD=y         # timerfd — Go time.NewTimer at scale
    CONFIG_AIO=y             # io_submit — some Go libraries, databases
    CONFIG_DEVTMPFS=y
    CONFIG_DEVTMPFS_MOUNT=y
    CONFIG_PROC_FS=y
    CONFIG_PROC_SYSCTL=y
    CONFIG_SYSFS=y
    # tmpfs (and its xattr support) — needed to switch_root off the initial
    # ramfs into a real filesystem that supports xattrs (containerd overlay
    # upper) and statfs (kubelet/cAdvisor rootfs introspection).
    CONFIG_SHMEM=y
    CONFIG_TMPFS=y
    CONFIG_TMPFS_XATTR=y
    CONFIG_BLOCK=y
    CONFIG_BLK_DEV_INITRD=y
    CONFIG_RD_GZIP=y

    # ---- Networking core (needed by 9p) -----------------------------------
    CONFIG_NET=y
    CONFIG_INET=y
    CONFIG_PACKET=y
    CONFIG_UNIX=y

    # ---- PCI bus ----------------------------------------------------------
    CONFIG_PCI=y
    # Generic ECAM PCI host bridge (used by arm64 QEMU virt; harmless on x86)
    CONFIG_PCI_HOST_GENERIC=y
    CONFIG_PCI_ECAM=y
    # MSI is a hard dep of VIRTIO_PCI; without it VIRTIO_PCI is silently
    # dropped and virtio-pci devices never bind.
    CONFIG_PCI_MSI=y

    # ---- Network device support -------------------------------------------
    # tinyconfig disables NETDEVICES; without that, VIRTIO_NET (and any
    # other network drivers) are silently dropped.
    CONFIG_NETDEVICES=y
    CONFIG_NET_CORE=y

    # ---- virtio everything ------------------------------------------------
    # tinyconfig disables VIRTIO_MENU; without that, the transport drivers
    # (VIRTIO_PCI, VIRTIO_MMIO) are hidden and our =y lines for them are
    # silently dropped.
    CONFIG_VIRTIO_MENU=y
    CONFIG_VIRTIO=y
    CONFIG_VIRTIO_PCI=y
    CONFIG_VIRTIO_MMIO=y
    CONFIG_VIRTIO_BLK=y
    CONFIG_VIRTIO_NET=y
    CONFIG_VIRTIO_CONSOLE=y
    CONFIG_VIRTIO_BALLOON=y
    CONFIG_HW_RANDOM=y
    CONFIG_HW_RANDOM_VIRTIO=y

    # ---- BPF --------------------------------------------------------------
    # CGROUP_BPF requires BPF_SYSCALL; modern container runtimes also use
    # BPF for filtering, tracing, etc.
    CONFIG_BPF=y
    CONFIG_BPF_SYSCALL=y
    CONFIG_BPF_JIT=y

    # ---- SysV IPC ---------------------------------------------------------
    # IPC_NS requires SYSVIPC or POSIX_MQUEUE; SYSVIPC is the conventional
    # choice and what most container tooling expects.
    CONFIG_SYSVIPC=y
    # POSIX message queues — runc's default OCI mounts include /dev/mqueue,
    # which fails to mount with "no such device" without this.
    CONFIG_POSIX_MQUEUE=y

    # ---- Cgroups (v2) -----------------------------------------------------
    # k3s/containerd require cgroups for resource accounting & isolation.
    CONFIG_CGROUPS=y
    CONFIG_MEMCG=y
    CONFIG_BLK_CGROUP=y
    CONFIG_CGROUP_PIDS=y
    CONFIG_CGROUP_FREEZER=y
    CONFIG_CGROUP_DEVICE=y
    CONFIG_CGROUP_CPUACCT=y
    CONFIG_CGROUP_SCHED=y
    # cpu.max in cgroup v2 — kubelet sets CPU limits via this; missing it
    # produces "openat2 /sys/fs/cgroup/.../cpu.max: no such file or directory"
    # at container start. CFS_BANDWIDTH depends on FAIR_GROUP_SCHED.
    CONFIG_FAIR_GROUP_SCHED=y
    CONFIG_CFS_BANDWIDTH=y
    CONFIG_CGROUP_BPF=y
    # k3s/kubelet require cpuset; tinyconfig disables it.
    CONFIG_CPUSETS=y

    # ---- Namespaces -------------------------------------------------------
    # Required for any container creation.
    CONFIG_NAMESPACES=y
    CONFIG_UTS_NS=y
    CONFIG_IPC_NS=y
    CONFIG_PID_NS=y
    CONFIG_USER_NS=y
    CONFIG_NET_NS=y

    # ---- Overlay filesystem -----------------------------------------------
    # Used by containerd's snapshotter for layered container images.
    CONFIG_OVERLAY_FS=y

    # ---- Inotify ----------------------------------------------------------
    # Used by kubelet, containerd, dynamic plugin discovery.
    CONFIG_INOTIFY_USER=y

    # ---- Kernel keyring ---------------------------------------------------
    # kubelet's ContainerManager reads /proc/sys/kernel/keys/root_max{keys,bytes}.
    CONFIG_KEYS=y

    # ---- Seccomp ----------------------------------------------------------
    # containerd's runc backend sets seccomp filters on every pod sandbox.
    CONFIG_SECCOMP=y
    CONFIG_SECCOMP_FILTER=y

    # ---- Netfilter / iptables for kube-proxy ------------------------------
    CONFIG_NETFILTER=y
    CONFIG_NETFILTER_ADVANCED=y
    CONFIG_NETFILTER_NETLINK=y
    CONFIG_NF_CONNTRACK=y
    CONFIG_NF_NAT=y
    # Xtables umbrella — gates all NETFILTER_XT_* and NFT_COMPAT.
    CONFIG_NETFILTER_XTABLES=y
    # nftables backend (modern iptables-nft uses this).
    CONFIG_NF_TABLES=y
    CONFIG_NF_TABLES_IPV4=y
    CONFIG_NF_TABLES_IPV6=y
    CONFIG_NF_TABLES_INET=y
    # NAT primitives for nftables — needed by kube-proxy service routing.
    CONFIG_NFT_NAT=y
    CONFIG_NFT_MASQ=y
    # iptables-over-nftables compat layer (the iptables-nft binary uses this
    # to translate iptables-style rules into nftables under the hood).
    CONFIG_NFT_COMPAT=y
    # xt match/target primitives kube-proxy uses (still relevant under
    # NFT_COMPAT — these are the rule-element implementations).
    CONFIG_NETFILTER_XT_NAT=y
    CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
    CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y
    CONFIG_NETFILTER_XT_MATCH_COMMENT=y
    CONFIG_NETFILTER_XT_TARGET_REDIRECT=y
    # REJECT for kube-proxy (services with no endpoints). NFT_REJECT enables
    # the nftables-native reject expression; NFT_REJECT_IPV{4,6} are silent
    # options auto-tracking NFT_REJECT when the corresponding family is
    # enabled (we have NF_TABLES_IPV4/IPV6). iptables-nft translates
    # `-j REJECT` to this when xt_REJECT isn't available.
    CONFIG_NFT_REJECT=y
    CONFIG_NFT_REJECT_INET=y
    # KUBE-MARK-MASQ / KUBE-MARK-DROP fwmark accounting and service connection
    # routing. CONNMARK is used by kube-proxy for affinity tracking.
    CONFIG_NETFILTER_XT_TARGET_MARK=y
    CONFIG_NETFILTER_XT_MATCH_MARK=y
    CONFIG_NETFILTER_XT_TARGET_CONNMARK=y
    CONFIG_NETFILTER_XT_MATCH_CONNMARK=y
    CONFIG_NETFILTER_XT_TARGET_MASQUERADE=y
    CONFIG_NETFILTER_XT_MATCH_MULTIPORT=y
    CONFIG_NETFILTER_XT_MATCH_STATISTIC=y
    CONFIG_NETFILTER_XT_MATCH_RECENT=y
    # Used by the embedded kube-router NetworkPolicy controller in k3s.
    CONFIG_NETFILTER_XT_MATCH_PHYSDEV=y
    CONFIG_NETFILTER_XT_MATCH_LIMIT=y
    CONFIG_NETFILTER_XT_TARGET_NFLOG=y
    CONFIG_NETFILTER_NETLINK_LOG=y
    # ipset + xt_set: kube-router uses these for NetworkPolicy.
    CONFIG_IP_SET=y
    CONFIG_IP_SET_HASH_IP=y
    CONFIG_IP_SET_HASH_NET=y
    CONFIG_NETFILTER_XT_SET=y
    # NFT expressions iptables-nft emits when translating xtables rules.
    # (NFT_COUNTER no longer has a Kconfig — nft_counter.o is unconditionally
    #  linked into nf_tables.o in modern kernels.)
    CONFIG_NFT_CT=y
    CONFIG_NFT_LIMIT=y
    CONFIG_NFT_LOG=y
    CONFIG_NFT_REJECT=y
    CONFIG_NFT_REJECT_IPV4=y
    CONFIG_NFT_REJECT_IPV6=y
    # NAT primitives — usually auto-selected by the xt_* targets above, but
    # pinning them explicitly so olddefconfig can't silently drop them.
    CONFIG_NF_NAT_MASQUERADE=y
    CONFIG_NF_NAT_REDIRECT=y

    # Legacy iptables IPv4/IPv6 families. iptables-nft-1.8.11 routes
    # several -j/-m operations (REJECT, MARK target with --xor-mark) through
    # the xt_* compat path which only resolves with these enabled in kernel.
    # Without them: "RULE_APPEND failed (No such file or directory)" and
    # "Extension X revision Y not supported, missing kernel module?".
    #
    # In modern kernels (7.x), IP_NF_FILTER/MANGLE/NAT depend on
    # IP_NF_IPTABLES_LEGACY, which in turn requires NETFILTER_XTABLES_LEGACY.
    CONFIG_NETFILTER_XTABLES_LEGACY=y
    CONFIG_IP_NF_IPTABLES_LEGACY=y
    CONFIG_IP_NF_IPTABLES=y
    CONFIG_IP_NF_FILTER=y
    CONFIG_IP_NF_NAT=y
    CONFIG_IP_NF_MANGLE=y
    CONFIG_IP_NF_TARGET_REJECT=y
    CONFIG_IP6_NF_IPTABLES_LEGACY=y
    CONFIG_IP6_NF_IPTABLES=y
    CONFIG_IP6_NF_FILTER=y
    CONFIG_IP6_NF_NAT=y
    CONFIG_IP6_NF_MANGLE=y
    CONFIG_IP6_NF_TARGET_REJECT=y

    # ---- Bridge / veth / tun (pod networking) -----------------------------
    CONFIG_BRIDGE=y
    CONFIG_BRIDGE_NETFILTER=y
    CONFIG_VETH=y
    CONFIG_TUN=y
    # flannel default backend uses VXLAN tunnels for pod overlay networking.
    CONFIG_VXLAN=y

    # ---- Real-time clock --------------------------------------------------
    # Without an RTC driver, system time stays at epoch zero forever; k3s
    # (and most server software) refuses to start. RTC_HCTOSYS sets the
    # system clock from the RTC at boot.
    CONFIG_RTC_CLASS=y
    CONFIG_RTC_HCTOSYS=y

    # ---- 9p shared filesystem (host /nix into guest) ----------------------
    CONFIG_NET_9P=y
    CONFIG_NET_9P_VIRTIO=y
    CONFIG_9P_FS=y
    CONFIG_9P_FS_POSIX_ACL=y
  '';

  kernelConfigArm64 = ''
    # ---- arm64 QEMU virt: PL011 UART --------------------------------------
    CONFIG_SERIAL_AMBA_PL011=y
    CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
    # arm64 QEMU virt provides a PL031 AMBA RTC.
    CONFIG_RTC_DRV_PL031=y
    # arm64 needs GICv3 + ITS for PCI MSI to actually work at runtime;
    # without ITS, virtio-pci tries to allocate MSI-X, fails, and never binds.
    CONFIG_ARM_GIC_V3=y
    CONFIG_ARM_GIC_V3_ITS=y
    # GICv2 fallback (some QEMU machine configs) and its MSI bridge.
    CONFIG_ARM_GIC=y
    CONFIG_ARM_GIC_V2M=y
  '';

  kernelConfigX86 = ''
    # ---- x86_64 QEMU q35: 8250 UART ---------------------------------------
    CONFIG_SERIAL_8250=y
    CONFIG_SERIAL_8250_CONSOLE=y
    # x86_64 QEMU q35 has the standard PC CMOS RTC.
    CONFIG_RTC_DRV_CMOS=y
    # ---- Hypervisor-guest support -----------------------------------------
    CONFIG_HYPERVISOR_GUEST=y
    CONFIG_PARAVIRT=y
    CONFIG_KVM_GUEST=y
    CONFIG_ACPI=y
  '';

  kernelConfigFragment = pkgs.writeText "kernel.config" (
    kernelConfigCommon
    + (if isAarch64 then kernelConfigArm64 else kernelConfigX86)
  );

  # Kernel src is the linux flake input — pure kernel tree, no nix/ or
  # flake.nix to exclude (those live in this repo, not in linux).
  kernelSrc = root;

  kernel = pkgs.stdenv.mkDerivation {
    pname = "linux";
    version = "0.0.1";

    src = kernelSrc;

    dontPatchELF = true;
    dontStrip = true;

    nativeBuildInputs = [
      pkgs.gnumake
      pkgs.flex
      pkgs.bison
      pkgs.lld
      pkgs.elf-header
      pkgs.bc
      pkgs.llvm
      pkgs.openssl
      pkgs.perl
      pkgs.python3
    ];

    configurePhase = ''
      runHook preConfigure
      make -j"$NIX_BUILD_CORES" ARCH=${arch.kernel} LLVM=1 tinyconfig
      ARCH=${arch.kernel} ./scripts/kconfig/merge_config.sh -m .config ${kernelConfigFragment}
      make -j"$NIX_BUILD_CORES" ARCH=${arch.kernel} LLVM=1 olddefconfig

      # Fail loudly if olddefconfig silently dropped any CONFIG_*=y line we
      # asked for (e.g. due to a missing menuconfig gate or unmet dep).
      missing=$(
        awk -F= '/^CONFIG_[A-Z0-9_]+=y$/{print $1"=y"}' ${kernelConfigFragment} \
          | sort -u \
          | comm -23 - <(grep -E '^CONFIG_[A-Z0-9_]+=y$' .config | sort -u)
      )
      if [ -n "$missing" ]; then
        echo "ERROR: the following options were silently dropped by olddefconfig:" >&2
        echo "$missing" | sed 's/^/  /' >&2
        echo "Look for an unmet dep or a parent menuconfig set to n in tinyconfig." >&2
        exit 1
      fi

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      make -j"$NIX_BUILD_CORES" ARCH=${arch.kernel} LLVM=1 \
        CC=${pkgs.llvmPackages.clang-unwrapped}/bin/clang \
        ${pkgs.lib.optionalString isDarwin ''HOSTCFLAGS="${darwinHostCFLAGS}"''}
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp ${arch.image} $out/${arch.imageName}
      cp vmlinux $out/
      cp System.map $out/
      cp .config $out/config
      runHook postInstall
    '';
  };

  # All Linux-targeted binaries are cross-built from this host via
  # pkgsCrossLinux — single, consistent build mode, no cache mixing.
  busyboxStatic = pkgsCrossLinux.pkgsStatic.busybox;
  k3s = pkgsCrossLinux.k3s_1_36;
  strace = pkgsCrossLinux.strace;
  nix = pkgsCrossLinux.nix;
  socat = pkgsCrossLinux.socat;
  iptables = pkgsCrossLinux.iptables;
  dropbear = pkgsCrossLinux.dropbear;
  cacert = pkgsCrossLinux.cacert;
  # kubectl/crictl are embedded in the k3s binary — use multicall symlinks
  # rather than a separate cross-build (kubectl cross-from-darwin currently
  # fails: the build patches shebangs to the target's bash and then tries to
  # exec one).
  k9s = pkgsCrossLinux.k9s;
  kubernetes-helm = pkgsCrossLinux.kubernetes-helm;

  # SSH pubkey baked into the VM so you can `ssh -p 2222 root@127.0.0.1`.
  sshAuthorizedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC4vmj1CAkxctWi8CC/2Ox9TlvOJhwVGvGJTr7jPCuZR user@macbook.local";

  # Host port that QEMU forwards to the guest's SSH (22).
  sshHostPort = "2222";

  # nix-daemon socket port we proxy from host into guest via TCP over the
  # QEMU user-mode network. 10.0.2.2 is the host as seen by the guest.
  daemonProxyPort = "9999";

  # Tiny C program that reports the host's CPU count and total RAM.
  # Portable across macOS / Linux / FreeBSD / NetBSD / OpenBSD via #ifdef
  # blocks; built with stdenv's compiler so no extra toolchain.
  hostInfo = pkgs.runCommandCC "host-info" { } ''
    mkdir -p $out/bin
    cat > host-info.c <<'CSRC'
    #include <stdio.h>
    #include <string.h>
    #include <stdint.h>
    #include <unistd.h>

    #if defined(__APPLE__) || defined(__FreeBSD__) || \
        defined(__NetBSD__) || defined(__OpenBSD__)
    #  include <sys/sysctl.h>
    #endif

    #if defined(__linux__)
    #  include <sys/sysinfo.h>
    #endif

    static long long total_memory_bytes(void) {
    #if defined(__APPLE__)
        int64_t mem = 0;
        size_t sz = sizeof(mem);
        if (sysctlbyname("hw.memsize", &mem, &sz, NULL, 0) != 0) return -1;
        return (long long)mem;
    #elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
        uint64_t mem = 0;
        size_t sz = sizeof(mem);
        if (sysctlbyname("hw.physmem", &mem, &sz, NULL, 0) != 0) return -1;
        return (long long)mem;
    #elif defined(__linux__)
        struct sysinfo info;
        if (sysinfo(&info) != 0) return -1;
        return (long long)info.totalram * (long long)info.mem_unit;
    #else
        return -1;
    #endif
    }

    /* P-core count on Apple Silicon, physical-core count on Intel Mac /
       FreeBSD, logical-core count everywhere else. The user can always
       override via VM_CPUS=N. */
    static long cpu_count(void) {
    #if defined(__APPLE__)
        int sn = 0;
        size_t sz = sizeof(sn);
        if (sysctlbyname("hw.perflevel0.physicalcpu", &sn, &sz, NULL, 0) == 0 && sn > 0)
            return sn;
        if (sysctlbyname("hw.physicalcpu", &sn, &sz, NULL, 0) == 0 && sn > 0)
            return sn;
    #elif defined(__FreeBSD__)
        int sn = 0;
        size_t sz = sizeof(sn);
        if (sysctlbyname("kern.smp.cores", &sn, &sz, NULL, 0) == 0 && sn > 0)
            return sn;
    #endif
        long n = sysconf(_SC_NPROCESSORS_ONLN);
        return n > 0 ? n : 1;
    }

    int main(int argc, char **argv) {
        if (argc != 2) {
            fprintf(stderr, "usage: %s {cpus|memory-bytes|memory-mb}\n",
                    argv[0]);
            return 2;
        }
        if (strcmp(argv[1], "cpus") == 0) {
            printf("%ld\n", cpu_count());
            return 0;
        }
        long long m = total_memory_bytes();
        if (m < 0) { fprintf(stderr, "could not detect memory\n"); return 1; }
        if (strcmp(argv[1], "memory-bytes") == 0) printf("%lld\n", m);
        else if (strcmp(argv[1], "memory-mb") == 0) printf("%lld\n", m / 1024 / 1024);
        else { fprintf(stderr, "unknown: %s\n", argv[1]); return 2; }
        return 0;
    }
    CSRC
    cc -O2 -Wall -Wextra -o $out/bin/host-info host-info.c
  '';

  # Minimal initramfs: busybox + a shell script that mounts /nix from the
  # host via 9p and drops to a shell.
  initramfs = pkgs.runCommand "initramfs.cpio.gz"
    {
      nativeBuildInputs = [ pkgs.cpio pkgs.gzip ];
    } ''
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT"/{bin,dev,proc,sys,nix,tmp,root}
    cp ${busyboxStatic}/bin/busybox "$ROOT/bin/busybox"
    chmod +x "$ROOT/bin/busybox"
    cat > "$ROOT/init" <<'INIT_EOF'
    #!/bin/busybox sh
    /bin/busybox --install -s /bin

    # If we're still on the initial ramfs (kubelet/cAdvisor can't introspect
    # 'rootfs' / 'ramfs' filesystem types), pivot to a tmpfs root and re-exec
    # this same script from there. Subsequent invocations skip this block
    # because /proc/mounts shows / as tmpfs.
    mkdir -p /proc /sysroot
    mount -t proc none /proc 2>/dev/null || true
    ROOTFS_TYPE=$(awk '$2 == "/" {print $3; exit}' /proc/mounts 2>/dev/null)
    umount /proc 2>/dev/null || true
    if [ "$ROOTFS_TYPE" = "rootfs" ] || [ "$ROOTFS_TYPE" = "ramfs" ]; then
      echo "Pivoting from initramfs ($ROOTFS_TYPE) to tmpfs root"
      mount -t tmpfs -o size=4G,mode=755 tmpfs /sysroot
      # Create the directory tree stage2 expects to mount/populate. Without
      # /dev existing on the new tmpfs, even shell redirections to /dev/null
      # fail before mounts run. busybox sh has no brace expansion (bash
      # feature), so list the dirs explicitly.
      for d in bin dev etc nix proc root run sys tmp var; do
        mkdir -p "/sysroot/$d"
      done
      cp /bin/busybox /sysroot/bin/busybox
      cp /init /sysroot/init
      chmod +x /sysroot/init
      exec switch_root /sysroot /init
    fi

    # nix CLI looks up $HOME for ~/.config; minimal init has no env.
    export HOME=/root
    # UTC everywhere — reproducible default; no zoneinfo files needed.
    export TZ=UTC
    # All nix-* binaries (nix-store, nix-build, ...) on PATH for k3s/snapshotter.
    # iptables on PATH for kube-proxy.
    export PATH=${nix}/bin:${iptables}/bin:/bin:/sbin
    # Enable nix-command + flakes (k3s-side tooling tends to use the new CLI).
    export NIX_CONFIG="experimental-features = nix-command flakes"
    mount -t proc none /proc
    mount -t sysfs none /sys
    # CONFIG_DEVTMPFS_MOUNT=y is suppressed under initramfs; mount manually
    # so /dev/kmsg, /dev/null, /dev/random, etc. are available to userspace.
    mount -t devtmpfs none /dev
    mkdir -p /dev/pts
    mount -t devpts none /dev/pts
    mkdir -p /sys/fs/cgroup
    mount -t cgroup2 none /sys/fs/cgroup
    mkdir -p /run
    mount -t ramfs none /run
    mkdir -p /nix /etc /root
    # Minimal passwd/group so getpwuid()-based lookups succeed (nix CLI etc.)
    echo 'root:x:0:0:root:/root:/bin/sh' > /etc/passwd
    echo 'root:x:0:' > /etc/group
    # Static hostname & machine-id — k3s rejects "(none)" hostname as an
    # invalid label value; kubelet warns about missing /etc/machine-id.
    hostname k3s-vm
    echo k3s-vm > /etc/hostname
    echo "00000000000000000000000000000000" > /etc/machine-id
    # /etc/hosts — containerd copies this into every pod sandbox; without
    # it, sandbox creation fails.
    cat > /etc/hosts <<HOSTS_EOF
    127.0.0.1   localhost
    ::1         localhost ip6-localhost ip6-loopback
    HOSTS_EOF

    # CA bundle so containerd / Go TLS clients can verify registry certs.
    mkdir -p /etc/ssl/certs
    ln -sf ${cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
    if mount -t 9p -o trans=virtio,version=9p2000.L,ro nix-store /nix 2>/dev/null; then
      echo "Mounted host /nix at /nix"
    else
      echo "WARN: failed to mount /nix from host"
    fi

    # Networking — QEMU user-mode defaults (10.0.2.0/24)
    echo "nameserver 10.0.2.3" > /etc/resolv.conf
    ip link set lo up
    if ip link set eth0 up 2>/dev/null && \
       ip addr add 10.0.2.15/24 dev eth0 2>/dev/null && \
       ip route add default via 10.0.2.2 2>/dev/null; then
      echo "Network configured: eth0 = 10.0.2.15/24"
    else
      echo "WARN: failed to configure eth0"
    fi

    # Surface tools on PATH (binaries live in the host /nix mount).
    ln -sf ${k3s}/bin/k3s /bin/k3s
    ln -sf ${strace}/bin/strace /bin/strace
    ln -sf ${nix}/bin/nix /bin/nix
    ln -sf ${socat}/bin/socat /bin/socat
    # kubectl/crictl/ctr are k3s subcommands — nixpkgs already creates the
    # multicall symlinks alongside the k3s binary; re-symlink them on PATH.
    ln -sf ${k3s}/bin/kubectl /bin/kubectl
    ln -sf ${k3s}/bin/crictl /bin/crictl
    ln -sf ${k3s}/bin/ctr /bin/ctr
    ln -sf ${k9s}/bin/k9s /bin/k9s
    ln -sf ${kubernetes-helm}/bin/helm /bin/helm

    # kubectl/k9s want $KUBECONFIG; k3s writes its kubeconfig here.
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # Bridge nix-daemon socket from host: guest UNIX socket ⇆ host TCP.
    socat UNIX-LISTEN:/run/nix-daemon.sock,fork,unlink-early \
          TCP:10.0.2.2:${daemonProxyPort} 2>/dev/null &
    export NIX_REMOTE=unix:///run/nix-daemon.sock

    # SSH server (dropbear): regenerate host key per boot, install the
    # baked-in pubkey, listen on :22 (host port ${sshHostPort} → :22).
    mkdir -p /etc/dropbear /root/.ssh /var/run
    echo '${sshAuthorizedKey}' > /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    ${dropbear}/bin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null
    ${dropbear}/bin/dropbear -E -r /etc/dropbear/dropbear_ed25519_host_key 2>&1 &

    echo "Test daemon bridge: nix store info"
    echo "SSH from host: ssh -p ${sshHostPort} root@127.0.0.1"

    # Auto-start k3s in background. Detach stdio so we can drop to an
    # interactive shell without log spew interleaving with the prompt.
    # PID and log are pinned to fixed paths for easy inspection:
    #   tail -f /var/log/k3s.log
    #   kill $(cat /run/k3s.pid)
    mkdir -p /var/log
    echo "Starting k3s server in background; logs at /var/log/k3s.log"
    k3s server --snapshotter=nix </dev/null >/var/log/k3s.log 2>&1 &
    echo $! > /run/k3s.pid

    exec /bin/sh
    INIT_EOF
    chmod +x "$ROOT/init"
    chmod +x "$ROOT/init"
    (cd "$ROOT" && find . | cpio -H newc -o 2>/dev/null | gzip -9 > $out)
  '';

  run = pkgs.writeShellApplication {
    name = "run-kernel";
    runtimeInputs = [ pkgs.qemu pkgs.socat ];
    text = ''
      # Default to half the host's CPUs and RAM, detected by a tiny C helper
      # that's portable across macOS / Linux / FreeBSD. Override with
      # VM_CPUS / VM_MEM_MB env vars.
      HOST_CPUS=$(${hostInfo}/bin/host-info cpus)
      HOST_MEM_MB=$(${hostInfo}/bin/host-info memory-mb)
      VM_CPUS="''${VM_CPUS:-$((HOST_CPUS / 2))}"
      VM_MEM_MB="''${VM_MEM_MB:-$((HOST_MEM_MB / 2))}"
      [ "$VM_CPUS"   -lt 2    ] && VM_CPUS=2
      [ "$VM_MEM_MB" -lt 4096 ] && VM_MEM_MB=4096

      # Bridge host nix-daemon socket onto a TCP port the guest can reach
      # via QEMU's user-mode networking (host appears as 10.0.2.2).
      DAEMON_SOCK="''${NIX_DAEMON_SOCKET:-/nix/var/nix/daemon-socket/socket}"
      if [ -S "$DAEMON_SOCK" ]; then
        socat TCP-LISTEN:${daemonProxyPort},bind=127.0.0.1,reuseaddr,fork \
              "UNIX-CONNECT:$DAEMON_SOCK" 2>/dev/null &
        SOCAT_PID=$!
        trap 'kill $SOCAT_PID 2>/dev/null || true' EXIT
      else
        echo "warning: no nix-daemon socket at $DAEMON_SOCK; guest daemon proxy disabled" >&2
      fi

      echo "VM: $VM_CPUS CPUs, ''${VM_MEM_MB} MB RAM"

      qemu-system-${arch.qemu} \
        -machine ${arch.machine} \
        -cpu host \
        -accel ${accel} \
        -smp "$VM_CPUS" \
        -m "''${VM_MEM_MB}M" \
        -nographic \
        -no-reboot \
        -rtc base=utc,clock=host \
        -kernel ${kernel}/${arch.imageName} \
        -initrd ${initramfs} \
        -fsdev local,id=nixstore_fsdev,path=/nix,security_model=none,readonly=on \
        -device virtio-9p-pci,fsdev=nixstore_fsdev,mount_tag=nix-store \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${sshHostPort}-:22 \
        -device virtio-net-pci,netdev=net0 \
        -append "${arch.console} panic=-1" \
        "$@"
    '';
  };
in
{ inherit kernel initramfs run; }
