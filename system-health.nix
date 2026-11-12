{
  lib,
  pkgs,
  ...
}:
let
  # Root units must never execute a user-writable file. scripts/ is
  # mkOutOfStoreSymlink'd into ~/.config, so the script bodies are read from the
  # repo at eval time and pinned into the store. Editing the live
  # ~/.config/scripts/machine-digest.sh changes nothing for the service; the
  # edit only applies on the next nixos-rebuild, same as scripts/power.sh.
  machineDigest = pkgs.writeShellApplication {
    name = "machine-digest";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
      gawk
      gnused
    ];
    text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./scripts/machine-digest.sh);
  };

  suspendProbe = pkgs.writeShellApplication {
    name = "suspend-probe";
    runtimeInputs = with pkgs; [
      util-linux
      procps
      gnused
    ];
    text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./scripts/suspend-probe.sh);
  };

  stateDir = "/var/lib/machine-digest";

  # The digest itself only prints. This wrapper gives the unit its two side
  # effects: a stable copy in the state dir, rewritten every run, and the same
  # report on stdout so the journal keeps a history. tee truncates, it does not
  # append.
  digestRun = pkgs.writeShellScript "machine-digest-run" ''
    set -euo pipefail
    ${machineDigest}/bin/machine-digest | tee ${stateDir}/latest.txt
  '';
in
{
  # Weekly one page health report. It runs as root because the full journal and
  # other users' coredumps need it, so it is sandboxed down to read-only
  # everything except its own state dir. StateDirectory implies the write path;
  # ReadWritePaths spells it out so the only writable location is visible here.
  systemd.services.machine-digest = {
    description = "Machine health digest";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${digestRun}";
      SyslogIdentifier = "machine-digest";
      StateDirectory = "machine-digest";
      ReadWritePaths = [ stateDir ];
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };

  systemd.timers.machine-digest = {
    wantedBy = [ "timers.target" ];
    description = "Weekly machine health digest";
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };

  # NixOS writes this as a drop-in for the shipped systemd-suspend unit
  # (overrideStrategy = asDropinIfExists), so it extends the real unit instead
  # of replacing it. The probe only logs and cannot fail, so it cannot turn a
  # suspend into a failure.
  systemd.services.systemd-suspend.serviceConfig.ExecStartPre = [
    "${suspendProbe}/bin/suspend-probe"
  ];
}
