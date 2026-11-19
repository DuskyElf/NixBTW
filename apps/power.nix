# The keybind power helper. apps/power/power.sh runs as root through NOPASSWD
# sudo, so the invariant is two parts: an immutable body and pinned command
# lookups. The activation script links this store copy into /usr/local/sbin,
# which is the only path sudo matches, and runtimeInputs means sudo's inherited
# caller PATH cannot shadow a tool. writeShellApplication emits a directory, so
# link its /bin/power.sh, not it. Edits to apps/power/power.sh only reach root on
# the next nixos-rebuild; the file is store-pinned and not linked live anywhere,
# because sudo matches only the /usr/local/sbin path.
#
# This is a system app, so a host that has no keybinds and no battery (the
# homelab) does not list it and never installs the helper or the rule.
{
  lib,
  pkgs,
  hostConfig,
  ...
}:
let
  powerScript = pkgs.writeShellApplication {
    name = "power.sh";
    inheritPath = false;
    # The script owns its own errexit/nounset/pipefail, so the wrapper must not
    # add a second copy of them.
    bashOptions = [ ];
    runtimeInputs = [
      pkgs.auto-cpufreq
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.kmod
      pkgs.libnotify
      pkgs.sudo
    ];
    # ls -l | grep parses /proc/<pid>/fd symlink targets; a glob is not
    # equivalent, so this is the one shellcheck check worth excluding.
    excludeShellChecks = [ "SC2010" ];
    # The screenpad device is host data, so bake it into this root-only copy
    # instead of accepting it as an argument. The NOPASSWD rule allows power.sh
    # with any arguments, and a device argument would let that rule blank any
    # backlight, the internal panel included. The writable ~/.config copy has
    # no baked value and cannot write sysfs as the login user anyway.
    text = ''
      SCREENPAD_DEVICE=${
        lib.escapeShellArg (
          if hostConfig.hardware.screenpad == null then "" else hostConfig.hardware.screenpad.device
        )
      }
    ''
    + lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./power/power.sh);
  };
in
{
  system.activationScripts.powerHelper = ''
    mkdir -p ${builtins.dirOf hostConfig.powerScriptPath}
    ln -sfn ${lib.getExe powerScript} ${hostConfig.powerScriptPath}
  '';

  security.sudo.extraRules = [
    {
      users = [ hostConfig.user.name ];
      commands = [
        {
          command = hostConfig.powerScriptPath;
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  # Disable the credential cache: a fresh sudo timestamp (e.g. from a rebuild)
  # would otherwise let anything running as the login user `sudo -n <anything>`
  # within the window. The NOPASSWD keybind rule above is unaffected, but every
}
