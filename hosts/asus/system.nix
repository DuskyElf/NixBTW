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

  environment.sessionVariables = {
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

    kernelPackages = pkgs.linuxPackages_zen;
    kernelPatches = [
      {
        name = "march-native-for-zen-kernel";
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
        };
      }
    ];
  };

  # auto-generated stuff
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];
}
