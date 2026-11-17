#!/usr/bin/env bash
# Fast home-manager switch.
#
#   hm-switch.sh           build and activate the current tree
#   hm-switch.sh --force   activate even if that generation is already active
#
# `home-manager switch` evaluates the configuration twice (the generation, then
# its news feed) and repeats the whole evaluation on every run even when
# nothing changed. Evaluation is ~20s of single-core work and is the entire
# cost of a rebuild. This script keys each generation by the content of the
# tree, so a tree it has already built costs a directory hash and one file
# read, with no nix invocation at all.
#
# The key covers every entry under the repo (mode, symlink target and file
# bytes) except .git, .tmp and result links, deploy-system/flake.lock included.
# Nothing in the tree reads git metadata (no self.rev, no dirtyRev), so the
# generation is a pure function of those bytes and an equal key means an equal
# generation. A key whose derivation or output the GC collected falls back to a
# fresh evaluation.
#
# `activated` records the generation whose activation finished. The profile is
# moved before the activation script runs, so a profile pointing at a
# generation only means one was attempted; an activation that died (power loss,
# disk full, killed unit) is retried by the next run instead of skipped. Pass
# --force after `home-manager test`, which activates without moving the profile.
#
# The tree is passed as `path:`, not `git+file:`, so untracked files count: a
# new module works before `git add`. `path:` copies the whole repo into the
# store, .git included, which is why this hashes the tree itself instead of
# relying on the flake's fingerprint.
set -euo pipefail

dots=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
deploy=$dots/deploy-system
state=${XDG_STATE_HOME:-$HOME/.local/state}
cache_dir=$state/hm-switch
cache=$cache_dir/drv-cache
link=$cache_dir/generation
activated=$cache_dir/activated
attr="$(id -un)@$(hostname -s)"

# The profile this moves has to be the one home-manager moves: it uses the XDG
# directory only when it already exists, and the per-user store directory
# otherwise.
if [ -d "$state/nix/profiles" ]; then
  profile=$state/nix/profiles/home-manager
elif [ -d "/nix/var/nix/profiles/per-user/$(id -un)" ]; then
  profile=/nix/var/nix/profiles/per-user/$(id -un)/home-manager
else
  echo "${0##*/}: no profile directory; use the home-manager command in AGENTS.md" >&2
  exit 1
fi

usage() {
  echo "usage: ${0##*/} [--force]" >&2
  exit 2
}

force=
case $# in
  0) ;;
  1)
    case $1 in
      -f | --force) force=1 ;;
      *) usage ;;
    esac
    ;;
  *) usage ;;
esac

[ -d "$deploy" ] || {
  echo "${0##*/}: no deploy wrapper at $deploy" >&2
  exit 1
}
mkdir -p "$cache_dir"

# The timer and a hand-run switch must not interleave profile moves or the
# cache rewrite.
exec 9>"$cache_dir/lock"
flock -w 600 9 || {
  echo "${0##*/}: another switch is running" >&2
  exit 1
}

tree_key() {
  (
    cd -- "$dots" || exit 1
    {
      find . \( -name .git -o -name .tmp -o -name result \) -prune -o -type f -print0 |
        LC_ALL=C sort -z | xargs -0 sha256sum
      # Modes and symlink targets are not in the bytes above, and the store
      # copy keeps them, so an executable bit flip must change the key too.
      find . \( -name .git -o -name .tmp -o -name result \) -prune -o \
        -printf '%m %y %l\t%p\n' | LC_ALL=C sort
    } | sha256sum
  ) | cut -d' ' -f1
}

# Nix explains the modified lock file it declines to write while an input is
# overridden. Every override prints it, and it says nothing about the build.
drop_lock_warning() {
  awk '
    /^warning: not writing modified lock file/ { skip = 1; next }
    skip && (/^[[:space:]]/ || /^•/) { next }
    { skip = 0; print }
  '
}

evaluate() {
  echo "${0##*/}: evaluating configuration" >&2
  nix eval --raw "$deploy#homeConfigurations.\"$attr\".activationPackage.drvPath" \
    --override-input my-dotfiles "path:$dots" 2> >(drop_lock_warning >&2)
}

# True when this generation is both the one the profile points at and the one
# whose activation completed.
is_active() {
  [ "$(readlink -f -- "$profile")" = "$1" ] &&
    [ "$(cat -- "$activated" 2>/dev/null)" = "$1" ]
}

key=$(tree_key)
drv= out=
if [ -f "$cache" ]; then
  entry=$(awk -v k="$key" '$1 == k { print $2, $3; exit }' "$cache")
  drv=${entry%% *}
  [ "$entry" = "$drv" ] || out=${entry#* }
fi

# The recorded output is in the store and its activation finished: nothing to
# build, nothing to activate, not even a nix call.
if [ -z "$force" ] && [ -n "$out" ] && [ -e "$out" ] && is_active "$out"; then
  echo "${0##*/}: ${out##*/} is already active"
  exit 0
fi

# `$drv^*` is the installable that means "every output of this derivation";
# a bare .drv path builds the derivation file itself. --out-link (rather than
# --print-out-paths) roots a path built here across the activation below; a
# reused output is already in the store and is activated within microseconds.
generation=
if [ -n "$out" ] && [ -e "$out" ]; then
  generation=$out
elif [ -n "$drv" ] && [ -e "$drv" ]; then
  if nix build --out-link "$link" "$drv^*" 2>/dev/null; then
    generation=$(readlink -f -- "$link")
  else
    echo "${0##*/}: recorded derivation did not build, re-evaluating" >&2
  fi
fi
if [ -z "$generation" ]; then
  drv=$(evaluate)
  nix build --out-link "$link" "$drv^*"
  generation=$(readlink -f -- "$link")
fi

# A legacy activation script updates the profile itself, which is not what the
# three lines at the bottom do.
if [ ! -e "$generation/gen-version" ]; then
  echo "${0##*/}: ${generation##*/} has no gen-version; use the home-manager command in AGENTS.md" >&2
  exit 1
fi

# One line per tree, newest last, trimmed so the file stays small across GCs.
# An edit landing before nix copies the tree would otherwise be recorded against
# a generation built from the newer bytes, so the key is checked again and a
# tree that moved during the build is simply not cached. Edit-and-revert inside
# that window is the one order this cannot see, and it costs at most one stale
# generation for a tree the user returned to.
if [ "$key" = "$(tree_key)" ]; then
  tmp=$(mktemp "$cache_dir/cache.XXXXXX")
  {
    awk -v k="$key" '$1 != k' "$cache" 2>/dev/null || true
    echo "$key $drv $generation"
  } | tail -n 50 > "$tmp"
  mv "$tmp" "$cache"
else
  echo "${0##*/}: the tree changed during the build, not caching it" >&2
fi

if [ -z "$force" ] && is_active "$generation"; then
  echo "${0##*/}: ${generation##*/} is already active"
  exit 0
fi

echo "${0##*/}: activating ${generation##*/}"
nix-env --profile "$profile" --set "$generation"
"$generation/activate" --driver-version 1
printf '%s\n' "$generation" > "$activated"
