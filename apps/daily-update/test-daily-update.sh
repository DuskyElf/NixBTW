#!/usr/bin/env bash
# test-daily-update: deterministic checks for apps/daily-update/daily-update.sh.
#
# The script runs in a fake tree. Its three sibling scripts (T3 Code pin,
# hm-switch, projects) are stubs that check the environment they are handed and
# record their call, and nix, nix-collect-garbage, git, sudo, curl, notify-send
# and sleep are shims first in PATH. The sleep shim does nothing, so the 60-probe
# network loop is free, and the collection shim refuses to run once the marker
# exists, which is what proves the collection comes first. The sudo shim checks
# that only the helper path the unit passes is ever asked for, and never runs a
# real rebuild. Nothing here touches the real wrapper, store, network, sudo, or
# notification daemon.
#
# Cases:
#   1. happy path      pull, submodules, tree lock, flake update, T3 pin, system
#                      switch, home switch, commit, devshell pin, collection
#   2. network wait    two failed probes, then an answer: the run proceeds
#   3. no network      sixty failed probes: critical notify, no pull, no nix
#                      call, the collection still runs, exit 1
#   4. rebase conflict critical notify, the rebase is aborted, the update and
#                      both switches still run, exit 1
#   5. fetch fails     critical notify, the pull never starts, the settled tree
#                      is still updated and switched, exit 1
#   6. up to date      no pull, no rebase, the rest of the run unchanged
#   7. work in progress a rebase is already running: no pull, no abort, no
#                      switch, the collection still runs, exit 1
#   8. autostash       the pull exits 0 but leaves unmerged paths: no submodule
#                      update, no switch, critical notify, exit 1
#   9. submodules      fail to follow: no lock, no update, no switch, exit 1
#  10. tree lock       fails: no update, no switch, critical notify, exit 1
#  11. flake update    fails: no T3 pin, no switch, collection still runs, exit 1
#  12. T3 pin          fails: the run carries on to the system switch
#  13. system switch   fails: critical notify, no home switch, no commit,
#                      collection still runs, exit 1
#  14. home switch     fails: critical notify, no commit, collection still runs,
#                      exit 1
#  15. lock unchanged  nothing is committed
#  16. collection      fails: critical notify, marker still written, exit 1
#  17. devshell pin    fails: the collection still runs
#  18. commit fails    critical notify, collection still runs, exit 1
#  19. arguments       the marker and helper paths the unit passes are the two
#                      that get used
#  20. no wrapper      exits before the network wait, nothing recorded
#  21. earlier conflicts unmerged paths survive into a later run: the pre-pull
#                      probe stops the update half, the collection still runs
#  22. killed mid-run  SIGTERM during the pull: the exit trap asks for the root
#                      collection anyway
#  23. self update     the pull rewrites this script: the run hands over to the
#                      new copy as a child, whose new line runs, and finishes
#                      there
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/daily-update.sh
repo=$(cd -- "$here/../.." && pwd)
mkdir -p -- "$repo/.tmp"
work=$(mktemp -d "$repo/.tmp/test-daily-update.XXXXXX")
trap 'rm -rf "$work"' EXIT

case=setup
fail() {
  echo "FAIL ($case): $*" >&2
  exit 1
}

ok() { echo "ok ($case): $*"; }

if [ ! -x "$script" ]; then
  fail "$script is missing or not executable"
fi

tree=$work/dotfiles
bin=$work/bin
home=$work/home
mkdir -p "$tree/apps/daily-update" "$tree/apps/home-switch" "$tree/pkgs/t3code" \
  "$tree/deploy-system" "$bin" "$home"
cp -- "$script" "$tree/apps/daily-update/daily-update.sh"
under_test=$tree/apps/daily-update/daily-update.sh
marker=$home/.local/state/daily-update/gc-request
switch_helper=$work/nixos-switch.sh
gitdir=$work/gitdir

