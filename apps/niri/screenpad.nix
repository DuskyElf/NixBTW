# The screenpad switch: the panel behind asus_screenpad and the niri output that
# shows on it. power.sh owns the backlight; on this kernel bl_power 4 blanks the
# panel and 0 lights it (the standard backlight class spelling). The output is
# configured off, so it stays dark and unmapped until this asks. The power
# helper is the store copy at /usr/local/sbin/power.sh, so a change that spans
# both halves needs the system switch before the home one; otherwise this calls
# the old script with the new arguments.
#
# This is not a module, it is a factory: binds.nix imports it for Mod+1 and adds
# it to home.packages so `screenpad-toggle off` works from a terminal too.
#
# Why a script instead of a keybind one-liner: the panel powers on over ACPI and
# its DP link needs a moment to train, so niri's first attempt to build the
# output can fail with EINVAL. Retry until the output is really mapped instead
# of trusting one `niri msg output on`, which exits 0 even when nothing appears.
#
# The transient on lives in niri's memory. Reloading a config whose outputs
# section changed drops it, leaving the panel lit and unmapped until the next
# press; the same is true after a niri restart, except startup blanks it.
{
  pkgs,
  screenpad,
  powerScriptPath,
}:
pkgs.writeShellApplication {
  name = "screenpad-toggle";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gawk
    pkgs.libnotify
    pkgs.util-linux
  ];
  text = ''
    # niri isn't a runtimeInput: the session gets the compositor from
    # programs.niri.enable in apps/niri/system.nix, so PATH resolves the binary
    # actually running. Pinning it here would force the home module's
    # programs.niri.package, which under the current lock fails to evaluate
    # (niri-flake's libdisplay-info_0_2 assert), while PATH already has the
    # running compositor. sudo is not a runtimeInput either: the store sudo is
    # not setuid and sits ahead of /run/wrappers/bin, so it fails with
    # "effective uid is not 0". Keep inheritPath at its default.
    output='${screenpad.output}'
    device='${screenpad.device}'
    power='${powerScriptPath}'
    bl_power="/sys/class/backlight/$device/bl_power"

    # A second press is dropped, not queued: a held key would otherwise stack
    # toggles and leave the panel in a random state. binds.nix also sets
    # repeat=false.
    exec 9>"''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/screenpad-toggle.lock"
    flock -n 9 || exit 0

    if ! command -v niri >/dev/null; then
      notify-send "Secondary Display" "niri is not on PATH" -t 2000 || true
      exit 1
    fi
    # A binary is not a compositor: without a session this would light the panel
    # and then time out, so refuse before touching the hardware.
    if ! niri msg version >/dev/null 2>&1; then
      notify-send "Secondary Display" "niri is not running" -t 2000 || true
      exit 1
    fi
    if [ ! -r "$bl_power" ]; then
      notify-send "Secondary Display" "No backlight device $device" -t 2000 || true
      exit 1
    fi

    # niri prints a known but unmapped output without a current mode.
    mapped() {
      niri msg outputs 2>/dev/null | awk -v tag="($output)" '
        /^Output / { active = index($0, tag) > 0; next }
        active && /Current mode/ { found = 1 }
        END { exit !found }
      '
    }

    # Write the hardware and read back the driver's cached value. The exit code
    # alone is not enough: a power.sh from before the value swap accepts
    # `screenpad on|off` and writes the opposite value (its `off` writes 0,
    # which lights the panel). sudo -n fails at once instead of prompting
    # inside a keybind-spawned process.
    power_state() {
      local want
      case "$1" in
        off) want=4 ;;
        on) want=0 ;;
      esac
      if ! sudo -n "$power" screenpad "$1"; then
        notify-send "Secondary Display" "power.sh screenpad $1 failed" -t 2000 || true
        return 1
      fi
      if [ "$(cat "$bl_power" 2>/dev/null)" != "$want" ]; then
        notify-send "Secondary Display" "power.sh did not change bl_power" -t 2000 || true
        return 1
      fi
    }

    power_on() {
      # Enable the output before powering the panel: when the DP hotplug
      # arrives, niri's scan then sees it enabled and maps it. The loop covers
      # the modeset losing its race with link training (EINVAL); every
      # `output on` re-runs that scan. Half-second spacing: link training takes
      # several seconds here, and a faster recreate-and-test-commit loop hammers
      # a marginal link.
      niri msg output "$output" on >/dev/null 2>&1 || true
      if ! power_state on; then
        niri msg output "$output" off >/dev/null 2>&1 || true
        return 1
      fi
      for _ in {1..20}; do
        niri msg output "$output" on >/dev/null 2>&1 || true
        sleep 0.5
        if mapped; then
          notify-send "Secondary Display" "Turned ON" -t 1000 || true
          return 0
        fi
      done
      # Never leave a lit panel with no output behind: blank it and say what
      # actually happened, so the next press is a clean off to on cycle.
      if power_state off; then
        niri msg output "$output" off >/dev/null 2>&1 || true
        notify-send "Secondary Display" "niri did not attach $output; panel blanked" -t 2000 || true
      else
        niri msg output "$output" off >/dev/null 2>&1 || true
        notify-send "Secondary Display" "niri did not attach $output; panel still lit" -t 2000 || true
      fi
      return 1
    }

    power_off() {
      # Blank first: if the write fails, keep the output mapped instead of
      # leaving a lit panel that shows nothing.
      power_state off || return 1
      niri msg output "$output" off >/dev/null 2>&1 || true
      notify-send "Secondary Display" "Turned OFF" -t 1000 || true
    }

    case "''${1:-toggle}" in
      on) power_on ;;
      off) power_off ;;
      toggle)
        # 4 is blanked, so the panel is dark and the next press turns it on.
        if [ "$(cat "$bl_power" 2>/dev/null)" = 4 ]; then
          power_on
        else
          power_off
        fi
        ;;
      *)
        echo "usage: screenpad-toggle [on|off|toggle]" >&2
        exit 2
        ;;
    esac
  '';
}
