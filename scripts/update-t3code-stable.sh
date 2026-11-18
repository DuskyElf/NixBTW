#!/usr/bin/env bash
# Moves pkgs/t3code/lock.nix to upstream's latest stable release tag.
#
# Runs from scripts/daily-update.sh, between `nix flake update` and the
# home-manager switch:
#   1. resolve the stable tag through the GitHub releases API, then the tag to
#      a commit
#   2. rewrite the lock with the new tag and rev and a placeholder hash for
#      each of the three fixed outputs
#   3. build the package through the deploy wrapper's nixpkgs pins, and each
#      time nix reports a fixed-output hash mismatch, write the hash it reports
#      and build again
#   4. commit the lock
#
# The releases/latest endpoint only ever serves a stable release: GitHub
# excludes drafts and prereleases from it by definition. The tag is still
# checked against the stable vX.Y.Z shape before use, so a nightly, preview,
# or mobile build tag can never move the pin even if the endpoint ever served
# one. A tag older than the locked one is refused too: the endpoint orders by
# publish date, so a re-published older patch would otherwise move the pin
# backwards. Either refusal keeps the old pin and exits 0, same as a tag that
# does not build.
#
# The rev is reconciled from the tag on every run, not just when the tag
# moves: a kill between the tag and rev writes used to leave tag=new with
# rev=old, and the next run then built the old commit while committing it as
# the new tag. A rev that disagrees with the tag is rewritten with placeholder
# hashes and relearned, same as a fresh tag.
#
# Every run builds, including one where the tag has not moved. A cached pin
# costs a couple of seconds and proves the lock still builds: a hash that
# nixpkgs invalidated under a fixed rev shows up here as a mismatch instead of
# failing the switch later. That is also why a tag bump relearns every hash
# rather than keeping the old pnpm and cargo ones as guesses. A guess that
# still resolves to a store path nix already has is reused without a mismatch,
# and the build then dies inside t3code-unwrapped with
# ERR_PNPM_NO_OFFLINE_TARBALL, which reports no hash to learn from.
#
# Every way out other than a finished build puts the previous lock back, so the
# switch never sees a half-written pin and an interrupted run cannot wedge it.
# A build failure (nixpkgs changed the recipe under us, or the tag is broken)
# restores the previous lock and exits 0, so the old T3 keeps working and the
# rest of the update still runs. Run it by hand to skip the wait for 08:30.
set -euo pipefail

DOTFILES=${DOTFILES:-/home/duskyelf/dotfiles}
DEPLOY=${DEPLOY:-/home/duskyelf/dotfiles/deploy-system}
REMOTE=https://github.com/pingdotgg/t3code
RELEASE_API=https://api.github.com/repos/pingdotgg/t3code/releases/latest
LOCK=$DOTFILES/pkgs/t3code/lock.nix
PKG=$DOTFILES/pkgs/t3code/default.nix
FAKE=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
HASHES=(srcHash pnpmDepsHash cargoHash)

notify() { command -v notify-send >/dev/null && notify-send "$@" || true; }

lock_value() {
  if [ -f "$LOCK" ]; then sed -n "s/^  $1 = \"\(.*\)\";$/\1/p" "$LOCK"; fi
}

# Writes through a sibling file and renames, so a kill can never leave a
# truncated lock for the next run to trust.
write_lock() {
  cat > "$LOCK.new"
  mv -f "$LOCK.new" "$LOCK"
}

set_lock_value() { sed -i "s|^  $1 = \".*\";\$|  $1 = \"$2\";|" "$LOCK"; }

# Builds the package exactly the way the home switch will: the deploy
# wrapper's lock decides nixpkgs-unstable-small, while the package itself is
# read from the live tree, so an uncommitted lock file still counts.
build_pkg() {
  nix build --no-link --impure --cores "${CORES:-4}" --expr "
    let
      deploy = builtins.getFlake \"path:$DEPLOY\";
      pkgs = deploy.inputs.nixpkgs-unstable-small.legacyPackages.x86_64-linux;
    in
    import $PKG { inherit pkgs; }
  "
}

# Which of the three hashes a failed fixed-output derivation belongs to.
classify() {
  case "$1" in
    *-source.drv) echo srcHash ;;
    *-pnpm-deps.drv) echo pnpmDepsHash ;;
    *vendor*.drv) echo cargoHash ;;
    *) echo "" ;;
  esac
}

