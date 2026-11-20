#!/usr/bin/env bash
# The one daily run: pull the merged work, lock the checkout, move the floating
# wrapper inputs and the T3 Code stable pin, rebuild the system and
# home-manager, commit the wrapper lock, pin the devshells the collection has to
# keep, and collect the store.
#
#   daily-update.sh [marker] [system-switch] [options]
#                   the whole run; the `daily-update` user timer calls it
#                   (apps/daily-update/home.nix) and a hand run with no options
#                   is the laptop's full run.
#                   The unit passes hostConfig.gcRequest and
#                   hostConfig.systemSwitchPath so both halves of each pair read
#                   one value; the fallbacks only keep a hand run working.
#
#   --t3 / --no-t3                   move the T3 Code stable pin (default: on)
#   --devshells / --no-devshells     pin the project devshells (default: on)
#   --collect / --no-collect         collect this user's store and ask the system
#                                    unit for root's (default: on)
#   --home-switch <path>             home switch to run after the system one
#                                    (default: <dots>/apps/home-switch/hm-switch.sh)
#   --wrapper-inputs "<names>"       the deploy-system inputs `nix flake update`
#                                    moves (default: the laptop's full list)
#   --kernel-cache <url> / --no-kernel-cache
#                                    substituter that must already serve this
#                                    host's kernel (or a store that already has
#                                    it), else the system *and home* switches
#                                    are skipped: a host whose kernel CI builds
#                                    passes it so a cache miss costs a day
#                                    instead of a night of compiling
#                                    (default: off)
#
# The unit passes every option explicitly, so what it does not pass is not part
# of this machine's run. The defaults above are the laptop's full run, which is
# what a hand run meant before the flags existed; a headless host's hand run
# should copy its unit's command line.
#
# The system is rebuilt before home-manager. Both configurations read this
# tree, and a change that spans them (a power.sh argument and its niri caller)
# needs the new store copy installed before the home activation calls it.
#
# The user half of the collection cannot prune generations under
# /nix/var/nix/profiles or /root, so the script writes a marker when it is
# done and a system path unit (apps/daily-update/system.nix) collects root's
# profiles. The marker is written on exit, including an interrupted one: a
# system switch can restart the display manager and take this unit's cgroup with
# it, and the collection must not depend on the update finishing.
#
# The collection runs even when the update did not: generations age whether or
# not a lock moved, so the day's collection must not depend on the network or
# on a working switch. A failed update, pull, switch, commit or collection exits
# nonzero and notifies.
#
# Every tool comes from the login PATH the user manager hands a unit; nix,
# nix-collect-garbage, git, sudo, curl, systemctl and notify-send all live there. The
# inline unit this replaces relied on the same PATH for its bare nix and git.
set -euo pipefail

# The handover below re-runs this file, so the arguments have to survive the
# parsing loop's shifts.
orig_args=("$@")

dots=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
deploy=$dots/deploy-system

t3=1
devshells=1
collect=1
home_switch=
# The laptop's list, which is what the old hardcoded call moved. The unit always
# passes this host's list, so production never reads this default.
wrapper_inputs="nixpkgs nixpkgs-unstable-small zen-browser neovimBTW wallpaper-guardian"
marker=
kernel_cache=
# apps/daily-update/system.nix links this store copy for the NOPASSWD rule, and
# lib/host.nix derives its path from powerScriptPath; the fallback is that
# derivation with its default, kept here only so a hand run works. The helper
# takes no arguments and holds the flake, the override and the core count.
# Passing the path in is what lets the test run a stub instead of the real
# thing.
system_switch=/usr/local/sbin/nixos-switch.sh

usage() {
  if [ "$#" -gt 0 ]; then
    echo "${0##*/}: $*" >&2
  fi
  echo "usage: ${0##*/} [marker] [system-switch] [--t3|--no-t3] [--devshells|--no-devshells] [--collect|--no-collect] [--home-switch PATH] [--wrapper-inputs NAMES] [--kernel-cache URL|--no-kernel-cache]" >&2
  exit 2
}

pos=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --t3) t3=1 ;;
    --no-t3) t3=0 ;;
    --devshells) devshells=1 ;;
    --no-devshells) devshells=0 ;;
    --collect) collect=1 ;;
    --no-collect) collect=0 ;;
    --home-switch)
      [ "$#" -ge 2 ] || usage "--home-switch needs a path"
      shift
      home_switch=$1
      ;;
    --wrapper-inputs)
      [ "$#" -ge 2 ] || usage "--wrapper-inputs needs a list of input names"
      shift
      wrapper_inputs=$1
      ;;
    --kernel-cache)
      [ "$#" -ge 2 ] || usage "--kernel-cache needs a url"
      shift
      kernel_cache=$1
      ;;
    --no-kernel-cache) kernel_cache= ;;
    --help | -h)
      usage
      ;;
    --*) usage "unknown option $1" ;;
    *)
      pos=$((pos + 1))
      case "$pos" in
        1) marker=$1 ;;
        2) system_switch=$1 ;;
        *) usage "unexpected argument $1" ;;
      esac
      ;;
  esac
  shift
