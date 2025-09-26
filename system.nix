{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.hostOptions = {
    hostName = lib.mkOption {
      type = lib.types.str;
    };
  };

  config = {
    nixpkgs.config.allowUnfree = true;

    console.useXkbConfig = true;
    services.xserver.xkb.options = "ctrl:swapcaps";

    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    networking = {
      networkmanager.enable = true;
      hostName = config.hostOptions.hostName;
    };

    services.blueman.enable = true;
    hardware.bluetooth.enable = true;

    # for better battery life keep it at 80%
    systemd.services.battery-threshold-control = {
      script = ''
        echo "80" > /sys/class/power_supply/BAT0/charge_control_end_threshold
      '';
      wantedBy = [ "multi-user.target" ];
    };

    services.auto-cpufreq = {
      enable = true;
      settings = {
        battery = {
          governor = "powersave";
          turbo = "never";
        };
        charger = {
          governor = "powersave";
          turbo = "auto";
        };
      };
    };

    time.timeZone = "Asia/Kolkata";
    i18n.defaultLocale = "en_US.UTF-8";

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    i18n.extraLocaleSettings = {
      LC_ADDRESS = "en_IN";
      LC_IDENTIFICATION = "en_IN";
      LC_MEASUREMENT = "en_IN";
      LC_MONETARY = "en_IN";
      LC_NAME = "en_IN";
      LC_NUMERIC = "en_IN";
      LC_PAPER = "en_IN";
      LC_TELEPHONE = "en_IN";
      LC_TIME = "en_IN";
    };

    system.stateVersion = "25.05"; # Leave it as it is
  };
}