# Siblings the script drives. Each checks what the script passes it, records
# the call, then obeys its switch.
cat >"$tree/pkgs/t3code/update.sh" <<'STUB'
#!/usr/bin/env bash
[ "${DOTFILES:-}" = "$T_TREE" ] || { echo "bad DOTFILES=${DOTFILES:-}" >&2; exit 4; }
[ "${DEPLOY:-}" = "$T_TREE/deploy-system" ] || { echo "bad DEPLOY=${DEPLOY:-}" >&2; exit 4; }
printf 't3code\n' >> "$T_CALLS"
exit "${T_T3CODE:-0}"
STUB
cat >"$tree/apps/home-switch/hm-switch.sh" <<'STUB'
#!/usr/bin/env bash
[ "${NIX_CONFIG:-}" = "cores = 2" ] || { echo "bad NIX_CONFIG=${NIX_CONFIG:-}" >&2; exit 4; }
printf 'switch\n' >> "$T_CALLS"
exit "${T_SWITCH:-0}"
STUB
cat >"$tree/apps/daily-update/projects.sh" <<'STUB'
#!/usr/bin/env bash
printf 'projects %s\n' "$*" >> "$T_CALLS"
exit "${T_PIN:-0}"
STUB
chmod +x "$tree/pkgs/t3code/update.sh" "$tree/apps/home-switch/hm-switch.sh" \
  "$tree/apps/daily-update/projects.sh"

cat >"$bin/nix" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "flake lock $T_TREE")
    printf 'nix flake lock\n' >> "$T_CALLS"
    exit "${T_LOCK:-0}"
    ;;
  "flake update nixpkgs nixpkgs-unstable-small zen-browser neovimBTW wallpaper-guardian")
    printf 'nix flake update\n' >> "$T_CALLS"
    exit "${T_FLAKE:-0}"
    ;;
  *)
    echo "bad nix arguments: $*" >&2
    exit 4
    ;;
esac
SHIM
cat >"$bin/nix-collect-garbage" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "--delete-older-than 2d" ] || {
  echo "bad collection arguments: $*" >&2
  exit 4
}
[ ! -e "$T_MARKER" ] || {
  echo "marker existed before the collection ran" >&2
  exit 4
}
printf 'nix-collect-garbage\n' >> "$T_CALLS"
exit "${T_GC:-0}"
SHIM
cat >"$bin/sudo" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
# Only the helper path the unit passes, always non-interactive, never another
# argument: a prompt in a timer would hang until the unit's timeout.
[ "$#" -eq 2 ] || { echo "sudo with $# arguments: $*" >&2; exit 4; }
[ "$1" = "-n" ] || { echo "sudo without -n: $*" >&2; exit 4; }
[ "$2" = "$T_SWITCH_HELPER" ] || {
  echo "sudo asked for $2, wanted $T_SWITCH_HELPER" >&2
  exit 4
}
printf 'sudo switch\n' >> "$T_CALLS"
exit "${T_SYSTEM_SWITCH:-0}"
SHIM
cat >"$bin/git" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
[ "${args[0]:-}" = "-C" ] || { echo "git without -C: $*" >&2; exit 4; }
repo=${args[1]:-}
args=("${args[@]:2}")