done

# An empty list must not reach `nix flake update` with no names: that updates
# every input, which is not what a host with no inputs asked for.
[ -n "$wrapper_inputs" ] || usage "--wrapper-inputs must name at least one input"
read -r -a wrapper_names <<<"$wrapper_inputs"

marker=${marker:-$HOME/.local/state/daily-update/gc-request}
home_switch=${home_switch:-$dots/apps/home-switch/hm-switch.sh}

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

# A rebase, a merge, or a cherry-pick in progress means someone is working in
# this checkout. A timer must not abort that work, and must not switch a tree in
# that state.
work_in_progress() {
  local dir
  dir=$(git -C "$dots" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -e "$dir/rebase-merge" ] || [ -e "$dir/rebase-apply" ] ||
    [ -e "$dir/MERGE_HEAD" ] || [ -e "$dir/CHERRY_PICK_HEAD" ]
}

# Merging upstream is the one manual gate left in the kernel rotation (the
# check workflow opens a PR, the merge is the gate, CI publishes the binary), so
# the run picks the merge up instead of waiting for a hand pull. The timer's own
# T3 Code commits are the only local work in the way, hence the rebase.
#
# Returns 0 on a clean pull, 1 when the pull did not happen and the tree is
# untouched, 2 when work is already in progress and the pull was skipped, 3 when
# the pull landed but its autostash conflicts, and 4 when an earlier run left
# unmerged paths behind. Git exits 0 for both 3 and 4, and neither leaves an
# operation marker, so the unmerged index is the only evidence.
pull_merged() {
  local before
  if work_in_progress; then
    log "a rebase, merge, or cherry-pick is in progress in $dots"
    return 2
  fi
  # Checked before the pull, not only after it: once the pull has landed, the
  # next day's merge-base answers "already contained" and returns 0 without
  # ever reaching the post-pull check, so yesterday's conflict would be rebuilt.
  if [ -n "$(git -C "$dots" diff --name-only --diff-filter=U)" ]; then
    log "the checkout still has unmerged paths"
    return 4
  fi
  before=$(git -C "$dots" rev-parse HEAD)
  git -C "$dots" fetch --quiet origin || return 1
  if git -C "$dots" merge-base --is-ancestor origin/main HEAD; then
    log "tree already has every merged change"
    return 0
  fi
  if ! git -C "$dots" pull --quiet --rebase --autostash origin main; then
    # Only this pull could have started the rebase, since the probe above found
    # none, so the abort cannot be tearing down a human's resolution.
    git -C "$dots" rebase --abort >/dev/null 2>&1 || true
    return 1
  fi
  if [ -n "$(git -C "$dots" diff --name-only --diff-filter=U)" ]; then
    return 3
  fi
  log "pulled $(git -C "$dots" rev-list --count "$before..origin/main" 2>/dev/null || echo 0) commit(s)"
  return 0
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

# The helper is the hand-run command with the password taken out: fixed flake,
# fixed live-tree override, hostConfig.dailyUpdate.cores. A cache hit costs a
# minute, and a kernel that has to compile is the one case where the count
# matters.
#
# Two switches can overlap (the timer's and a hand run that does not take the
# helper's lock), and both end at switch-to-configuration, which starts as one
# fixed transient unit name. The loser exits nonzero after the other run's
# activation applied, so a failed exit is not proof of a failed switch. The
# generation is the proof, and the activation writes it, so wait for any
# in-flight activation first. When the generation moved, run the helper again:
# it waits on the lock and repeats a switch that changes nothing, which is
# cheaper than reporting a switch that happened as failed and skipping the home
# half. Only a second failure is a failure.
switch_system() {
  local before after waited=0 rc=0 unit=nixos-rebuild-switch-to-configuration.service
  before=$(readlink -f /run/current-system) || before=
  sudo -n "$system_switch" || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  # A unit that exists but is not yet `active` still owns the colliding name,
  # so every live state counts as in flight.
  while [ "$waited" -lt 180 ]; do
    case $(systemctl show -p ActiveState --value "$unit" 2>/dev/null) in
      active | activating | reloading | deactivating | refreshing) ;;
      *) break ;;
    esac
    sleep 5
    waited=$((waited + 5))
  done
  after=$(readlink -f /run/current-system) || after=
  [ "$after" != "$before" ] || return 1
  log "the system generation moved during a failed switch, running it again"
  rc=0
  sudo -n "$system_switch" || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  # Exit 4 is switch-to-configuration saying the activation applied and some
  # units failed. The generation above is the proof of the switch, and the home
  # half has to run against the new system; the failed units stay visible in
  # `systemctl --failed`. Any other code is a switch that did not apply.
  if [ "$rc" -eq 4 ] && [ "$(readlink -f /run/current-system)" = "$after" ]; then
    log "the system generation moved, and switch-to-configuration reported failed units"
    return 0
  fi
  return "$rc"
}

