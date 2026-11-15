# What makes one machine different from another: the account it runs as, the
# names it answers to, and the hardware the app modules assume. A host file
# (hosts/<name>/config.nix) sets these values; mkHost evaluates it once and
# hands the result to both configurations as `hostConfig`, so base/ and apps/
# never carry a username, a connector name, or a device path of their own.
#
# This is data, not policy. Add a field only when a real host would set it to a
# different value. Taste (colours, keybinds, timers) stays in the module that
# uses it.
{ lib }:
let
  inherit (lib) mkOption types;

  schema = {
    options = {
      hostName = mkOption {
        type = types.str;
        description = "networking.hostName and the flake output name.";
      };

      stateVersion = {
        system = mkOption {
          type = types.str;
          description = "system.stateVersion. Move it on a reinstall, not on an upgrade.";
        };
        home = mkOption {
          type = types.str;
          description = "home.stateVersion. Move it on a reinstall, not on an upgrade.";
        };
      };

      timeZone = mkOption { type = types.str; };

      locale = {
        default = mkOption {
          type = types.str;
          default = "en_US.UTF-8";
        };
        extra = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "A second locale for every LC_* category, for regional formats. Null leaves them at the default.";
        };
      };

      user = {
        name = mkOption {
          type = types.str;
          description = "The login name. The system account, the home-manager user, and the flake output all follow it.";
        };
        home = mkOption { type = types.str; };
        description = mkOption {
          type = types.str;
          description = "The GECOS field that login managers and finger show.";
        };
        git = {
          name = mkOption { type = types.str; };
          email = mkOption { type = types.str; };
          signingKey = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "SSH key git signs with. Null turns signing off.";
          };
        };
      };

      dotsDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "This checkout. Null means <user.home>/dotfiles.";
      };

      waylandDisplay = mkOption {
        type = types.str;
        default = "wayland-1";
        description = "Socket the session services pin, because a user service does not inherit niri's environment.";
      };

      niri = {
        outputs = mkOption {
          type = types.attrsOf types.anything;
          default = { };
          description = "programs.niri.settings.outputs, keyed by connector name.";
        };
        env = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Extra programs.niri.settings.environment entries, such as driver workarounds.";
        };
        render = {
          primary = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "DRM render node niri draws on, as a /dev/dri/by-path path.";
          };
          ignore = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "DRM render node niri must leave alone.";
          };
        };
      };

      powerScriptPath = mkOption {
        type = types.str;
        default = "/usr/local/sbin/power.sh";
        description = "Where the activation script links the root helper. sudo matches this exact path, so keybinds and the rule share it.";
      };

      hardware = {
        backlight = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Device for brightnessctl -d. Null lets brightnessctl pick the first backlight.";
        };

        screenpad = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                output = mkOption {
                  type = types.str;
                  description = "Connector name, as niri reports it.";
                };
                device = mkOption {
                  type = types.str;
                  description = "Backlight device that switches the panel.";
                };
              };
            }
          );
          default = null;
          description = "A second panel behind its own backlight switch. Null means the host has none.";
        };

        battery = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                device = mkOption { type = types.str; };
                chargeLimit = mkOption {
                  type = types.int;
                  default = 80;
                };
              };
            }
          );
          default = null;
        };

        gpu = {
          cuda = mkOption {
            type = types.bool;
            default = false;
            description = "An NVIDIA card ollama can use. Enables the CUDA build and the nvidia-smi probes.";
          };
          contextLength = mkOption {
            type = types.int;
            default = 4096;
            description = "OLLAMA_CONTEXT_LENGTH. Raise it only as far as VRAM allows.";
          };
        };
      };
    };
  };
in
{
  # Evaluates host files against the schema and fills in the one derived value.
  # Every option has a default or is required, so a host file states only what
  # differs from the next machine.
  load =
    modules:
    let
      config = (lib.evalModules { modules = [ schema ] ++ modules; }).config;
    in
    config
    // lib.optionalAttrs (config.dotsDir == null) {
      dotsDir = "${config.user.home}/dotfiles";
    };
}
