{ pkgs, pkgsCrossLinux, lib }:
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
    } else {
      kernel = "x86_64";
      qemu = "x86_64";
      machine = "q35";
      image = "arch/x86/boot/bzImage";
      imageName = "bzImage";
    };

  # Single kernel cmdline for both runners: virtio-console is the only
  # console hardware vfkit emulates, and qemu can also wire it up. No
  # earlycon (virtio-console has no earlycon driver) — early boot logs
  # are still in the kernel ring buffer (dmesg) just not on the
  # terminal. Add `earlycon=pl011,0x9000000` (arm) or
  # `earlycon=uart8250,io,0x3f8` (x86) to debug pre-virtio init.
  kernelCmdline = "console=hvc0 panic=-1";

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

    # ---- Shared filesystem (host /nix into guest) -------------------------
    # virtiofs is the lingua franca of our runner backends: qemu speaks
    # it via virtiofsd, and vfkit only supports virtiofs. Standardizing
    # on it keeps the guest-side mount identical regardless of which
    # backend the host runs. 9p is kept as a fallback during the
    # qemu-vs-vfkit runner work.
    CONFIG_VIRTIO_FS=y
    CONFIG_FUSE_FS=y
    CONFIG_NET_9P=y
    CONFIG_NET_9P_VIRTIO=y
    CONFIG_9P_FS=y
    CONFIG_9P_FS_POSIX_ACL=y

    # ---- Persistent data disk (ext4 on /dev/vda → /var) -------------------
    # Format-on-first-boot then mount at /var so containerd images,
    # snapshots, k3s state, and logs survive reboots. ACLs + xattrs are
    # required by containerd's overlay snapshotter.
    CONFIG_EXT4_FS=y
    CONFIG_EXT4_FS_POSIX_ACL=y
    CONFIG_EXT4_FS_SECURITY=y
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

  # Kernel source — fetched as a tarball from the personal linux fork.
  # We do NOT use a flake input for this: flake input materialization
  # extracts to the case-insensitive nix store, and the kernel tree has
  # ~12 case-pair files (xt_CONNMARK.h ↔ xt_connmark.h, etc.) that
  # collapse onto a single inode, with non-deterministic content survival.
  # Fetching the .tar.gz directly lets the build use `tar -xOf <exact
  # case-name>` to overwrite case-folded paths with deterministic content
  # (see prePatch in the kernel derivation below).
  #
  # Update `linuxRev` + `linuxHash` when you push new commits to the
  # linux fork. lib.fakeHash on first build to discover the right hash.
  linuxRev = "aa13ad0833fd4eaa8eecea64a310f7b16e1e28a8";
  linuxHash = "sha256-Sjsd8KHjvsIbHyt/j1x+lHHLX8PKiBsWWuIHOF55Xw0=";

  kernelSrc = pkgs.fetchurl {
    url = "https://github.com/jonhermansen/linux/archive/${linuxRev}.tar.gz";
    hash = linuxHash;
  };

  # Files where the kernel ships an uppercase shim alongside the lowercase
  # peer that holds the actual struct/enum definitions. On case-insensitive
  # FS only one inode survives extraction; we re-extract the lowercase
  # entry by exact name from the tarball, redirecting to the lowercase
  # path. That overwrites the case-folded inode's content with the full
  # content (the lowercase peer's), so subsequent #includes resolve
  # correctly regardless of which case-name won the initial race.
  kernelCaseFoldFiles = [
    "include/uapi/linux/netfilter/xt_connmark.h"
    "include/uapi/linux/netfilter/xt_dscp.h"
    "include/uapi/linux/netfilter/xt_mark.h"
    "include/uapi/linux/netfilter/xt_rateest.h"
    "include/uapi/linux/netfilter/xt_tcpmss.h"
    "include/uapi/linux/netfilter_ipv4/ipt_ttl.h"
    "include/uapi/linux/netfilter_ipv6/ip6t_hl.h"
    "net/netfilter/xt_dscp.c"
    "net/netfilter/xt_hl.c"
    "net/netfilter/xt_rateest.c"
    "net/netfilter/xt_tcpmss.c"
  ];

  kernel = pkgs.stdenv.mkDerivation {
    pname = "linux";
    version = "7.0.3";

    src = kernelSrc;

    # vmlinux is an ELF, but it's a kernel image — no RPATH to shrink, no
    # DT_NEEDED to rewrite. Skip the patchelf fixup hook (installed by the
    # patchelf package via setup-hook.sh) to make intent explicit.
    dontPatchELF = true;
    # Preserve vmlinux symbols for /System.map and kernel debugging.
    dontStrip = true;

    # Case-fold collision fixup. After unpackPhase the source tree may
    # have either case-name surviving for each pair, with arbitrary
    # content. Re-extract the lowercase entry from the tarball directly
    # (tar reads its index by exact case, not the FS), redirecting to
    # the lowercase path. That overwrites the case-folded inode's
    # content with the full definitions.
    prePatch = ''
      for f in ${lib.concatStringsSep " " kernelCaseFoldFiles} ; do
        tar -xOzf $src "$sourceRoot/$f" > "$f"
      done
    '';

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
  e2fsprogs = pkgsCrossLinux.e2fsprogs;
  cacert = pkgsCrossLinux.cacert;
  # kubectl/crictl are embedded in the k3s binary — use multicall symlinks
  # rather than a separate cross-build (kubectl cross-from-darwin currently
  # fails: the build patches shebangs to the target's bash and then tries to
  # exec one).
  k9s = pkgsCrossLinux.k9s;
  kubernetes-helm = pkgsCrossLinux.kubernetes-helm;
  nano = pkgsCrossLinux.nano;
  # Bundled images (pause, traefik, coredns, local-path, metrics-server)
  # as a tar.zst k3s imports on startup. Avoids needing DNS + a working
  # image-registry connection from the guest.
  k3sAirgapImages = pkgsCrossLinux.k3s_1_36.airgap-images;
  # terminfo database — TUI apps (k9s, vi, htop, less -R) read it via
  # ncurses to learn what escape sequences a given $TERM accepts. Without
  # a terminfo dir on PATH, tcell-based apps like k9s fail to initialize.
  ncurses = pkgsCrossLinux.ncurses;

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

  # Bake @VAR@ placeholders → /nix/store paths in our shell scripts.
  # `pkgs.replaceVars` (formerly `substituteAll`, removed 2025-05-23)
  # produces a derivation whose output is the script with substitutions
  # applied; it errors if a placeholder is unmatched or unused.
  scriptInit = pkgs.replaceVars ./scripts/init {
    nix = "${nix}";
    iptables = "${iptables}";
    k3s = "${k3s}";
    strace = "${strace}";
    socat = "${socat}";
    k9s = "${k9s}";
    nano = "${nano}";
    kubernetes-helm = "${kubernetes-helm}";
    cacert = "${cacert}";
    ncurses = "${ncurses}";
    dropbear = "${dropbear}";
    e2fsprogs = "${e2fsprogs}";
    sshAuthorizedKey = sshAuthorizedKey;
    k3sAirgapImages = "${k3sAirgapImages}";
  };
  scriptUdhcpcLease = ./scripts/udhcpc.script;
  scriptSvUdhcpc = ./scripts/sv/udhcpc/run;
  scriptSvNixBridge = pkgs.replaceVars ./scripts/sv/nix-bridge/run {
    daemonProxyPort = toString daemonProxyPort;
  };
  scriptSvDropbear = pkgs.replaceVars ./scripts/sv/dropbear/run {
    dropbear = "${dropbear}";
  };
  scriptSvK3s = ./scripts/sv/k3s/run;
  scriptSvK3sLog = ./scripts/sv/k3s/log/run;

  # Minimal initramfs: busybox + /init + /etc/sv/<svc>/run runit
  # service dirs + /etc/udhcpc.script DHCP lease handler.
  initramfs = pkgs.runCommand "initramfs.cpio.gz"
    {
      nativeBuildInputs = [ pkgs.cpio pkgs.gzip ];
    } ''
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT"/{bin,dev,proc,sys,nix,tmp,root,etc/sv/udhcpc,etc/sv/nix-bridge,etc/sv/dropbear,etc/sv/k3s/log}
    cp ${busyboxStatic}/bin/busybox "$ROOT/bin/busybox"
    chmod +x "$ROOT/bin/busybox"

    install -m 0755 ${scriptInit}             "$ROOT/init"
    install -m 0755 ${scriptUdhcpcLease}      "$ROOT/etc/udhcpc.script"
    install -m 0755 ${scriptSvUdhcpc}         "$ROOT/etc/sv/udhcpc/run"
    install -m 0755 ${scriptSvNixBridge}      "$ROOT/etc/sv/nix-bridge/run"
    install -m 0755 ${scriptSvDropbear}       "$ROOT/etc/sv/dropbear/run"
    install -m 0755 ${scriptSvK3s}            "$ROOT/etc/sv/k3s/run"
    install -m 0755 ${scriptSvK3sLog}         "$ROOT/etc/sv/k3s/log/run"

    (cd "$ROOT" && find . | cpio -H newc -o 2>/dev/null | gzip -9 > $out)
  '';

  # ============================================================
  # OLD inline-init derivation, kept until the file-based version is
  # validated to boot. Remove this whole heredoc once `nix run` works
  # with the new initramfs.
  # ============================================================
  _initramfsLegacy = pkgs.runCommand "initramfs-legacy.cpio.gz"
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
    # Persist nix CLI config in the canonical location instead of env
    # vars (SSH sessions and any spawned subprocess inherit it
    # automatically; no need to re-export per-shell).
    #   - experimental-features: enable nix-command + flakes
    #   - store: point at the daemon socket bridged from the host. The
    #     default path /nix/var/nix/daemon-socket/socket is unusable
    #     because the entire /nix tree is mounted read-only from the
    #     host (the 9p share is path=/nix), so we host the bridged
    #     socket on a writable tmpfs at /run/ instead.
    mkdir -p /etc/nix
    cat > /etc/nix/nix.conf <<'NIX_CONF_EOF'
    experimental-features = nix-command flakes
    store = unix:///run/nix-daemon.sock
    NIX_CONF_EOF
    # TUI apps (k9s, vi, less -R) and busybox-sh job control both need a
    # terminfo entry; the kernel console is closest to TERM=linux. SSH
    # sessions get TERM from the client, so this only matters on the
    # serial console. ncurses finds the terminfo db via the
    # /etc/terminfo symlink (set up below) without needing TERMINFO_DIRS.
    export TERM=linux
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
    # terminfo at /etc/terminfo for tools that don't honor TERMINFO_DIRS.
    ln -sf ${ncurses}/share/terminfo /etc/terminfo
    # Try virtiofs first (vfkit, qemu+virtiofsd), then 9p (qemu on
    # darwin where virtiofsd doesn't exist). Single tag "nix-store"
    # works as both the virtiofs `tag=` and the 9p `mount_tag=`.
    if mount -t virtiofs nix-store /nix 2>/dev/null; then
      echo "Mounted host /nix at /nix (virtiofs)"
    elif mount -t 9p -o trans=virtio,version=9p2000.L,ro nix-store /nix 2>/dev/null; then
      echo "Mounted host /nix at /nix (9p)"
    else
      echo "WARN: failed to mount /nix from host"
    fi

    # Networking — DHCP via busybox udhcpc. Both qemu user-mode and
    # vfkit's vmnet provide a DHCP server, but the address ranges
    # differ (qemu: 10.0.2.x, vfkit: vmnet-assigned 192.168.x.x), so
    # static config doesn't work portably.
    ip link set lo up
    cat > /tmp/udhcpc.script <<'UDHCPC_EOF'
    #!/bin/sh
    case "$1" in
      deconfig) ip addr flush dev "$interface"; ip link set "$interface" up ;;
      bound|renew)
        ip addr flush dev "$interface"
        # Convert dotted subnet → prefix length (covers the /16 and /24
        # cases qemu and vmnet both hand out; widen if you ever need it).
        case "$subnet" in
          255.255.0.0)   prefix=16 ;;
          255.255.255.0) prefix=24 ;;
          *)             prefix=24 ;;
        esac
        ip addr add "$ip/$prefix" dev "$interface"
        [ -n "$router" ] && ip route replace default via "''${router%% *}"
        : > /etc/resolv.conf
        for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done
        ;;
    esac
    UDHCPC_EOF
    chmod +x /tmp/udhcpc.script
    if udhcpc -i eth0 -n -q -s /tmp/udhcpc.script 2>/dev/null; then
      GW=$(ip route show default | awk '/default/{print $3; exit}')
      MY_IP=$(ip -o -4 addr show eth0 | awk '{print $4; exit}')
      echo "Network configured: eth0 = $MY_IP, gateway = $GW"
    else
      echo "WARN: DHCP failed on eth0"
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
    ln -sf ${nano}/bin/nano /bin/nano
    ln -sf ${kubernetes-helm}/bin/helm /bin/helm

    # kubectl's default search includes ~/.kube/config; symlink the file
    # k3s writes there once it's available, so KUBECONFIG doesn't need
    # to be in the env (SSH sessions inherit nothing → would otherwise
    # need to re-export there too).
    mkdir -p /root/.kube
    ln -sf /etc/rancher/k3s/k3s.yaml /root/.kube/config

    # Bridge nix-daemon socket from host: guest UNIX socket ⇆ host TCP.
    # Path is referenced from /etc/nix/nix.conf above; lives on /run
    # (tmpfs) since /nix is the read-only host mount. The host IP is
    # whatever the DHCP server advertised as gateway — qemu user-mode
    # uses 10.0.2.2, vfkit's vmnet uses the vmnet-assigned NAT gateway.
    socat UNIX-LISTEN:/run/nix-daemon.sock,fork,unlink-early \
          "TCP:''${GW:-10.0.2.2}:${daemonProxyPort}" 2>/dev/null &

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

    # Capture all post-boot kernel messages to /var/log/kernel.log so the
    # console stays clean for interactive shells and TUI apps. /dev/kmsg
    # is the in-kernel stream of every printk; `cat` follows it
    # indefinitely. (busybox's dmesg lacks -w/--follow, so we read the
    # underlying device directly.) Pre-boot messages already went to the
    # console as usual.
    mkdir -p /var/log
    (cat /dev/kmsg > /var/log/kernel.log 2>&1) &

    # Drop the runtime console-loglevel to KERN_ALERT-and-worse only, so
    # bridge/veth/iptables printks don't paint over k9s/vi/htop output on
    # the serial console. View captured logs with `tail -f /var/log/kernel.log`
    # or `dmesg` (ring buffer); raise verbosity again with `dmesg -n 7`.
    dmesg -n 1 2>/dev/null || true

    # `setsid -c` creates a new session AND makes our stdin (the kernel
    # console) the new session's controlling TTY. Without this, the shell
    # has no controlling terminal: open("/dev/tty") fails with ENXIO,
    # job control (^Z, fg, bg) is silently disabled, and TUI apps like
    # k9s/vi/htop can't take over the screen.
    exec setsid -c /bin/sh
    INIT_EOF
    chmod +x "$ROOT/init"
    chmod +x "$ROOT/init"
    (cd "$ROOT" && find . | cpio -H newc -o 2>/dev/null | gzip -9 > $out)
  '';

  # Common pre-launch logic for any runner: VM resource sizing,
  # persistent disk-image setup, and nix-daemon socket bridging.
  # Emitted as a shell snippet that runners source at the top of their text.
  preLaunch = ''
    # Default to half the host's CPUs and RAM, detected by a tiny C helper
    # that's portable across macOS / Linux / FreeBSD. Override with
    # VM_CPUS / VM_MEM_MB env vars.
    HOST_CPUS=$(${hostInfo}/bin/host-info cpus)
    HOST_MEM_MB=$(${hostInfo}/bin/host-info memory-mb)
    VM_CPUS="''${VM_CPUS:-$((HOST_CPUS / 2))}"
    VM_MEM_MB="''${VM_MEM_MB:-$((HOST_MEM_MB / 2))}"
    [ "$VM_CPUS"   -lt 2    ] && VM_CPUS=2
    [ "$VM_MEM_MB" -lt 4096 ] && VM_MEM_MB=4096

    # Persistent raw disk image (sparse, 100G). vfkit can't read qcow2,
    # so raw is the only format that works across both runners. truncate
    # creates a sparse file: the on-disk allocation grows only as the
    # guest writes blocks.
    VM_STATE_DIR="''${XDG_DATA_HOME:-$HOME/.local/share}/darwin-vm"
    VM_DISK="''${VM_DISK:-$VM_STATE_DIR/disk.img}"
    VM_DISK_SIZE="''${VM_DISK_SIZE:-100G}"
    mkdir -p "$(dirname "$VM_DISK")"
    if [ ! -f "$VM_DISK" ]; then
      truncate -s "$VM_DISK_SIZE" "$VM_DISK"
      echo "Created sparse disk image: $VM_DISK ($VM_DISK_SIZE)"
    fi

    # Bridge host nix-daemon socket onto a TCP port the guest can reach
    # via the runner's user-mode networking (host appears as 10.0.2.2 to
    # qemu user-mode; vfkit's NAT differs — see below).
    DAEMON_SOCK="''${NIX_DAEMON_SOCKET:-/nix/var/nix/daemon-socket/socket}"
    if [ -S "$DAEMON_SOCK" ]; then
      socat TCP-LISTEN:${daemonProxyPort},bind=0.0.0.0,reuseaddr,fork \
            "UNIX-CONNECT:$DAEMON_SOCK" 2>/dev/null &
      SOCAT_PID=$!
      trap 'kill $SOCAT_PID 2>/dev/null || true' EXIT
    else
      echo "warning: no nix-daemon socket at $DAEMON_SOCK; guest daemon proxy disabled" >&2
    fi

    echo "VM: $VM_CPUS CPUs, ''${VM_MEM_MB} MB RAM, disk $VM_DISK"
  '';

  # qemu runner — works on every supported host. Uses 9p for the /nix
  # share (virtiofsd is Linux-only; 9p works under qemu everywhere).
  run = pkgs.writeShellApplication {
    name = "run-kernel";
    runtimeInputs = [ pkgs.qemu pkgs.socat ];
    text = preLaunch + ''
      echo "Runner: qemu (share transport: 9p)"

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
        -drive file="$VM_DISK",format=raw,if=virtio,cache=writeback,discard=unmap \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${sshHostPort}-:22 \
        -device virtio-net-pci,netdev=net0 \
        -append "${kernelCmdline}" \
        "$@"
    '';
  };

  # vfkit runner — Apple Virtualization Framework, darwin only. Uses
  # virtiofs for the /nix share (vfkit's only supported share type).
  # Networking is NAT-only with auto-assigned IP: there's no qemu-style
  # hostfwd, so SSH after boot is `ssh root@<guest-ip>` rather than
  # `ssh -p 2222 root@127.0.0.1`. The guest IP is announced on stdout
  # by vfkit's DHCP lease.
  run-vfkit = pkgs.writeShellApplication {
    name = "run-kernel-vfkit";
    runtimeInputs = [ pkgs.vfkit pkgs.socat ];
    text = preLaunch + ''
      echo "Runner: vfkit (share transport: virtiofs)"

      # Forward ^C (and ^Z, ^\) as bytes to the guest tty instead of
      # letting the host tty translate them into SIGINT for vfkit
      # itself (which would kill the VM). qemu's -nographic mux handles
      # this internally; vfkit doesn't, so we do it from the runner.
      # Restored on EXIT so the host shell isn't left in raw mode.
      saved_stty=$(stty -g 2>/dev/null || true)
      [ -n "$saved_stty" ] && trap 'stty "$saved_stty" 2>/dev/null || true; kill ''${SOCAT_PID:-0} 2>/dev/null || true' EXIT
      stty -isig -icanon -echo 2>/dev/null || true

      # vfkit doesn't emulate qemu's PL011/8250 UARTs — its console is
      # virtio-console (hvc0). CONFIG_VIRTIO_CONSOLE=y in the kernel
      # provides the device; the cmdline tells kernel to log there.
      vfkit \
        --cpus "$VM_CPUS" \
        --memory "$VM_MEM_MB" \
        --bootloader "linux,kernel=${kernel}/${arch.imageName},initrd=${initramfs},cmdline=\"console=hvc0 panic=-1\"" \
        --device virtio-rng \
        --device "virtio-fs,sharedDir=/nix,mountTag=nix-store" \
        --device "virtio-blk,path=$VM_DISK" \
        --device "virtio-net,nat,mac=72:20:43:d4:38:62" \
        --device virtio-serial,stdio \
        "$@"
    '';
  };
in
{ inherit kernel initramfs run run-vfkit; }