# Every fixed-output hash mismatch in a build log, as "drv hash" lines. The
# apostrophes around the derivation path are dropped first so the pattern stays
# readable. nix prints one block per mismatched output, sometimes several in one
# log:
#   error: hash mismatch in fixed-output derivation '/nix/store/x-source.drv':
#            specified: sha256-old
#               got:    sha256-new
# `got:` is anchored to the start of the line so nixpkgs' own advice text
# ("3. Copy the 'got: sha256-' value back...") is not read as a hash.
mismatches() {
  tr -d "'" | awk '
    /in fixed-output derivation / {
      drv = $0
      sub(/.*in fixed-output derivation /, "", drv)
      sub(/:.*/, "", drv)
      next
    }
    /^[[:space:]]*got:[[:space:]]*sha256-/ {
      got = $0
      sub(/^[[:space:]]*got:[[:space:]]*/, "", got)
      sub(/[^A-Za-z0-9+\/=-].*/, "", got)
      if (drv != "") print drv, got
      drv = ""
    }
  '
}

# curl is bare on purpose: the timer inherits the user manager PATH, whose
# trailing /run/current-system/sw/bin entry links the system curl, git, and
# nix, the same PATH the daily switch already relies on for bare nix and git.
release_json=$(curl -fsSL "$RELEASE_API") || {
  echo "t3code: could not fetch the latest stable release"
  exit 1
}
# Parse from the variable, not the pipe: with no `head` in any pipeline, a
# reader closing the pipe early cannot SIGPIPE-fail the run under pipefail.
# The match quits after the first tag_name, which is the only one present.
tag=$(printf '%s\n' "$release_json" | sed -n '/"tag_name"/{s/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q}')
if [ -z "${tag:-}" ]; then
  echo "t3code: could not resolve the latest stable release"
  exit 1
fi

old_tag=$(lock_value tag)
old_rev=$(lock_value rev)

