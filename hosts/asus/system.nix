{
  config,
  hostConfig,
  pkgs,
  pkgs-fast-release,
  stableKernel,
  lib,
  modulesPath,
  ...
}:
let
  disk = import ./disk.nix;

  # setup_var.efi version pinned from upstream releases.
  # Bump version + hash together. Prefetch new hash with:
  # nix-prefetch-url --type sha256 https://github.com/datasone/setup_var.efi/releases/download/<version>/setup_var.efi
  setupVarVersion = "0.3.1";
  setupVarEfi = pkgs.fetchurl {
    url = "https://github.com/datasone/setup_var.efi/releases/download/${setupVarVersion}/setup_var.efi";
    hash = "sha256-y+V3e2EnbT81BqKLNIRTJukvbBcb/1kXfjkS/iD0mEA=";
  };
  # UX581GV BIOS v309 offsets in Setup(0x1). Single source for the entries below.
  biosUnlockVars = {
    varstore = "Setup(0x1)";
    overclockingLock = "0x78C";
    cfgLock = "0x6F0";
  };
in
{
  networking.useDHCP = lib.mkDefault true;

  # This machine's own binary cache: CI builds the tuned kernel and publishes
  # it here. The key name must match the NIX_SECRET_KEY signer exactly or
  # lookups miss silently and the kernel builds here instead. Other hosts do
  # not trust it, which is why it is appended here and not in base/.
  nix.settings.substituters = lib.mkAfter [ "https://duskyelf.github.io/NixBTW" ];
  nix.settings.trusted-public-keys = lib.mkAfter [
    "i9-kernel-cache:4R0pqOZkrRj4utTbF4zP05Y58QSgShLqQ77KUPzFjwk="
  ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    # This is the logical size of the swap, not the RAM it costs: only pages
    # that actually get swapped out are held, compressed. The worktree tmpfs
    # below spills into it, and with no disk swap behind it the real ceiling on
    # total usage is the OOM killer.
    memoryPercent = 75;
  };
  boot.kernel.sysctl = {
    "vm.swappiness" = 180;
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
    "vm.page-cluster" = 0;
    # The kernel built here defaults to BBR, and BBR paces through fq. Without
    # it the link still works, but the pacing that keeps the wifi queue from
    # bursting is gone.
    "net.core.default_qdisc" = "fq";
  };

  # Build sandboxes unpack under TMPDIR and a chromium or LLVM derivation needs
  # several GB there, so /tmp keeps its full size. Pinned rather than left at
  # the 50% default: the agent budgets in this file assume 16 GB, and a RAM
  # change should not move that silently.
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "16G";
  # Names, not UUIDs: a reformat changes every UUID, and disko writes these
  # labels (see hosts/asus/disko.nix). The running disk already carries them,
  # which is why /etc/fstab resolves these on this boot.
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/${disk.labels.root}";
      fsType = "f2fs";
      options = [
        "noatime"
        "compress_algorithm=zstd:3"
        "compress_mode=fs"
      ];
    };
    "/home" = {
      device = "/dev/disk/by-label/${disk.labels.home}";
      fsType = "f2fs";
      options = [
        "noatime"
        "compress_algorithm=zstd:3"
        "compress_mode=fs"
      ];
    };
    "/boot" = {
      device = "/dev/disk/by-label/${disk.labels.boot}";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };

    # Parallel agent worktrees and every build artifact under them. tmpfs on
    # purpose: the tree is source and object code, so under pressure those
    # pages swap into zram0 compressed instead of sitting unevictable in RAM,
    # and a full mount gives ENOSPC instead of corrupting a journal-less
    # filesystem. Build output has to be executable, so there is no noexec.
    # Nothing is here until the t3code worktree root is pointed at it, and
    # nothing prunes it: agents delete their own worktrees when they are done.
    "/mnt/agent-worktrees" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [
        "size=24G"
        "mode=1777"
        "noatime"
        "nodev"
        "nosuid"
      ];
    };
  };

  # Everything the language caches write to. Created at boot so the first
  # sccache or npm start finds it, and so they degrade to the SSD if the mount
  # is ever missing instead of failing on a root-owned /mnt.
  systemd.tmpfiles.rules = [
    "d /mnt/agent-worktrees/caches 1777 root root -"
  ];

  # systemd-boot entries for unlocking undervolting (UX581GV BIOS v309).
  # The .efi is pinned above and installed to the ESP, no manual copy needed.
  boot.loader.systemd-boot.extraFiles."EFI/tools/setup_var.efi" = setupVarEfi;

  boot.loader.systemd-boot.extraEntries = {
    "bios-read-locks.conf" = ''
      title   BIOS Unlock: Read Current Lock Status
      efi     /EFI/tools/setup_var.efi
      options ${biosUnlockVars.varstore}:${biosUnlockVars.overclockingLock} ${biosUnlockVars.varstore}:${biosUnlockVars.cfgLock}
    '';

    "bios-final-unlock.conf" = ''
      title   BIOS Unlock: DISABLE Overclocking & CFG Locks (0x00)
      efi     /EFI/tools/setup_var.efi
      options ${biosUnlockVars.varstore}:${biosUnlockVars.overclockingLock}=0x00 ${biosUnlockVars.varstore}:${biosUnlockVars.cfgLock}=0x00
    '';

    "bios-reset-lock.conf" = ''
      title   BIOS Lock: ENABLE Overclocking & CFG Locks (0x01 - Stock)
      efi     /EFI/tools/setup_var.efi
      options ${biosUnlockVars.varstore}:${biosUnlockVars.overclockingLock}=0x01 ${biosUnlockVars.varstore}:${biosUnlockVars.cfgLock}=0x01
    '';
  };

  services.undervolt = {
    enable = true;

    coreOffset = -134;
    gpuOffset = -130;

    p1 = {
      window = 28;
      limit = 62;
    };
    p2 = {
      window = 10;
      limit = 75;
    };
  };

  hardware = {
    cpu.intel = {
      updateMicrocode = config.hardware.enableRedistributableFirmware;
    };

    graphics = {
      enable = true;
      extraPackages = with pkgs; [
        intel-media-driver
        libvdpau-va-gl
        vpl-gpu-rt
        #intel-media-sdk # for older iGPUs
      ];
    };

    # The dGPU is optional. powersave modes in apps/power/power.sh remove the PCI
    # device and unload the modules; performance re-scans the bus and reloads
    # them. A missing nvidia module is a power mode, not a broken config.
    nvidia = {
      open = true;

      # The driver tracks the kernel: every kernel jump needs a driver release
      # that knows it. 26.05's 595.x predates Linux 7.2 (7.2 removed
      # include/linux/platform/, the header nv-ipc-soc.c probes for, and NVIDIA
      # added 7.2 support in 610.57.04). 615.71.09 then broke on 7.3.1: 7.3
      # changed dmem_cgroup_register_region to take a struct dmem_cgroup_init
      # pointer, while os-interface.c still called it as (size, name).
      # So the driver is 615.78.08, built against our kernel via mkDriver.
      # Hashes copied from linuxPackages.nvidiaPackages.new_feature in
      # nixos-unstable; bump by hand. Cost: this exact driver closure is not in
      # any binary cache, so the userspace build happens locally once, then
      # stays in the store. The kernel module is the half that moves with every
      # kernel, so CI builds and publishes that one together with the kernel
      # (.github/workflows/compile-kernel.yml).
      package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
        version = "615.78.08";
        sha256_64bit = "sha256-Pj9t3cLudnoIGFMAr3vjyyhuznZpjS3eNSRZl4LQf/4=";
        sha256_aarch64 = "sha256-UHYBE1AYHoGgMfD9AS/jX+S+N8eCDWUft6qolK9Eejc=";
        openSha256 = "sha256-HBINiOjL0ZJLIAJeNIBYHBnwgUXtNwPPtnFpAI1YwF4=";
        settingsSha256 = "sha256-inDRpG02sdDgHmlqgu/DsgK8OFdOt1fZIYyXdhlGC/c=";
        persistencedSha256 = "sha256-RzeR6Ldct6MUxjnXRyThdh5Y3jjMehTVg85MtwuWNX4=";
      };

      modesetting.enable = true;
      powerManagement.enable = true;
      powerManagement.finegrained = true;
      prime = {
        offload = {
          enable = true;
          enableOffloadCmd = true;
        };
        intelBusId = "PCI:0:2:0";
        nvidiaBusId = "PCI:1:0:0";
      };
    };
  };

  services.xserver.videoDrivers = [
    "modesetting"
    "nvidia"
  ];

  environment.systemPackages = with pkgs; [
    # iGPU tooling for this board. undervolt comes in with the service above.
    intel-gpu-tools
    cudatoolkit
    #cudaPackages.cudnn
    cudaPackages.cuda_cudart
  ];

  environment.sessionVariables = {
    CUDA_PATH = "${pkgs.cudatoolkit}";
    # The driver we actually built, not nvidiaPackages.stable: kernel module and
    # userspace libs must be the same version or CUDA refuses to load.
    LD_LIBRARY_PATH = "${config.hardware.nvidia.package}/lib";
    EXTRA_LDFLAGS = "-L/lib -L${config.hardware.nvidia.package}/lib";

    LIBVA_DRIVER_NAME = "iHD"; # for iGPU support from some applicaptions
  };

  boot = {
    kernelParams = [
      "mem_sleep_default=deep"
      # OLED backlight (2026-07): SOLVED, keep =3.
      # Intel HDR interface is the ONLY one that works on this panel (eDP 1.3;
      # VBT lies about PWM; VESA probe fails; PWM register path is a no-op).
      # Nits-based: max 528 = panel's 528-nit EDID rating. Auto mode gates Intel
      # HDR on EDID HDR metadata and behaved inconsistently; force keeps it explicit.
      # Panel-native quirks (not driver-fixable): slight luminance dip above ~440
      # nits (83%), green cast below ~428 nits (81%).
      "i915.enable_dpcd_backlight=3"
    ];
    initrd = {
      availableKernelModules = [
        "xhci_pci"
        "nvme"
        "usb_storage"
        "sd_mod"
      ];
      kernelModules = [ ];
    };
    kernelModules = [
      "kvm-intel"
      "msr"
    ];
    extraModulePackages = [ ];

    # The kernel drv comes from flake.nix (hosts/asus/stable-kernel.nix picks
    # the newest series with a stable patch release). This file only decides
    # how it is configured, so a new series never needs an edit here.
    kernelPackages = pkgs-fast-release.linuxPackagesFor (
      stableKernel.override {
        ignoreConfigErrors = true;

        # Start with an all-no config.  It is slightly easiler to pull together
        # enough options to get this running than to whittle down the defaults.
        # However, it is still a lot and you may miss some that are more important
        # than what you gain by starting from a clean slate.
        # defconfig = "ARCH=x86_64 allnoconfig";
      }
    );

    # Editing this config produces a kernel no cache holds. CI builds and
    # publishes it to the signed cache this machine trusts
    # (.github/workflows/compile-kernel.yml), so the next switch substitutes
    # instead of compiling here; a run takes roughly two hours. LTO is
    # unavailable, not disabled: the clang LTO knobs cannot be forced on a
    # GCC build.
    kernelPatches = [
      {
        name = "skylake-march";
        patch = ./skylake-march.patch;
        structuredExtraConfig = with lib.kernel; {
          # Do NOT use X86_NATIVE_CPU. It sniffs the *build* host's CPU at
          # compile time, so a kernel built on GitHub Actions (AMD runner)
          # would differ from one built on this laptop while sharing the
          # same store path. That silently poisons the binary cache and
          # forces local rebuilds. The -march=skylake tuning lives in
          # skylake-march.patch instead: kernel 7.2 dropped the 64-bit
          # family choice from Kconfig, so a fixed Makefile flag is the
          # only deterministic way to keep the tuning. It compiles
          # identically anywhere and only ever runs on this laptop
          # (i9-9980HK, Coffee Lake == skylake).
          X86_NATIVE_CPU = lib.mkForce no;
          X86_INTEL_PSTATE = yes;
          PREEMPT = lib.mkForce yes;
          # nixpkgs' common-config turns PREEMPT_LAZY on for kernels >= 6.18,
          # and Kconfig puts it in the same choice group as PREEMPT, so both
          # set makes generate-config.pl fail with "conflicting answers!".
          PREEMPT_LAZY = lib.mkForce no;
          PREEMPT_DYNAMIC = yes;
          CPU_IDLE = yes;
          INTEL_IDLE = yes;
          SCHED_SMT = yes;
          SCHED_MC = yes;
          SCHED_MC_PRIO = yes;

          # TEO decides the idle state from the next timer event; menu uses
          # interactivity heuristics and rates 20 against TEO's 19, so menu has
          # to go for TEO to be the one that runs. CPU_IDLE only selects menu
          # when TEO is off, so these two lines are the whole change.
          CPU_IDLE_GOV_TEO = yes;
          CPU_IDLE_GOV_MENU = no;

          # 512 CPUs of per-CPU state in the image: nixpkgs' common-config pins
          # NR_CPUS at 512 for x86. This part has 16 threads, so 32 keeps
          # headroom and stays inside the 2..512 range x86 allows.
          NR_CPUS = lib.mkForce (freeform "32");

          # KFENCE samples the allocator every 100 ms for the life of the
          # machine, which is a debug tax no shipping kernel pays.
          KFENCE = lib.mkForce no;

          # Soldered RAM, one socket, no memory hotplug and no damon consumer in
          # sysfs. Turning hotplug off takes ZONE_DEVICE and DEVICE_PRIVATE with
          # it; HMM_MIRROR is independent and stays. Nothing here does P2P DMA,
          # and nvidia-peermem has no RDMA device to attach to.
          MEMORY_HOTPLUG = lib.mkForce no;
          DAMON = lib.mkForce no;

          # MODULE_DECOMPRESS is off, so kmod unpacks every modprobe in
          # userspace; zstd does that several times faster than xz at a slightly
          # worse ratio. That is boot and hotplug time, paid on every load.
          MODULE_COMPRESS_XZ = lib.mkForce no;
          MODULE_COMPRESS_ZSTD = yes;

          # Data symbols exist for livepatching and data-symbol kprobes only;
          # bpftrace, perf and oops decoding still work without them.
          KALLSYMS_ALL = no;

          # DEBUG_LIST walks and validates every list operation, and its own
          # Kconfig points at LIST_HARDENED as the cheap half. LIST_HARDENED
          # stays: BUG_ON_DATA_CORRUPTION selects it.
          DEBUG_LIST = lib.mkForce no;

          # Coffee Lake predates CET, so ENDBR decodes as a NOP and userspace
          # can never claim a shadow stack. The cost is padding at every
          # indirect target plus an objtool pass, and the build no longer
          # selects the compiler's IBT capability probe.
          X86_KERNEL_IBT = no;
          X86_USER_SHADOW_STACK = lib.mkForce no;

          # systemd, bpftrace and nftables all reach for BPF; with the JIT
          # always on there is no interpreter to fall back to.
          BPF_JIT_ALWAYS_ON = lib.mkForce yes;

          # The only link is an AX200. BBR holds throughput on paths that lose
          # packets for reasons other than congestion, and DEFAULT_BBR needs the
          # algorithm built in rather than modular. fq is a built-in for the same
          # reason: the default_qdisc sysctl above runs before any module could
          # autoload.
          TCP_CONG_BBR = yes;
          DEFAULT_BBR = yes;
          DEFAULT_CUBIC = no;
          NET_SCH_FQ = yes;

          # Hardware this laptop does not have. These are modules nothing can
          # bind, so they cost build time, store size and cache space, never
          # runtime. The audit behind that claim: the bound drivers are i915,
          # nvidia, iwlwifi, snd_hda_intel, nvme, xhci, asus-nb-wmi, the I2C-HID
          # touchpads and one USB webcam. Hidden children disappear with their
          # parent and are not listed.

          # Media: no tuner, capture card, camera sensor, radio or SDR. The
          # MEDIA_*_SUPPORT type switches have no prompt while the filter is off
          # (EXPERT is on), and a promptless bool is forced to its default, so
          # the filter line is what makes the rest reachable. The webcam survives
          # because MEDIA_CAMERA_SUPPORT and MEDIA_USB_SUPPORT in nixpkgs'
          # config keep it reachable; CEC_CORE is sourced outside this subtree.
          MEDIA_SUPPORT_FILTER = yes;
          MEDIA_DIGITAL_TV_SUPPORT = lib.mkForce no;
          MEDIA_ANALOG_TV_SUPPORT = lib.mkForce no;
          MEDIA_PCI_SUPPORT = lib.mkForce no;
          MEDIA_RADIO_SUPPORT = no;
          MEDIA_SDR_SUPPORT = no;
          MEDIA_TEST_SUPPORT = no;
          MEDIA_PLATFORM_SUPPORT = no;

          # Audio is snd_hda_intel on ALC295 plus Intel HDMI. The SOF/AVS/
          # SoundWire stack loads and binds nothing here; snd/core, the HDA
          # codecs and snd_usb_audio are untouched.
          SND_SOC = no;

          # No /sys/bus/iio device exists on this machine.
          IIO = no;

          # Radios: WLAN_VENDOR_INTEL is the only one that has a device, there is
          # no WWAN modem and no NFC controller. cfg80211, mac80211, bluetooth
          # and iwlwifi stay.
          WLAN_VENDOR_ADMTEK = no;
          WLAN_VENDOR_ATH = no;
          WLAN_VENDOR_ATMEL = no;
          WLAN_VENDOR_BROADCOM = no;
          WLAN_VENDOR_INTERSIL = no;
          WLAN_VENDOR_MARVELL = no;
          WLAN_VENDOR_MEDIATEK = no;
          WLAN_VENDOR_MICROCHIP = no;
          WLAN_VENDOR_MORSEMICRO = no;
          WLAN_VENDOR_NXP = no;
          WLAN_VENDOR_PURELIFI = no;
          WLAN_VENDOR_RALINK = no;
          WLAN_VENDOR_REALTEK = no;
          WLAN_VENDOR_RSI = no;
          WLAN_VENDOR_SILABS = no;
          WLAN_VENDOR_ST = no;
          WLAN_VENDOR_TI = no;
          WLAN_VENDOR_ZYDAS = no;
          WLAN_VENDOR_QUANTENNA = no;
          WWAN = no;
          NFC = no;

          # GPUs that are not in this machine. i915, simpledrm, efifb, the DRM
          # helpers and the out-of-tree nvidia module stay. Dropping DRM_AMDGPU
          # also drops the promptless CEC_NOTIFIER it selects, so i915 loses its
          # HDMI-CEC hook; CEC_CORE and dp-aux-cec are unaffected, and nothing
          # on this laptop speaks CEC.
          DRM_AMDGPU = no;
          DRM_RADEON = no;
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
          DRM_VBOXVIDEO = no;
          DRM_GMA500 = lib.mkForce no;
          DRM_HISI_HIBMC = no;
          DRM_UDL = no;
          DRM_GM12U320 = no;
        };
      }
    ];
  };

  # Screenpad (secondary display, DP-2): the asus_screenpad backlight device
  # probes late in boot, so waiting for it in a unit beats racing it from niri.
  # bl_power 4 blanks the panel and 0 lights it (kernel 7.3.4; the driver
  # inverts the ACPI argument, so 4 is the off value, not 0). The unit drives
  # power.sh instead of writing sysfs itself, so the values live in one place.
  # It stays active after the first run and ignores unit changes, so a switch
  # does not restart it; an inactive unit (the first run or a failed run) still
  # starts once and blanks the panel. After the first run `systemctl start` is
  # a no-op and `systemctl restart` re-runs it. Guarded like every other
  # screenpad consumer.
  systemd.services.screenpad-off = lib.mkIf (hostConfig.hardware.screenpad != null) {
    description = "Turn off the screenpad panel after boot";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udevd.service" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in {1..150}; do [ -e /sys/class/backlight/${hostConfig.hardware.screenpad.device}/bl_power ] && exit 0; sleep 0.2; done; exit 1'";
      ExecStart = "${hostConfig.powerScriptPath} screenpad off";
    };
  };

  # auto-generated stuff
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];
}