case "$repo" in
  "$T_TREE")
    case "${args[0]}" in
      rev-parse)
        case "${args[1]:-}" in
          HEAD) printf '%s\n' "$T_HEAD" ;;
          --absolute-git-dir) printf '%s\n' "$T_GITDIR" ;;
          *) echo "odd rev-parse: $*" >&2; exit 4 ;;
        esac
        ;;
      fetch)
        case " ${args[*]} " in
          *" origin "*) ;;
          *) echo "fetch without origin: $*" >&2; exit 4 ;;
        esac
        printf 'git fetch\n' >> "$T_CALLS"
        exit "${T_FETCH:-0}"
        ;;
      merge-base)
        case " ${args[*]} " in
          *" --is-ancestor origin/main HEAD "*) ;;
          *) echo "odd merge-base: $*" >&2; exit 4 ;;
        esac
        printf 'git merge-base\n' >> "$T_CALLS"
        # The first answer after a pull is "already contained", which is what
        # the rerun of a self-updating script sees.
        if [ "${T_PULL:-0}" = 0 ] || [ -e "$T_PULL_APPLIED" ]; then exit 0; fi
        exit 1
        ;;
      pull)
        case " ${args[*]} " in
          *" --rebase "*) ;;
          *) echo "pull without --rebase: $*" >&2; exit 4 ;;
        esac
        case " ${args[*]} " in
          *" --autostash "*) ;;
          *) echo "pull without --autostash: $*" >&2; exit 4 ;;
        esac
        case " ${args[*]} " in
          *" origin main "*) ;;
          *) echo "pull from the wrong branch: $*" >&2; exit 4 ;;
        esac
        printf 'git pull\n' >> "$T_CALLS"
        if [ "${T_PULL:-0}" = term ]; then
          # A switch can kill the run through the unit's cgroup. The marker
          # must survive it.
          : >"$T_PULL_APPLIED"
          kill -TERM "$PPID"
          exit 0
        fi
        if [ "${T_PULL:-0}" = conflict ]; then exit 1; fi
        if [ "${T_PULL:-0}" = stash ]; then : >"$T_UNMERGED"; fi
        : >"$T_PULL_APPLIED"
        if [ "${T_SELF_UPDATE:-0}" = 1 ]; then
          # A line before the script's exit, so the new copy does something a
          # comment after the exit could not.
          sed -i '$i printf "new copy\n" >> "$T_CALLS"' "$T_SCRIPT"
        fi
        exit 0
        ;;
      rev-list)
        case " ${args[*]} " in
          *" --count "*"..origin/main "*) ;;
          *) echo "odd rev-list: $*" >&2; exit 4 ;;
        esac
        printf 'git rev-list\n' >> "$T_CALLS"
        printf '2\n'
        ;;
      diff)
        case " ${args[*]} " in
          *" --name-only "*) ;;
          *) echo "diff without --name-only: $*" >&2; exit 4 ;;
        esac
        case " ${args[*]} " in
          *" --diff-filter=U "*) ;;
          *) echo "diff without --diff-filter=U: $*" >&2; exit 4 ;;
        esac
        # Not recorded: this probe runs after every successful pull, and the
        # cases prove it by what they do next.
        [ ! -e "$T_UNMERGED" ] || echo f
        ;;
      rebase)
        [ "${args[1]:-}" = --abort ] || { echo "odd rebase: $*" >&2; exit 4; }
        printf 'git rebase abort\n' >> "$T_CALLS"
        ;;
      submodule)
        case " ${args[*]} " in
          *" update --init --recursive "*) ;;
          *) echo "odd submodule: $*" >&2; exit 4 ;;
        esac
        printf 'git submodule update\n' >> "$T_CALLS"
        exit "${T_SUBMODULE:-0}"
        ;;
      *) echo "unexpected git call on the tree: $*" >&2; exit 4 ;;
    esac
    ;;
  "$T_DEPLOY")
    case "${args[0]}" in
      add)
        [ "${args[1]:-}" = flake.lock ] || { echo "bad add: $*" >&2; exit 4; }
        printf 'git add\n' >> "$T_CALLS"
        ;;
      diff)
        case " ${args[*]} " in
          *" --cached "*" flake.lock "*) ;;
          *) echo "bad diff: $*" >&2; exit 4 ;;
        esac
        printf 'git diff\n' >> "$T_CALLS"
        if [ "${T_LOCK_CHANGED:-0}" = 1 ]; then exit 1; else exit 0; fi
        ;;
      commit)
        case " ${args[*]} " in
          *" --no-gpg-sign "*) ;;
          *) echo "commit without --no-gpg-sign: $*" >&2; exit 4 ;;
        esac
        case " ${args[*]} " in
          *" -- flake.lock "*) ;;
          *) echo "commit without the flake.lock pathspec: $*" >&2; exit 4 ;;
        esac
        msg=
        for ((i = 0; i < ${#args[@]}; i++)); do
          [ "${args[i]}" = "-m" ] && msg=${args[i + 1]}
        done
        [ "$msg" = "chore: private auto-update" ] || {
          echo "bad commit message: ${msg:-none}" >&2
          exit 4
        }
        printf 'git commit\n' >> "$T_CALLS"
        exit "${T_COMMIT:-0}"
        ;;
      *) echo "unexpected git call on the wrapper: $*" >&2; exit 4 ;;
    esac
    ;;
  *) echo "git -C $repo, neither tree nor wrapper" >&2; exit 4 ;;
esac
SHIM
cat >"$bin/curl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
n=$(cat "$T_CURL_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$T_CURL_COUNT"
if [ "$n" -le "${T_CURL_FAILS:-0}" ]; then exit 7; fi
exit 0
SHIM
cat >"$bin/sleep" <<'SHIM'
#!/bin/sh
exit 0
SHIM
cat >"$bin/notify-send" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T_NOTIFY"
SHIM
chmod +x "$bin"/*

export PATH="$bin:$PATH"
# The unit passes the marker path; a hand run falls back to $HOME, so the fake
# home keeps the real state dir and the real marker untouched.
export HOME="$home"
export T_TREE="$tree" T_DEPLOY="$tree/deploy-system" T_MARKER="$marker"
export T_SCRIPT="$under_test" T_PULL_APPLIED="$work/pull-applied"
export T_UNMERGED="$work/unmerged" T_GITDIR="$gitdir" T_HEAD=$'abc1234\n'
export T_SWITCH_HELPER="$switch_helper" T_CALLS="$work/calls" T_NOTIFY="$work/notify"
export T_CURL_COUNT="$work/curl-count"

reset() {
  : >"$T_CALLS"
  : >"$T_NOTIFY"
  rm -f "$T_CURL_COUNT" "$T_PULL_APPLIED" "$T_UNMERGED"
  rm -rf "$home/.local/state" "$gitdir"
  mkdir -p "$home" "$gitdir"
  export T_FLAKE=0 T_T3CODE=0 T_SWITCH=0 T_SYSTEM_SWITCH=0 T_PIN=0 T_GC=0
  export T_COMMIT=0 T_FETCH=0 T_SUBMODULE=0 T_LOCK=0 T_PULL=1 T_SELF_UPDATE=0
  export T_CURL_FAILS=0 T_LOCK_CHANGED=1
}

run() {
  rc=0
  "$under_test" "${1:-$marker}" "${2:-$switch_helper}" >"$work/out" 2>&1 || rc=$?
}

calls() { cat -- "$T_CALLS" 2>/dev/null || true; }
probes() { cat -- "$T_CURL_COUNT" 2>/dev/null || echo 0; }

expect_calls() {
  [ "$(calls)" = "$1" ] ||
    fail "calls were
$(calls)
wanted
$1"
}

expect_status() {
  [ "$rc" -eq "$1" ] || fail "exit $rc, wanted $1; output:
$(cat -- "$work/out")"
}

expect_notified() {
  grep -qF -- "$1" "$T_NOTIFY" ||
    fail "no notification matching '$1'; got:
$(cat -- "$T_NOTIFY")"
}

expect_not_notified() {
  ! grep -qF -- "$1" "$T_NOTIFY" ||
    fail "unexpected notification matching '$1'; got:
$(cat -- "$T_NOTIFY")"
}

expect_output() {
  grep -qF -- "$1" "$work/out" || fail "no output matching '$1'; got:
$(cat -- "$work/out")"
}

expect_marker() {
  [ -s "$marker" ] || fail "marker not written"
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$marker" ||
    fail "marker does not hold a date: $(cat -- "$marker")"
}

expect_no_marker() { [ ! -e "$marker" ] || fail "marker written"; }

# The lines a run produces around the two switches. Cases that fail earlier or
# later take a prefix or a subset.
pull_full="git fetch
git merge-base
git pull
git rev-list"
settled="$pull_full
git submodule update
nix flake lock"
up_to_system="$settled
nix flake update
t3code
sudo switch"
home_calls="switch
git add
git diff
git commit"
tail_calls="projects pin
nix-collect-garbage"

case="1 happy path"
reset
run
expect_status 0
expect_calls "$up_to_system
$home_calls
$tail_calls"
expect_notified "Update successful"
expect_marker
ok "pull, submodules, lock, pin, both switches, commit, collection, marker"

case="2 network wait"
reset
export T_CURL_FAILS=2
run
expect_status 0
[ "$(probes)" = 3 ] || fail "probed $(probes) times, wanted 3"
expect_calls "$up_to_system
$home_calls
$tail_calls"
ok "waited through two failed probes"

case="3 no network"
reset
export T_CURL_FAILS=100
run
expect_status 1
expect_calls "$tail_calls"
expect_notified "No network after 10 minutes"
expect_marker
[ "$(probes)" = 60 ] || fail "probed $(probes) times, wanted 60"
ok "gave up after 60 probes, skipped the update, still collected"

case="4 rebase conflict"
reset
export T_PULL=conflict
run
expect_status 1
expect_calls "git fetch
git merge-base
git pull
git rebase abort
git submodule update
nix flake lock
nix flake update
t3code
sudo switch
$home_calls
$tail_calls"
expect_notified "Could not pull the merged changes"
expect_marker
ok "aborted its own rebase, notified, and carried on with the tree it had"

case="5 fetch fails"
reset
export T_FETCH=1
run
expect_status 1
expect_calls "git fetch
git submodule update
nix flake lock
nix flake update
t3code
sudo switch
$home_calls
$tail_calls"
expect_notified "Could not pull the merged changes"
ok "skipped the pull and still updated and switched the tree it had"

case="6 up to date"
reset
export T_PULL=0
run
expect_status 0
expect_calls "git fetch
git merge-base
git submodule update
nix flake lock
nix flake update
t3code
sudo switch
$home_calls
$tail_calls"
expect_notified "Update successful"
ok "no pull, no rebase, the rest of the run unchanged"

case="7 work in progress"
reset
: >"$gitdir/rebase-merge"
run
expect_status 1
expect_calls "$tail_calls"
expect_notified "A rebase or merge is in progress"
expect_marker
ok "left the human's rebase alone and skipped the switches"

case="8 autostash conflict"
reset
export T_PULL=stash
run
expect_status 1
expect_calls "git fetch
git merge-base
git pull
$tail_calls"
expect_notified "autostash conflicts with local edits"
expect_marker
ok "stopped after the pull, kept the stash, switched nothing"

case="9 submodules fail"
reset
export T_SUBMODULE=1
run
expect_status 1
expect_calls "$pull_full
git submodule update
$tail_calls"
expect_notified "Could not update the submodule checkouts"
expect_marker
ok "no lock, no update, no switch"

case="10 tree lock fails"
reset
export T_LOCK=1
run
expect_status 1
expect_calls "$pull_full
git submodule update
nix flake lock
$tail_calls"
expect_notified "Could not refresh this checkout's flake.lock"
expect_marker
ok "no update, no switch"

case="11 flake update fails"
reset
export T_FLAKE=1
run
expect_status 1
expect_calls "$settled
nix flake update
$tail_calls"
expect_notified "Failed to update flakes"
expect_not_notified "Update successful"
expect_marker
ok "skipped the pin and both switches, still collected"

case="12 T3 pin fails"
reset
export T_T3CODE=1
run
expect_status 0
expect_calls "$up_to_system
$home_calls
$tail_calls"
expect_notified "Update successful"
ok "carried on to the system switch with the previous pin"

case="13 system switch fails"
reset
export T_SYSTEM_SWITCH=1
run
expect_status 1
expect_calls "$up_to_system
$tail_calls"
expect_notified "Failed to switch the system"
expect_not_notified "Update successful"
expect_marker
ok "skipped home-manager and the commit, still pinned and collected"

case="14 home switch fails"
reset
export T_SWITCH=1
run
expect_status 1
expect_calls "$up_to_system
switch
$tail_calls"
expect_notified "Failed to switch configuration"
expect_not_notified "Update successful"
expect_marker
ok "skipped the commit but still pinned and collected"

case="15 lock unchanged"
reset
export T_LOCK_CHANGED=0
run
expect_status 0
expect_calls "$up_to_system
switch
git add
git diff
$tail_calls"
expect_notified "Update successful"
ok "left the commit out"

case="16 collection fails"
reset
export T_GC=1
run
expect_status 1
expect_calls "$up_to_system
$home_calls
$tail_calls"
expect_notified "Store collection failed"
expect_marker
ok "reported the failure and still asked for the root half"

case="17 devshell pin fails"
reset
export T_PIN=1
run
expect_status 0
expect_calls "$up_to_system
$home_calls
$tail_calls"
expect_notified "Update successful"
ok "collected anyway"

case="18 commit fails"
reset
export T_COMMIT=1
run
expect_status 1
expect_calls "$up_to_system
$home_calls
$tail_calls"
expect_notified "did not commit"
expect_not_notified "Update successful"
expect_marker
ok "reported the lock and still collected"

case="19 marker argument"
reset
alt=$work/alt-marker
alt_switch=$work/alt-switch.sh
export T_SWITCH_HELPER="$alt_switch"
run "$alt" "$alt_switch"
export T_SWITCH_HELPER="$switch_helper"
expect_status 0
[ -s "$alt" ] || fail "the argument was not used as the marker"
[ ! -e "$marker" ] || fail "the fallback was used despite the argument"
ok "honoured the marker and helper paths the unit passes"

case="20 no deploy wrapper"
reset
mv "$tree/deploy-system" "$work/deploy-system.gone"
run
mv "$work/deploy-system.gone" "$tree/deploy-system"
expect_status 1
expect_calls ""
expect_no_marker
ok "exited before touching the network, wrote no marker"

case="21 earlier conflicts"
reset
export T_PULL=0
: >"$T_UNMERGED"
run
expect_status 1
expect_calls "$tail_calls"
expect_notified "Unmerged paths from an earlier pull"
expect_marker
ok "stopped before the pull and the switches, still collected"

case="22 killed mid-run"
reset
export T_PULL=term
run
expect_status 143
expect_calls "git fetch
git merge-base
git pull"
expect_marker
ok "the exit trap asked for the root collection anyway"

case="23 self update"
reset
export T_SELF_UPDATE=1
run
expect_status 0
expect_calls "$pull_full
git fetch
git merge-base
git submodule update
nix flake lock
nix flake update
t3code
sudo switch
$home_calls
$tail_calls
new copy"
expect_output "handing over to the new copy"
expect_marker
ok "reran the copy the pull wrote, whose new line ran, and finished there"

echo "all cases passed"
