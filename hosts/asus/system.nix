{
  config,
  pkgs,
  pkgs-fast-release,
  lib,
  modulesPath,
  ...
}:
{
  hostOptions.hostName = "asus";
  nixpkgs.hostPlatform = "x86_64-linux";

  networking.useDHCP = lib.mkDefault true;

  users.users.duskyelf = {
    shell = pkgs.zsh;
    isNormalUser = true;
    description = "DuskyElf";
    extraGroups = [
      "networkmanager"
      "input"
      "wheel"
    ];
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };
  boot.kernel.sysctl = {
    "vm.swappiness" = 180;
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
    "vm.page-cluster" = 0;
  };

  boot.tmp.useTmpfs = true;
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-uuid/009aaadc-3753-481f-ba78-b8d29a9fe7f3";
      fsType = "btrfs";
      options = [
        "subvol=@"
        "noatime"
        "compress=zstd"
      ];
    };
    "/home" = {
      device = "/dev/disk/by-uuid/b8061842-55cd-4349-bc1b-c463433ef84c";
      fsType = "btrfs";
      options = [
        "noatime"
        "compress=zstd"
      ];
    };
    "/boot" = {
      device = "/dev/disk/by-uuid/5F09-CC9D";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
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

    nvidia = {
      open = true;
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
    cudatoolkit
    #cudaPackages.cudnn
    cudaPackages.cuda_cudart
  ];

  environment.sessionVariables = {
    CUDA_PATH = "${pkgs.cudatoolkit}";
    LD_LIBRARY_PATH = "${config.boot.kernelPackages.nvidiaPackages.stable}/lib";
    EXTRA_LDFLAGS = "-L/lib -L${config.boot.kernelPackages.nvidiaPackages.stable}/lib";

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

    #kernelPackages = pkgs.linuxPackages_latest;

    kernelPackages = pkgs-fast-release.linuxPackagesFor (
      pkgs-fast-release.linuxKernel.kernels.linux_7_1.override {
        ignoreConfigErrors = true;

        # Start with an all-no config.  It is slightly easiler to pull together
        # enough options to get this running than to whittle down the defaults.
        # However, it is still a lot and you may miss some that are more important
        # than what you gain by starting from a clean slate.
        # defconfig = "ARCH=x86_64 allnoconfig";
      }
    );

    kernelPatches = [
      {
        name = "march-native-llvm-lto";
        patch = null;
        structuredExtraConfig = with lib.kernel; {
          X86_NATIVE_CPU = yes;
          X86_INTEL_PSTATE = yes;
          PREEMPT = lib.mkForce yes;
          PREEMPT_LAZY = lib.mkForce no;
          PREEMPT_DYNAMIC = yes;
          CPU_IDLE = yes;
          INTEL_IDLE = yes;
          SCHED_SMT = yes;
          SCHED_MC = yes;
          SCHED_MC_PRIO = yes;
        };
      }
    ];
  };

  # Screenpad (secondary display, DP-2): the asus_screenpad backlight device probes
  # late in boot, so niri's spawn-time "power.sh screenpad off" races it and fails
  # silently, leaving the panel lit with no niri output. This service waits for the
  # device (max 30s) and powers it off. Note: screenpad bl_power is inverted —
  # 0 = off, 4 = on.
  systemd.services.screenpad-off = {
    description = "Turn off the screenpad panel after boot";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udevd.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in {1..150}; do [ -e /sys/class/backlight/asus_screenpad/bl_power ] && exit 0; sleep 0.2; done; exit 1'";
      ExecStart = "${pkgs.bash}/bin/bash -c 'echo 0 > /sys/class/backlight/asus_screenpad/bl_power'";
    };
  };

  # auto-generated stuff
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];
}
