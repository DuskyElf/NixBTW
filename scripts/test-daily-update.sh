#!/usr/bin/env bash
# test-daily-update: deterministic checks for scripts/daily-update.sh.
#
# The script runs in a fake tree. Its three sibling scripts (T3 Code pin,
# hm-switch, projects) are stubs that check the environment they are handed and
# record their call, and nix, nix-collect-garbage, git, curl, notify-send and
# sleep are shims first in PATH. The sleep shim does nothing, so the 60-probe
# network loop is free, and the collection shim refuses to run once the marker
# exists, which is what proves the collection comes first. Nothing here touches
# the real wrapper, store, network or notification daemon.
#
# Cases:
#   1. happy path      update, T3 pin, switch, commit, devshell pin, collection
#   2. network wait    two failed probes, then an answer: the run proceeds
#   3. no network      sixty failed probes: critical notify, no nix call,
#                      the collection still runs, exit 1
#   4. flake update    fails: no T3 pin, no switch, collection still runs, exit 1
#   5. T3 pin          fails: the run carries on to the switch
#   6. switch fails    critical notify, no commit, collection still runs, exit 1
#   7. lock unchanged  nothing is committed
#   8. collection      fails: critical notify, marker still written, exit 1
#   9. devshell pin    fails: the collection still runs
#  10. commit fails    critical notify, collection still runs, exit 1
#  11. marker argument the path the unit passes is the one written
#  12. no wrapper      exits before the network wait, nothing recorded
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/daily-update.sh
mkdir -p -- "$(dirname -- "$here")/.tmp"
work=$(mktemp -d "$(dirname -- "$here")/.tmp/test-daily-update.XXXXXX")
trap 'rm -rf "$work"' EXIT

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
mkdir -p "$tree/scripts" "$tree/deploy-system" "$bin" "$home"
cp -- "$script" "$tree/scripts/daily-update.sh"
under_test=$tree/scripts/daily-update.sh
marker=$home/.local/state/daily-update/gc-request

# Siblings the script drives. Each checks what the script passes it, records
# the call, then obeys its switch.
cat >"$tree/scripts/update-t3code-stable.sh" <<'STUB'
#!/usr/bin/env bash
[ "${DOTFILES:-}" = "$T_TREE" ] || { echo "bad DOTFILES=${DOTFILES:-}" >&2; exit 4; }
[ "${DEPLOY:-}" = "$T_TREE/deploy-system" ] || { echo "bad DEPLOY=${DEPLOY:-}" >&2; exit 4; }
printf 't3code\n' >> "$T_CALLS"
exit "${T_T3CODE:-0}"
STUB
cat >"$tree/scripts/hm-switch.sh" <<'STUB'
#!/usr/bin/env bash
[ "${NIX_CONFIG:-}" = "cores = 2" ] || { echo "bad NIX_CONFIG=${NIX_CONFIG:-}" >&2; exit 4; }
printf 'switch\n' >> "$T_CALLS"
exit "${T_SWITCH:-0}"
STUB
cat >"$tree/scripts/projects.sh" <<'STUB'
#!/usr/bin/env bash
printf 'projects %s\n' "$*" >> "$T_CALLS"
exit "${T_PIN:-0}"
STUB
chmod +x "$tree/scripts/update-t3code-stable.sh" "$tree/scripts/hm-switch.sh" \
  "$tree/scripts/projects.sh"

cat >"$bin/nix" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "flake update nixpkgs nixpkgs-unstable-small zen-browser" ] || {
  echo "bad nix arguments: $*" >&2
  exit 4
}
printf 'nix flake update\n' >> "$T_CALLS"
exit "${T_FLAKE:-0}"
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
cat >"$bin/git" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
[ "${args[0]:-}" = "-C" ] || { echo "git without -C: $*" >&2; exit 4; }
[ "${args[1]:-}" = "$T_DEPLOY" ] || { echo "git -C ${args[1]:-}, wanted $T_DEPLOY" >&2; exit 4; }
args=("${args[@]:2}")
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
  *) echo "unexpected git call: $*" >&2; exit 4 ;;
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
export T_CALLS="$work/calls" T_NOTIFY="$work/notify" T_CURL_COUNT="$work/curl-count"

