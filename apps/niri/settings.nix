# The compositor config: inputs, outputs, layout, startup, and the DRM devices.
# Keybinds are in binds.nix.
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
{
  programs.niri = {
    package = inputs.niri.packages.${pkgs.system}.niri-unstable;

    settings = {
      input = {
        touchpad = {
          drag = false;
          middle-emulation = true;
        };
        warp-mouse-to-focus.enable = true;
      };

      outputs = {
        "eDP-1" = {
          focus-at-startup = true;
          mode = {
            width = 3840;
            height = 2160;
          };
          position = {
            x = 0;
            y = 0;
          };
          scale = 2.5;
        };

        "DP-2" = {
          mode = {
            width = 3840;
            height = 1100;
          };
          position = {
            x = 0;
            y = 864;
          };
          scale = 2.5;
        };
      };

      cursor = {
        size = 48;
        hide-when-typing = true;
      };

      layout = {
        gaps = 0;
        empty-workspace-above-first = true;
        always-center-single-column = true;
        default-column-width.proportion = 1.0;
        tab-indicator.hide-when-single-tab = true;

        focus-ring.enable = false;
        border.enable = false;
        shadow.enable = false;
      };

      overview = {
        zoom = 0.25;
      };

      environment = {
        WLR_DRM_NO_MODIFIERS = "1";
      };

      # Explicitly only use the iGPU and leave the dGPU alone; the nvidia
      # render node is ignored even when it is present.
      debug = {
        ignore-drm-device = "/dev/dri/by-path/pci-0000:01:00.0-render";
        render-drm-device = "/dev/dri/by-path/pci-0000:00:02.0-render";
      };

      prefer-no-csd = true;
      hotkey-overlay.skip-at-startup = true;
      spawn-at-startup = [
        {
          argv = [
            "${pkgs.brightnessctl}/bin/brightnessctl"
            "set"
            "10%"
          ];
        }
        { argv = [ "kitty" ]; }
        {
          argv = [
            "bash"
            "-c"
            "niri msg output DP-2 off || true"
          ];
        }
        {
          argv = [
            "sudo"
            "/usr/local/sbin/power.sh"
            "screenpad"
            "off"
          ];
        }
      ];
    };
  };

  # Override the niri-flake's validated config source to skip validation,
  # which avoids triggering builtins.fetchGit for the smithay Cargo dependency.
  xdg.configFile."niri-config".source = lib.mkForce (
    pkgs.writeText "config.kdl" config.programs.niri.finalConfig
  );
}
