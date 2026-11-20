# The kernel this box builds for itself. The stock series is a general-purpose
# image: it carries every GPU, every radio vendor and every debug tax, and on
# this hardware none of that can ever bind. This file trims it to what the
# machine actually has and states the tuning that matters for a 24/7 headless
# server, in the same shape as hosts/asus/system.nix.
#
# The kernel comes from the rev-pinned `nixpkgs-fast-release` input, not the
# floating stable channel: CI builds this derivation and the box substitutes it
# (.github/workflows/compile-kernel.yml), and only a rev-pinned input makes both
# evaluate to the same store path. The series stays the LTS one on purpose; what
# moves is the patch level, with the pin in flake.nix.
#
# Everything set here is either something nixpkgs would otherwise get wrong for
# this machine, or something whose silent loss would cost a build. CI greps the
# generated .config against .github/kernel-asserts/homelab.txt before it spends
# two hours, so `ignoreConfigErrors` cannot hide a rename.
{
  lib,
  pkgs-fast-release,
  ...
}:
{
  boot.kernelPackages = pkgs-fast-release.linuxPackagesFor (
    pkgs-fast-release.linux_6_18.override {
      # Silences both of generate-config.pl's failure channels: a symbol that no
      # longer exists, and a value a `select` or an unmet dependency rewrote.
      # Neither prints anything, which is why the assertion list exists.
      ignoreConfigErrors = true;
    }
  );

  boot.kernelPatches = [
    {
      name = "bdver2-march";
      patch = ./bdver2-march.patch;
    }
    {
      # A patch entry with no patch: build.nix filters null out of the apply
      # list, and this is where the config changes live so they read as their
      # own thing next to the -march patch.
      name = "homelab-trim";
      patch = null;
      structuredExtraConfig = with lib.kernel; {
        # --- build determinism ------------------------------------------
        # Do NOT use X86_NATIVE_CPU. It sniffs the *build* host's CPU at
        # compile time, so a kernel built on a GitHub runner would differ
        # from one built here while sharing the store path. The -march
        # tuning lives in bdver2-march.patch instead, which compiles
        # identically anywhere and only ever runs on this APU.
        X86_NATIVE_CPU = lib.mkForce no;

        # --- CPU: topology, tick, preemption ----------------------------
        # A10-4600M: 2 Piledriver modules x 2 threads. Linux models a module's
        # pair as SMT siblings and the two modules as one MC domain, so both
        # knobs describe this part exactly. nixpkgs pins NR_CPUS at 384
        # (common-config.nix, `freeform "384"`); 8 keeps headroom over the 4
        # threads and shrinks every per-CPU array in the image.
        NR_CPUS = lib.mkForce (freeform "8");
        SCHED_SMT = yes;
        SCHED_MC = yes;

        # NO_HZ (which nixpkgs sets) means an idle CPU carries no tick, so HZ
        # prices only busy time: 1000 interrupts/s/core is a tax this box pays
        # while it builds, and 250 Hz is the server norm. HZ_1000 comes from the
        # base defconfig, so it is named here to stop the choice drifting back.
        HZ_250 = yes;
        HZ_1000 = no;

        # PREEMPT_LAZY is what nixpkgs picks for >= 6.18, and it is what this
        # config keeps: it preempts at explicit points, which keeps ssh usable
        # while two cores compile. Switching between none, voluntary, lazy and
        # full at runtime moved nothing beyond the bench's own spread (25% on
        # fork/exec), so this is a choice to keep, not a knob to tune. Set here
        # rather than inherited, so a nixpkgs that changes its default does not
        # quietly change the model; PREEMPT is in the same Kconfig choice group
        # and must never be set at the same time.
        PREEMPT_LAZY = lib.mkForce yes;
        PREEMPT_DYNAMIC = yes;

        # --- cpufreq / cpuidle ------------------------------------------
        # acpi-cpufreq is the only driver that can scale this APU (amd_pstate
        # needs CPPC, fam17h+; powernow-k8 predates fam15h). Built in rather
        # than modular because the governor is chosen at boot.
        CPU_FREQ = yes;
        X86_ACPI_CPUFREQ = yes;
        X86_ACPI_CPUFREQ_CPB = yes;
        CPU_FREQ_DEFAULT_GOV_SCHEDUTIL = lib.mkForce yes;
        CPU_FREQ_GOV_SCHEDUTIL = lib.mkForce yes;
        CPU_FREQ_STAT = lib.mkForce yes;

        # intel_pstate and amd_pstate cannot be trimmed away: CPU_SUP_INTEL and
        # CPU_SUP_AMD `select` them, and a select beats any config value. Neither
        # can bind here (intel_pstate exits on a non-Intel vendor id, amd_pstate
        # needs CPPC, which is fam17h+), so they cost image bytes and nothing
        # else. Turning CPU_SUP_INTEL off would mean not supporting Intel CPUs,
        # which is not worth it on a box whose kernel CI might build elsewhere.

        # The firmware's _CST table offers C1 and C2 only, so acpi_idle is the
        # only driver that can register anything, and intel_idle is Intel-only
        # code that never probes here. TEO decides from the next timer event
        # instead of menu's interactivity heuristics; menu outranks it, so both
        # lines together are the change. (The stock config does not build TEO
        # at all, which is why this is a real difference, not a no-op.)
        CPU_IDLE = yes;
        ACPI_PROCESSOR_IDLE = yes;
        INTEL_IDLE = lib.mkForce no;
        CPU_IDLE_GOV_TEO = yes;
        CPU_IDLE_GOV_MENU = no;
        CPU_IDLE_GOV_HALTPOLL = no;

        # Fed by ondemand only, which this box never runs, and its own Kconfig
        # says fam16h and above. Kept as a module (40 kB) so a later experiment
        # with ondemand is not silently worse; never loaded.
        X86_AMD_FREQ_SENSITIVITY = module;

        # --- security: these are choices, not leftovers -------------------
        # Left at nixpkgs' values on purpose and named so a later trim has to
        # argue with them: KASLR, the MITIGATION_* set, HARDENED_USERCOPY,
        # FORTIFY_SOURCE, STACKPROTECTOR_STRONG, STRICT_KERNEL_RWX,
        # STRICT_MODULE_RWX, VMAP_STACK, INIT_ON_ALLOC, SLAB_FREELIST_HARDENED,
        # SHUFFLE_PAGE_ALLOCATOR, BUG_ON_DATA_CORRUPTION, and the LSM list
        # nixpkgs' CONFIG_LSM carries (landlock,lockdown,yama,... which is why
        # the cmdline says lsm=landlock,yama,bpf). This part takes the Spectre
        # v1/v2 and retbleed mitigations; Meltdown, MDS and L1TF report not
        # affected. A "minimal" config drops all of it, and the assertion file
        # in CI checks the six mitigations and these hardening lines are still
        # on. The cost of keeping them was measured: mitigations=off measured
        # 1.5% on a flake evaluation, 9% on a bare stat loop and nothing on xz,
        # which is not worth a userspace process being able to read kernel
        # memory.
        RANDOMIZE_BASE = lib.mkForce yes;
        HARDENED_USERCOPY = lib.mkForce yes;
        INIT_ON_ALLOC_DEFAULT_ON = lib.mkForce yes;
        # init_on_free is the expensive half (a free becomes a write) and only
        # covers reads after free; off, as in the baseline.
        INIT_ON_FREE_DEFAULT_ON = no;
        SLAB_FREELIST_HARDENED = lib.mkForce yes;
        SHUFFLE_PAGE_ALLOCATOR = lib.mkForce yes;
        BUG_ON_DATA_CORRUPTION = lib.mkForce yes;
        # DEBUG_LIST walks every list operation for the life of the machine.
        # LIST_HARDENED is the cheap half and BUG_ON_DATA_CORRUPTION selects
        # it anyway; nixpkgs turns the expensive half on.
        DEBUG_LIST = lib.mkForce no;
        # systemd's cgroup BPF, nftables and the LSM stack all reach BPF. With
        # the JIT always on there is no interpreter left to spray against.
        BPF_JIT_ALWAYS_ON = lib.mkForce yes;
        # MODULE_SIG stays off as nixpkgs sets it: the build key is random, so
        # enabling it makes the store path unreproducible and every CI-built
        # kernel a cache miss, and without MODULE_SIG_FORCE it enforces
        # nothing. Every .ko in /run/current-system came from a signed store
        # path of this same kernel; that is the guarantee NixOS actually gives.

        # Fam15h predates CET: ENDBR decodes as a NOP, so IBT is padding at
        # every indirect target plus an objtool pass for no enforcement, and
        # userspace can never claim a shadow stack.
        X86_KERNEL_IBT = no;
        X86_USER_SHADOW_STACK = lib.mkForce no;

        # --- size and memory, no runtime cost ---------------------------
        KFENCE = lib.mkForce no;
        KALLSYMS_ALL = no;
        MEMORY_HOTPLUG = lib.mkForce no;
        DAMON = lib.mkForce no;
        # zram is the swap device here; zswap is an option default nixpkgs
        # turns on and nothing on this box configures.
        ZSWAP = lib.mkForce no;
        HIBERNATION = no;

        # MODULE_DECOMPRESS is off, so kmod unpacks every modprobe in
        # userspace. zstd does that several times faster than xz on this APU at
        # a slightly worse ratio, which is boot and hotplug time on a 5400 rpm
        # disk.
        MODULE_COMPRESS_XZ = lib.mkForce no;
        MODULE_COMPRESS_ZSTD = yes;

        # --- hardware this machine does not have ------------------------
        # Audit behind this group: lspci shows the Trinity IGP (1002:9900), the
        # runtime-suspended Thames dGPU (1002:6840), RTL8168 ethernet, AHCI, 2x
        # xHCI + EHCI, HD audio (IDT codec + HDMI), the RTS5229 reader, HP EC/
        # WMI, the lis3lv02d accelerometer, sp5100_tco and edac. No tuner, no
        # capture card, no camera, no radio, no optical drive, no serial port.
        # These cost build time, store (this box boots from a HDD) and early
        # boot probes, never runtime.

        # Bare metal: no guest support, so paravirt spinlocks, PV clock and the
        # virtio/xen/hv code all go. KVM stays: this is a homelab, and a VM is
        # a plausible thing to ask of it later.
        HYPERVISOR_GUEST = lib.mkForce no;
        VIRTIO_MENU = lib.mkForce no;

        # radeon is what drives the console and what runtime-suspends the dGPU
        # to D3cold; removing it would leave that chip powered. Everything else
        # here is a GPU this box does not have.
        DRM_RADEON = module;
        DRM_AMDGPU = no;
        DRM_I915 = no;
        DRM_NOUVEAU = no;
        DRM_XE = no;
        DRM_VMWGFX = no;
        DRM_QXL = no;
        DRM_BOCHS = no;
        DRM_CIRRUS_QEMU = no;
        DRM_VIRTIO_GPU = no;
        DRM_VKMS = no;
        DRM_GUD = no;
        DRM_AST = no;
        DRM_MGAG200 = no;
        DRM_GMA500 = lib.mkForce no;
        DRM_HISI_HIBMC = no;
        DRM_UDL = no;
        DRM_GM12U320 = no;

        # No video capture, tuner, radio or SDR. Turning the parent off is what
        # makes the subtree disappear: its type switches have no prompt while
        # the filter is off.
        MEDIA_SUPPORT = no;

        # The IDT codec and HDMI audio exist but nothing on this box plays
        # sound; snd + snd_hda_intel stay so the hardware is not "missing",
        # while the SoC/SoundWire stack, OSS emulation and the sequencer go.
        SND = module;
        SND_SOC = no;
        SND_USB = no;
        SND_SEQUENCER = no;
        SND_OSSEMUL = lib.mkForce no;
        SND_DRIVERS = no;

        # No /sys/bus/iio device exists: the accelerometer is lis3lv02d under
        # drivers/misc. Staging holds nothing this box uses either.
        IIO = no;
        STAGING = lib.mkForce no;

        # No modem, CAN bus, ISDN, WAN, NFC or 802.15.4 controller.
        CAN = no;
        ISDN = no;
        WAN = lib.mkForce no;
        HAMRADIO = lib.mkForce no;
        DVB_CORE = no;
        NFC = no;
        WWAN = no;
        IEEE802154 = no;

        # Filesystems: ext4 root, vfat ESP, and the removable-media ones the SD
        # reader or a USB stick can turn up with. The network and cluster
        # filesystems cannot be reached from here (no NFS/CIFS/9P client), and
        # the copy-on-write ones are not used.
        EXT4_FS = yes;
        VFAT_FS = yes;
        MSDOS_FS = yes;
        EXFAT_FS = module;
        NTFS3_FS = module;
        FUSE_FS = module;
        OVERLAY_FS = module;
        XFS_FS = no;
        BTRFS_FS = no;
        F2FS_FS = lib.mkForce no;
        JFS_FS = no;
        GFS2_FS = no;
        OCFS2_FS = no;
        NFS_FS = lib.mkForce no;
        NFSD = no;
        CIFS = no;
        "9P_FS" = no;
        SQUASHFS = no;
        ISO9660_FS = lib.mkForce no;
        UDF_FS = lib.mkForce no;
        INFINIBAND = lib.mkForce no;

        # Ethernet: the only NIC is the RTL8168, so every vendor menu that
        # carries real drivers is dead weight. These are the *Ethernet* vendor
        # filters; the wireless ones (WLAN_VENDOR_*) are deliberately untouched
        # below. NET_VENDOR_REALTEK and r8169 stay as they are.
        NET_VENDOR_3COM = no;
        NET_VENDOR_AMD = no;
        NET_VENDOR_AQUANTIA = no;
        NET_VENDOR_ATHEROS = no;
        NET_VENDOR_BROADCOM = no;
        NET_VENDOR_CAVIUM = no;
        NET_VENDOR_CHELSIO = no;
        NET_VENDOR_EMULEX = no;
        NET_VENDOR_GOOGLE = no;
        NET_VENDOR_HUAWEI = no;
        NET_VENDOR_INTEL = no;
        NET_VENDOR_MARVELL = no;
        NET_VENDOR_MELLANOX = no;
        NET_VENDOR_MICROSOFT = no;
        NET_VENDOR_MYRI = no;
        NET_VENDOR_NETRONOME = no;
        NET_VENDOR_NVIDIA = no;
        NET_VENDOR_PENSANDO = no;
        NET_VENDOR_QLOGIC = no;
        NET_VENDOR_SOLARFLARE = no;
        NET_VENDOR_STMICRO = no;
        NET_VENDOR_SUN = no;
        NET_VENDOR_SYNOPSIS = no;
        NET_VENDOR_TI = no;
        NET_VENDOR_WANGXUN = no;
        NET_VENDOR_XILINX = no;

        # --- wireless and Bluetooth: kept, as modules --------------------
        # There is no radio in the machine today and the plan is to add one
        # (USB dongle and/or mini-PCIe card), so the whole stack stays. Every
        # driver is =m, so nothing parses a frame until the hardware exists;
        # rfkill is the runtime lever, not a rebuild. The 6.18 series has no
        # r8188eu/r8712u any more (rtl8xxxu covers those dongles).
        CFG80211 = module;
        # CFG80211_WEXT is left at nixpkgs' value on purpose: it is a deprecated
        # ioctl surface nothing here speaks (iwd and NetworkManager use nl80211),
        # so it is not worth forcing on. If a dongle ever needs it, nixpkgs
        # already has it on for the old drivers.
        MAC80211 = module;
        RFKILL = module;
        # The vendor sub-toggles are forced on rather than left to nixpkgs
        # because the whole point is "plug in any dongle and it works": a
        # dongle's IDs sit behind BT_HCIBTUSB_MTK/RTL/BCM and
        # RTL8XXXU_UNTESTED, and a module that is built but never loaded costs
        # store space only.
        BT = module;
        BT_BREDR = yes;
        BT_LE = yes;
        BT_HCIBTUSB = module;
        BT_HCIBTUSB_AUTOSUSPEND = lib.mkForce yes;
        BT_HCIBTUSB_BCM = yes;
        BT_HCIBTUSB_MTK = lib.mkForce yes;
        BT_HCIBTUSB_RTL = yes;
        BT_HCIBTSDIO = module;
        BT_HCIUART = lib.mkForce module;
        BT_HCIUART_SERDEV = lib.mkForce yes;
        BT_HCIUART_H4 = lib.mkForce yes;
        BT_HCIUART_BCSP = lib.mkForce yes;
        BT_HCIUART_LL = lib.mkForce yes;
        BT_HCIUART_BCM = lib.mkForce yes;
        BT_HCIUART_QCA = lib.mkForce yes;
        BT_ATH3K = module;
        BT_RFCOMM = module;
        BT_HIDP = module;
        # Only the debug interfaces go, never the protocol code.
        BT_DEBUGFS = no;
        ATH9K = module;
        ATH9K_HTC = module;
        ATH10K = module;
        RTL8XXXU = module;
        RTL8XXXU_UNTESTED = lib.mkForce yes;
        RTW88 = lib.mkForce module;
        RTW88_USB = module;
        RTW88_PCI = module;
        RTW89 = module;
        MT7601U = module;
        MT76_USB = module;
        BRCMFMAC = module;
        BRCMFMAC_USB = lib.mkForce yes;
        BRCMFMAC_PCIE = lib.mkForce yes;
        IWLWIFI = module;
        IWLMVM = module;
        IWLMLD = module;

        # --- what must positively stay -----------------------------------
        # Pinned so a later trim cannot silently take the driver this machine
        # boots from, its sensors or its watchdog.
        R8169 = module;
        # The root disk's driver stays a module under ATA (Kconfig cannot make a
        # y symbol depend on an m parent), and the initrd loads it; nixpkgs
        # states the same, this line only stops a later trim from taking it.
        SATA_AHCI = module;
        USB_XHCI_HCD = module;
        USB_EHCI_HCD = module;
        SND_HDA_INTEL = module;
        HP_WMI = module;
        HP_BIOSCFG = module;
        HP_ACCEL = module;
        SENSORS_LIS3LV02D = module;
        SENSORS_LIS3_I2C = module;
        SENSORS_K10TEMP = module;
        SP5100_TCO = module;
        EDAC_AMD64 = module;
        X86_MCE_AMD = yes;
        MISC_RTSX_PCI = module;
        MMC_REALTEK_PCI = module;
        I2C_PIIX4 = module;
      };
    }
  ];
}