reset() {
  : >"$T_CALLS"
  : >"$T_NOTIFY"
  rm -f "$T_CURL_COUNT"
  rm -rf "$home/.local/state"
  mkdir -p "$home"
  export T_FLAKE=0 T_T3CODE=0 T_SWITCH=0 T_PIN=0 T_GC=0 T_COMMIT=0
  export T_CURL_FAILS=0 T_LOCK_CHANGED=1
}

run() {
  rc=0
  "$under_test" "$@" >"$work/out" 2>&1 || rc=$?
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

expect_marker() {
  [ -s "$marker" ] || fail "marker not written"
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$marker" ||
    fail "marker does not hold a date: $(cat -- "$marker")"
}

expect_no_marker() { [ ! -e "$marker" ] || fail "marker written"; }

case="1 happy path"
reset
run
expect_status 0
expect_calls "nix flake update
t3code
switch
git add
git diff
git commit
projects pin
nix-collect-garbage"
expect_notified "Update successful"
expect_marker
ok "update, pin, switch, commit, devshell pin, collection, marker"

case="2 network wait"
reset
export T_CURL_FAILS=2
run
expect_status 0
[ "$(probes)" = 3 ] || fail "probed $(probes) times, wanted 3"
expect_calls "nix flake update
t3code
switch
git add
git diff
git commit
projects pin
nix-collect-garbage"
ok "waited through two failed probes"

case="3 no network"
reset
export T_CURL_FAILS=100
run
expect_status 1
expect_calls "projects pin
nix-collect-garbage"
expect_notified "No network after 10 minutes"
expect_marker
[ "$(probes)" = 60 ] || fail "probed $(probes) times, wanted 60"
ok "gave up after 60 probes, skipped the update, still collected"

case="4 flake update fails"
reset
export T_FLAKE=1
run
expect_status 1
expect_calls "nix flake update
projects pin
nix-collect-garbage"
expect_notified "Failed to update flakes"
expect_not_notified "Update successful"
expect_marker
ok "skipped the pin and the switch, still collected"

case="5 T3 pin fails"
reset
export T_T3CODE=1
run
expect_status 0
expect_calls "nix flake update
t3code
switch
git add
git diff
git commit
projects pin
nix-collect-garbage"
expect_notified "Update successful"
ok "carried on to the switch with the previous pin"

case="6 switch fails"
reset
export T_SWITCH=1
run
expect_status 1
expect_calls "nix flake update
t3code
switch
projects pin
nix-collect-garbage"
expect_notified "Failed to switch configuration"
expect_not_notified "Update successful"
expect_marker
ok "skipped the commit but still pinned and collected"

case="7 lock unchanged"
reset
export T_LOCK_CHANGED=0
run
expect_status 0
expect_calls "nix flake update
t3code
switch
git add
git diff
projects pin
nix-collect-garbage"
expect_notified "Update successful"
ok "left the commit out"

case="8 collection fails"
reset
export T_GC=1
run
expect_status 1
expect_calls "nix flake update
t3code
switch
git add
git diff
git commit
projects pin
nix-collect-garbage"
expect_notified "Store collection failed"
expect_marker
ok "reported the failure and still asked for the root half"

case="9 devshell pin fails"
reset
export T_PIN=1
run
expect_status 0
expect_calls "nix flake update
t3code
switch
git add
git diff
git commit
projects pin
nix-collect-garbage"
expect_notified "Update successful"
ok "collected anyway"

case="10 commit fails"
reset
export T_COMMIT=1
run
expect_status 1
expect_calls "nix flake update
t3code
switch
git add
git diff
git commit
projects pin
nix-collect-garbage"
expect_notified "did not commit"
expect_not_notified "Update successful"
expect_marker
ok "reported the lock and still collected"

case="11 marker argument"
reset
alt=$work/alt-marker
run "$alt"
expect_status 0
[ -s "$alt" ] || fail "the argument was not used as the marker"
[ ! -e "$marker" ] || fail "the fallback was used despite the argument"
ok "honoured the marker path the unit passes"

case="12 no deploy wrapper"
reset
mv "$tree/deploy-system" "$work/deploy-system.gone"
run
mv "$work/deploy-system.gone" "$tree/deploy-system"
expect_status 1
expect_calls ""
expect_no_marker
ok "exited before touching the network"

echo "all cases passed"