# Would the switch have to *build* this host's kernel? A custom kernel is not on
# cache.nixos.org, so a host that builds one waits for the run that publishes it;
# compiling it here would take hours of two cores and nothing else in the day
# would happen. Either source satisfies it: the substituter, or this machine's
# own store (a kernel built here by hand, or one a previous switch installed).
# Exit 2 means the kernel could not even be evaluated, exit 1 that it is
# nowhere; the caller treats both as "do not switch".
kernel_substitutable() {
  local out
  out=$(nix eval --raw \
    "$deploy#nixosConfigurations.$(hostname -s).config.boot.kernelPackages.kernel.outPath" \
    --override-input my-dotfiles "path:$dots" 2>/dev/null) || return 2
  nix path-info "$out" >/dev/null 2>&1 ||
    nix path-info --store "$kernel_cache" "$out" >/dev/null 2>&1
}

# The root collection is triggered by a file, not by a clean exit. Writing it
# from the trap keeps that true when the run is killed mid-switch: the
# collection is idempotent inside its two-day window, so an early marker costs
# nothing and a lost one costs a day of generations. A host that does not
# collect has no root half to ask for.
write_marker() {
  [ "$collect" -eq 1 ] || return 0
  mkdir -p -- "$(dirname -- "$marker")" 2>/dev/null || true
  date -Is >"$marker" 2>/dev/null || true
  log "asked the system unit to collect root's profiles"
}
trap write_marker EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# This file lives in the tree the pull rewrites, and a shell reads its script as
# it goes: a checkout that replaces the file under it could feed the run half of
# one version and half of the other. Hash it before the pull and hand over to
# the new copy when it moved. The rerun's pull is a no-op, so it cannot loop.
self=$(readlink -f -- "$0")
self_hash=$(sha256sum -- "$self" | cut -d' ' -f1)

log "daily update starting"
status=0
# Cleared when the checkout is not in a state a rebuild may read: a conflict, an
# unfinished operation, or a lock that would not settle. The update half is then
# skipped whole, and the day still pins and collects.
tree_ok=1
# Set when this host's own kernel is not in its substituter yet: the switch is
# skipped, home-manager with it, and the day still pins and collects.
skip_switch=0

# A wrapper without a flake.nix is not a wrapper: there is nothing to lock,
# nothing to update and no switch target, so the update half is skipped instead
# of running nix in a directory that is not a flake. The pin and the collection
# still run, since neither reads the wrapper.
if [ ! -f "$deploy/flake.nix" ]; then
  log "no deploy wrapper flake at $deploy/flake.nix"
  notify -u critical "Update failed" "No deploy wrapper at $deploy"
  status=1
  tree_ok=0
fi

if [ "$tree_ok" -eq 0 ]; then
  # Already logged and notified above: nothing in the update half can run to a
  # working switch without a wrapper, so the run goes straight to the tail.
  :
elif ! wait_for_network; then
  notify -u critical "Update failed" "No network after 10 minutes"
  status=1
