#!/usr/bin/env bash
# The one daily run: move the floating wrapper inputs, move the T3 Code stable
# pin, switch home-manager, commit the wrapper lock, pin the devshells the
# collection has to keep, and collect the store.
#
#   daily-update.sh   the whole run; the `daily-update` user timer calls it
#                     (base/home.nix) and a hand-run update is the same thing
#
# The user half of the collection cannot prune generations under
# /nix/var/nix/profiles or /root, so the script writes a marker when it is done
# and a system path unit (base/system.nix) collects root's profiles.
#
# The collection runs even when the update did not: generations age whether or
# not a lock moved, so the day's collection must not depend on the network or
# on a working switch. A failed update, switch, commit or collection exits
# nonzero and notifies.
#
# Every tool comes from the login PATH the user manager hands a unit; nix,
# nix-collect-garbage, git, curl and notify-send all live there. The inline
# unit this replaces relied on the same PATH for its bare nix and git.
set -euo pipefail

dots=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
deploy=$dots/deploy-system
# The daily-update unit passes hostConfig.gcRequest, the same value the system
# path unit in base/system.nix watches, so production has one source for this
# path. The fallback only keeps a hand run working; changing it here alone does
# not move the marker the system unit watches.
marker=${1:-$HOME/.local/state/daily-update/gc-request}

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
notify() { notify-send "$@" 2>/dev/null || true; }

# The timer is Persistent, so a missed run starts at login, often before wifi
# is up. Wait for a real answer instead of failing on the first DNS miss. Sixty
# probes of five seconds, plus the pause between them, is a ten minute worst
# case.
wait_for_network() {
  local i
  for i in $(seq 1 60); do
    curl -sf --max-time 5 -o /dev/null https://channels.nixos.org/flake-registry.json && return 0
    log "no network yet ($i/60), waiting"
    sleep 5
  done
  return 1
}

# A failed commit must not take the collection with it, and it must not pass
# silently either: the caller notifies and marks the run failed.
commit_lock() {
  git -C "$deploy" add flake.lock || return 1
  if git -C "$deploy" diff --cached --quiet -- flake.lock; then
    log "flake.lock unchanged, nothing to commit"
    return 0
  fi
  git -C "$deploy" commit -q -m "chore: private auto-update" --no-gpg-sign -- flake.lock || return 1
  log "committed flake.lock"
}

[ -d "$deploy" ] || {
  echo "${0##*/}: no deploy wrapper at $deploy" >&2
  exit 1
}
cd -- "$deploy" || exit 1

log "daily update starting"
status=0

if ! wait_for_network; then
  notify -u critical "Update failed" "No network after 10 minutes"
  status=1
elif ! nix flake update nixpkgs nixpkgs-unstable-small zen-browser; then
  notify -u critical "Update failed" "Failed to update flakes"
  status=1
else
  # A tag that does not build keeps the previous pin and never blocks the day.
  log "moving the T3 Code stable pin"
  DOTFILES=$dots DEPLOY=$deploy "$dots/scripts/update-t3code-stable.sh" ||
    log "T3 Code pin update failed, keeping the previous pin"

  # cores = 2 keeps a post-lock-bump rebuild polite while the machine is in use.
  if NIX_CONFIG="cores = 2" "$dots/scripts/hm-switch.sh"; then
    if commit_lock; then
      notify "Update successful" "Updated and switched privately"
    else
      notify -u critical "Update failed" "Switched, but the wrapper lock did not commit"
      status=1
    fi
  else
    notify -u critical "Update failed" "Failed to switch configuration"
    status=1
  fi
fi

# Pinning builds a devshell when its lock moved, so it runs before the
# collection. A failed pin keeps the previous root.
log "pinning project devshells"
"$dots/scripts/projects.sh" pin || log "some devshells failed to pin, previous roots kept"

log "collecting the user store"
if ! nix-collect-garbage --delete-older-than 2d; then
  notify -u critical "Store collection failed" "nix-collect-garbage exited nonzero"
  status=1
fi

mkdir -p -- "$(dirname -- "$marker")"
date -Is >"$marker"
log "asked the system unit to collect root's profiles"

log "daily update finished with status $status"
exit "$status"