# Structural guard on top of the endpoint: only a plain vX.Y.Z tag moves the
# pin, so nightly, preview, and mobile build tags are never candidates no
# matter how new they are.
if [[ ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "t3code: refusing non-stable tag $tag, keeping ${old_tag:-none}"
  notify -u normal "T3 Code update skipped" "refusing non-stable tag $tag; still on ${old_tag:-none}"
  exit 0
fi

# A tag object and a commit share the ref name, so ask for both and prefer the
# peeled commit. A lightweight tag answers with one line and that line is the
# commit already.
ls_remote=$(git ls-remote "$REMOTE" "refs/tags/$tag" "refs/tags/$tag^{}")
rev=$(printf '%s\n' "$ls_remote" | awk '$2 ~ /\^\{\}$/ { peeled = $1 } $2 !~ /\^\{\}$/ { plain = $1 } END { if (peeled != "") print peeled; else print plain }')
if [ -z "${rev:-}" ]; then
  echo "t3code: could not resolve tag $tag"
  exit 1
fi

# The endpoint orders by publish date, so a re-published older patch would
# move the pin backwards. Refuse a tag that sorts older than the locked one.
# sort -C checks the order without printing, so no reader can close a pipe.
if [ -n "${old_tag:-}" ] && [ "$tag" != "$old_tag" ] \
  && ! printf '%s\n%s\n' "$old_tag" "$tag" | sort -V -C 2>/dev/null; then
  echo "t3code: stable $tag is older than $old_tag, keeping the pin"
  notify -u normal "T3 Code update skipped" "stable $tag is older than $old_tag; still on $old_tag"
  exit 0
fi

built=0
backup=$(mktemp)
if [ -f "$LOCK" ]; then cp "$LOCK" "$backup"; fi

# Any exit that is not a finished build puts the lock back, so an interrupted
# run cannot leave a placeholder behind for the switch to trip over.
restore() {
  if [ "$built" -ne 1 ]; then
    if [ -s "$backup" ]; then
      write_lock < "$backup"
    else
      rm -f "$LOCK" "$LOCK.new"
      git -C "$DOTFILES" checkout -- pkgs/t3code/lock.nix 2>/dev/null || true
    fi
  fi
  rm -f "$backup"
}
trap restore EXIT
trap 'exit 130' INT TERM

# No previous lock at all: start from the header plus placeholders so the first
# build can tell us every hash.
if [ ! -s "$backup" ]; then
  write_lock <<EOF
# Stable release tag of pingdotgg/t3code plus the fixed-output hashes for it.
# Rewritten by scripts/update-t3code-stable.sh; there is no reason to edit by hand.
{
  tag = "$tag";
  rev = "$rev";
  srcHash = "$FAKE";
  pnpmDepsHash = "$FAKE";
  cargoHash = "$FAKE";
}
EOF
fi

# Locks written before the tag field existed have no tag line for the writes
# below to match. Rewrite the header atomically around the kept values; the
# reconcile then sees the tag as changed and relearns the hashes.
if [ -f "$LOCK" ] && ! grep -q '^  tag = ' "$LOCK"; then
  kept_rev=$(lock_value rev)
  kept_src=$(lock_value srcHash)
  kept_pnpm=$(lock_value pnpmDepsHash)
  kept_cargo=$(lock_value cargoHash)
  write_lock <<EOF
# Stable release tag of pingdotgg/t3code plus the fixed-output hashes for it.
# Rewritten by scripts/update-t3code-stable.sh; there is no reason to edit by hand.
{
  tag = "";
  rev = "$kept_rev";
  srcHash = "$kept_src";
  pnpmDepsHash = "$kept_pnpm";
  cargoHash = "$kept_cargo";
}
EOF
fi

# The rev is reconciled from the tag on every run, not just when the tag
# moves. A tag move resets all three hashes to placeholders so they are
# relearned, never trusted; a rev that disagrees with its tag gets the same
# treatment, which also repairs a kill that landed between the two writes.
if [ "$(lock_value tag)" != "$tag" ]; then
  echo "t3code: stable ${old_tag:-none} -> $tag"
  set_lock_value tag "$tag"
  set_lock_value rev "$rev"
  # Force every hash instead of keeping the old ones as guesses. The price is
  # one extra pnpm store fetch and cargo vendor per bump, worth it against a pin
  # that stops moving without saying so.
  for key in "${HASHES[@]}"; do set_lock_value "$key" "$FAKE"; done
elif [ "$(lock_value rev)" != "$rev" ]; then
  echo "t3code: stable $tag rev ${old_rev:0:7} -> ${rev:0:7}, relearning hashes"
  set_lock_value rev "$rev"
  for key in "${HASHES[@]}"; do set_lock_value "$key" "$FAKE"; done
fi

for _ in 1 2 3 4 5 6; do
  if log=$(build_pkg 2>&1); then
    built=1
    break
  fi
  changed=0
  while read -r drv got; do
    key=$(classify "$drv")
    [ -n "$key" ] || continue
    [ "$(lock_value "$key")" = "$got" ] && continue
    set_lock_value "$key" "$got"
    # Read back: a value the lock cannot hold would otherwise be re-learned
    # every iteration and spin the whole loop.
    if [ "$(lock_value "$key")" != "$got" ]; then
      echo "t3code: cannot write $key into the lock"
      changed=0
      break
    fi
    echo "t3code: $key = $got"
    changed=1
  done < <(mismatches <<<"$log")
  # No hash moved, so this failure is not one the loop can fix.
  [ "$changed" -eq 1 ] || break
done

if [ "$built" -ne 1 ]; then
  echo "t3code: stable $tag (${rev:0:7}) does not build, keeping ${old_tag:-none}"
  printf '%s\n' "$log" | tail -40
  notify -u normal "T3 Code update skipped" "stable $tag does not build; still on ${old_tag:-none}"
  exit 0
fi

# An unchanged pin builds from the store and has nothing to commit.
if [ -n "$(git -C "$DOTFILES" status --porcelain -- pkgs/t3code/lock.nix)" ]; then
  git -C "$DOTFILES" add pkgs/t3code/lock.nix
  git -C "$DOTFILES" commit -q --no-gpg-sign -m "chore(t3code): $tag" \
    -- pkgs/t3code/lock.nix 2>/dev/null || true
  echo "t3code: stable $tag built"
else
  echo "t3code: stable $tag is current and builds"
fi