else
  pull_rc=0
  pull_merged && pull_rc=0 || pull_rc=$?
  case "$pull_rc" in
    0)
      if [ ! -f "$self" ] || [ ! -x "$self" ]; then
        log "this script is gone or not executable after the pull, staying on the running copy"
      elif [ "$(sha256sum -- "$self" | cut -d' ' -f1)" != "$self_hash" ]; then
        if [ "${DAILY_UPDATE_RERUN:-0}" = 1 ]; then
          log "the pull changed this script again, staying on the running copy"
        else
          # A child, not exec: if the handover fails, this process still reaches
          # its exit trap and asks for the collection. The child writes the
          # marker too, and the root unit is idempotent inside its window.
          log "the pull changed this script, handing over to the new copy"
          DAILY_UPDATE_RERUN=1 "$self" "${orig_args[@]}" || exit $?
          exit 0
        fi
      fi
      ;;
    2)
      notify -u normal "Update skipped" "A rebase or merge is in progress in $dots"
      status=1
      tree_ok=0
      ;;
    3)
      notify -u critical "Update stopped" "The pull's autostash conflicts with local edits; the stash is kept"
      status=1
      tree_ok=0
      ;;
    4)
      notify -u critical "Update stopped" "Unmerged paths from an earlier pull are still in $dots"
      status=1
      tree_ok=0
      ;;
    1)
      # The fetch failed or the pull's own rebase was aborted, so the tree is
      # the one the run started with and can still be switched.
      notify -u critical "Update failed" "Could not pull the merged changes"
      status=1
      ;;
    *)
      # Defensive: every return above is one of 0 to 4, so this only catches a
      # future status nobody mapped. The tree's state would be unknown, so it
      # must not be switched.
      notify -u critical "Update failed" "Could not pull the merged changes"
      status=1
      tree_ok=0
      ;;
  esac

  # A merged submodule bump moves the gitlink only, so the checkout has to
  # follow before anything evaluates it or the wrapper pins it.
  if [ "$tree_ok" -eq 1 ] &&
    ! git -C "$dots" submodule update --init --recursive --quiet; then
    log "the submodule checkouts did not follow the pull"
    notify -u critical "Update failed" "Could not update the submodule checkouts"
    status=1
    tree_ok=0
  fi

  # This checkout ships no tracked flake.lock (it is gitignored), and a merged
  # kernel PR moves the URL in flake.nix without touching it. A `path:` override
  # reads this file for inputs whose URL did not move, while a standalone
  # git-flake eval ignores it and resolves from flake.nix. Locking here makes the
  # file name the revs flake.nix now names, so neither reading can land on a
  # stale entry, and keeps the write with the login account instead of root. The
  # wrapper's own lock cannot cover this input: it deliberately does not follow
  # nixpkgs-fast-release.
  if [ "$tree_ok" -eq 1 ] && ! nix flake lock "$dots"; then
    notify -u critical "Update failed" "Could not refresh this checkout's flake.lock"
    status=1
    tree_ok=0
  fi

  if [ "$tree_ok" -eq 0 ]; then
    log "checkout is not ready, skipping the flake update, the pin, and both switches"
  elif ! (
    cd -- "$deploy" && nix flake update "${wrapper_names[@]}"
  ); then
    notify -u critical "Update failed" "Failed to update flakes"
    status=1
  else
    # A tag that does not build keeps the previous pin and never blocks the day.
    if [ "$t3" -eq 1 ]; then
      log "moving the T3 Code stable pin"
      DOTFILES=$dots DEPLOY=$deploy "$dots/pkgs/t3code/update.sh" ||
        log "T3 Code pin update failed, keeping the previous pin"
    fi

    if [ -n "$kernel_cache" ]; then
      log "checking $kernel_cache for this host's kernel"
      if kernel_substitutable; then
        log "kernel is substitutable"
      else
        rc=$?
        if [ "$rc" -eq 2 ]; then
          why="could not evaluate this host's kernel"
        else
          why="this host's kernel is not in $kernel_cache yet"
        fi
        log "$why, skipping the system and home switches"
        notify -u normal "Update skipped" "$why; system and home switches skipped"
        # Status stays nonzero so `systemctl --failed` still shows the day: a
        # kernel CI never publishes is something to look at, even though a late
        # one is not. The tail below still runs.
        status=1
        skip_switch=1
      fi
    fi

    if [ "$skip_switch" -eq 1 ]; then
      # The kernel check above already said why, and the wrapper lock stays
      # uncommitted exactly as a failed switch leaves it: the next run's
      # `nix flake update` rewrites it. The tail below still runs.
      :
    elif log "switching the system" && switch_system; then
      # cores = 2 keeps a post-lock-bump rebuild polite while the machine is in
      # use.
      if NIX_CONFIG="cores = 2" "$home_switch"; then
        if commit_lock; then
          notify "Update successful" "Updated, system and home switched"
        else
          notify -u critical "Update failed" "Switched, but the wrapper lock did not commit"
          status=1
        fi
      else
        notify -u critical "Update failed" "Failed to switch configuration"
        status=1
      fi
    else
      # Home-manager is skipped on purpose: if the system half does not apply,
      # a home generation that calls into it (power.sh, a system unit) would be
      # the half-applied state the order above exists to avoid.
      notify -u critical "Update failed" "Failed to switch the system, home switch skipped"
      status=1
    fi
  fi
fi

# Pinning builds a devshell when its lock moved, so it runs before the
# collection. A failed pin keeps the previous root.
if [ "$devshells" -eq 1 ]; then
  log "pinning project devshells"
  "$dots/apps/daily-update/projects.sh" pin || log "some devshells failed to pin, previous roots kept"
fi

if [ "$collect" -eq 1 ]; then
  log "collecting the user store"
  if ! nix-collect-garbage --delete-older-than 2d; then
    notify -u critical "Store collection failed" "nix-collect-garbage exited nonzero"
    status=1
  fi
fi

log "daily update finished with status $status"
exit "$status"
