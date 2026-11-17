# The compositor config: inputs, outputs, layout, startup, and the DRM devices.
# Keybinds are in binds.nix.
#
# Outputs, render nodes, and driver workarounds come from the host config: they
# describe the panels and the GPU, not the compositor. Everything else here is
# the same on any machine with niri.
{
  config,
  hostConfig,
  brightness,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  screenpad = hostConfig.hardware.screenpad;

  # Render nodes are host paths. Only niri's debug block names them, and only
  # when the host has an opinion; an empty block is not valid KDL.
  debug =
    lib.optionalAttrs (hostConfig.niri.render.primary != null) {
      render-drm-device = hostConfig.niri.render.primary;
    }
    // lib.optionalAttrs (hostConfig.niri.render.ignore != null) {
      ignore-drm-device = hostConfig.niri.render.ignore;
    };
in
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

      outputs = hostConfig.niri.outputs;

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

      prefer-no-csd = true;
      hotkey-overlay.skip-at-startup = true;
      spawn-at-startup = [
        {
          argv = [
            brightness.bin
          ]
          ++ brightness.argv
          ++ [
            "set"
            "10%"
          ];
        }
        { argv = [ "kitty" ]; }
      ]
      ++ lib.optionals (screenpad != null) [
        # The output config keeps DP-2 unmapped at every compositor start, but
        # a niri restart does not run screenpad-off.service, so without this the
        # backlight would stay lit on a panel nothing is showing. Blanking here
        # is the same default as boot; Mod+1 turns it back on.
        {
          argv = [
            "sudo"
            "-n"
            hostConfig.powerScriptPath
            "screenpad"
            "off"
          ];
        }
      ];
    }
    // lib.optionalAttrs (hostConfig.niri.env != { }) {
      environment = hostConfig.niri.env;
    }
    // lib.optionalAttrs (debug != { }) {
      inherit debug;
    };
  };

  # Override the niri-flake's validated config source to skip validation,
  # which avoids triggering builtins.fetchGit for the smithay Cargo dependency.
  xdg.configFile."niri-config".source = lib.mkForce (
    pkgs.writeText "config.kdl" config.programs.niri.finalConfig
  );
}
