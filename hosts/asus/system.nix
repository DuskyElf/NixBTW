{
  config,
  pkgs,
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
    cudaPackages.cudnn
    cudaPackages.cuda_cudart
  ];

  environment.sessionVariables = {
    CUDA_PATH = "${pkgs.cudatoolkit}";
    LD_LIBRARY_PATH = "${config.boot.kernelPackages.nvidiaPackages.stable}/lib";
    EXTRA_LDFLAGS = "-L/lib -L${config.boot.kernelPackages.nvidiaPackages.stable}/lib";

    LIBVA_DRIVER_NAME = "iHD"; # for iGPU support from some applicaptions
  };

  boot = {
    initrd = {
      availableKernelModules = [
        "xhci_pci"
        "nvme"
        "usb_storage"
        "sd_mod"
      ];
      kernelModules = [ ];
    };
    kernelModules = [ "kvm-intel" ];
    extraModulePackages = [ ];

    kernelPackages = pkgs.linuxPackagesFor (
      pkgs.linuxKernel.kernels.linux_zen.override {
        extraMakeFlags = [
          # Gcc flags.
          # "KCFLAGS+=-O3"
          # "KCFLAGS+=-march=native"
          # "KCFLAGS+=-mtune=native"

          # Clang/llvm flags
          "KCFLAGS+=-O3"
          "KCFLAGS+=-mtune=native"
          "KCFLAGS+=-march=native"
          "KCFLAGS+=-Wno-unused-command-line-argument"
          "KCFLAGS+=-fuse-ld=lld"
          "KCFLAGS+=-flto=full"
          "KCFLAGS+=-ffat-lto-objects"
          "KLDFLAGS+=--lto-O3"
          "KLDFLAGS+=--fat-lto-objects"
          "CC=${pkgs.llvmPackages.clang-unwrapped}/bin/clang"
          "AR=${pkgs.llvm}/bin/llvm-ar"
          "NM=${pkgs.llvm}/bin/llvm-nm"
          "LD=${pkgs.lld}/bin/ld.lld"
          "LLVM=1"
        ];

        stdenv = pkgs.stdenvAdapters.overrideInStdenv pkgs.llvmPackages.stdenv [
          pkgs.llvm
          pkgs.lld
        ];

        # Config generation failing usually corresponds to your config begin edited
        # in the output due to the incompatible options and therefore also failing.
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
          PREEMPT = yes;
          PREEMPT_DYNAMIC = yes;
          CPU_IDLE = yes;
          INTEL_IDLE = yes;
          SCHED_SMT = yes;
          SCHED_MC = yes;
          SCHED_MC_PRIO = yes;
          # Clang options require a lot of extra config
          CC_IS_CLANG = lib.mkForce yes;
          LTO_CLANG_FULL = lib.mkForce yes;
        };
      }
    ];
  };

  # auto-generated stuff
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];
}
