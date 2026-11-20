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

  schema = { config, ... }: {
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
        shell = mkOption {
          type = types.str;
          description = "The login shell as a nixpkgs attribute name, zsh or bash. The shell's own config belongs to an app module.";
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

      ssh.openLanPort = mkOption {
        type = types.bool;
        default = false;
        description = "Open 22 on every interface. False keeps sshd on the tailscale interface only, which is the laptop's policy.";
      };

      dotsDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "This checkout. Null means <user.home>/dotfiles.";
      };

      cacheRoot = mkOption {
        type = types.str;
        default = "${config.user.home}/.cache/nix-caches";
        description = "Where the language tool caches (sccache, npm, uv, go) live. A host with a fast scratch mount points it there; the default keeps them in the home directory.";
      };

      # What the daily update does on this machine. apps/daily-update/ turns each
      # field into either a flag on the run or a unit, so the host only states
      # which steps it has. A laptop pins the T3 Code stable release and keeps
      # the listed devshells alive; a headless box updates nixpkgs alone and
      # still collects.
      dailyUpdate = {
        t3 = mkOption {
          type = types.bool;
          default = false;
          description = "Move the T3 Code stable pin (pkgs/t3code/update.sh) before the switch.";
        };
        devshells = mkOption {
          type = types.bool;
          default = false;
          description = "Pin the project devshells in apps/daily-update/active-projects before the collection.";
        };
        collect = mkOption {
          type = types.bool;
          default = true;
          description = "Run the user store collection and ask the system path unit for root's.";
        };
        graphicalSession = mkOption {
          type = types.bool;
          default = false;
          description = "Tie the user timer to graphical-session.target. False leaves it to the user manager, which needs linger to start without a login.";
        };
        linger = mkOption {
          type = types.bool;
          default = false;
          description = "Start the login user's systemd manager at boot, so the timer runs with nobody logged in.";
        };
        cores = mkOption {
          type = types.int;
          default = 2;
          description = "The --cores count baked into nixos-switch.sh. Keep it low on a machine that stays in use.";
        };
        wrapperInputs = mkOption {
          type = types.listOf types.str;
          default = [ "nixpkgs" ];
          description = "The deploy-system flake inputs `nix flake update` moves on every run. Only inputs that wrapper declares, or the update fails.";
        };
        kernelCache = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Substituter that must already serve this host's kernel before the system switch runs. Null skips the check, which is right for a host that runs a kernel from cache.nixos.org.";
        };
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
          description = "A second panel behind its own backlight switch. Null means the host has none. A host that runs niri also sets that output's enable = false in niri.outputs, so the compositor leaves it unmapped until screenpad-toggle asks.";
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
  # Evaluates host files against the schema and fills in the derived values.
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
    }
    // {
      # The daily update's last step, and the trigger the system path unit in
      # apps/daily-update/system.nix watches. Derived here so the user unit that
      # writes it and the system unit that watches it read one path.
      gcRequest = "${config.user.home}/.local/state/daily-update/gc-request";

      # The daily update's system rebuild. It shares power.sh's directory and
      # the same sudo path shape; deriving its path from powerScriptPath keeps
      # one option, not two, and the homelab has the helper without power.sh.
      systemSwitchPath = "${builtins.dirOf config.powerScriptPath}/nixos-switch.sh";
    };
}
