#!/usr/bin/env bash
# Moves pkgs/t3code/lock.nix to the tip of pingdotgg/t3code main.
#
# Runs from the daily flake auto-update, between `nix flake update` and the
# home-manager switch:
#   1. resolve main
#   2. rewrite the lock with the new rev and a placeholder hash for each of the
#      three fixed outputs
#   3. build the package through the deploy wrapper's nixpkgs pins, and each
#      time nix reports a fixed-output hash mismatch, write the hash it reports
#      and build again
#   4. commit the lock
#
# Every run builds, including one where main has not moved. A cached pin costs
# a couple of seconds and proves the lock still builds: a hash that nixpkgs
# invalidated under a fixed rev shows up here as a mismatch instead of failing
# the switch later. That is also why a rev bump relearns every hash rather than
# keeping the old pnpm and cargo ones as guesses. A guess that still resolves to
# a store path nix already has is reused without a mismatch, and the build then
# dies inside t3code-unwrapped with ERR_PNPM_NO_OFFLINE_TARBALL, which reports
# no hash to learn from.
#
# Every way out other than a finished build puts the previous lock back, so the
# switch never sees a half-written pin and an interrupted run cannot wedge it.
# A build failure (nixpkgs changed the recipe under us, or main is broken)
# restores the previous lock and exits 0, so the old T3 keeps working and the
# rest of the update still runs. Run it by hand to skip the wait for 08:30.
set -euo pipefail

DOTFILES=${DOTFILES:-/home/duskyelf/dotfiles}
DEPLOY=${DEPLOY:-/home/duskyelf/dotfiles/deploy-system}
REMOTE=https://github.com/pingdotgg/t3code
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

rev=$(git ls-remote "$REMOTE" refs/heads/main | cut -f1)
if [ -z "$rev" ]; then
  echo "t3code: could not resolve main"
  exit 1
fi

old_rev=$(lock_value rev)

built=0
backup=$(mktemp)
if [ -f "$LOCK" ]; then cp "$LOCK" "$backup"; fi

# Any exit that is not a finished build puts the lock back, so an interrupted
# run cannot leave a placeholder behind for the switch to trip over.
restore() {
  if [ "$built" -ne 1 ]; then
    if [ -s "$backup" ]; then
      cp "$backup" "$LOCK.new" && mv -f "$LOCK.new" "$LOCK"
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
# Commit of pingdotgg/t3code main plus the fixed-output hashes for it.
# Rewritten by scripts/update-t3code-main.sh; there is no reason to edit by hand.
{
  rev = "$rev";
  srcHash = "$FAKE";
  pnpmDepsHash = "$FAKE";
  cargoHash = "$FAKE";
}
EOF
fi

if [ "$rev" != "$old_rev" ]; then
  echo "t3code: main ${old_rev:0:7} -> ${rev:0:7}"
  sed -i "s|^  rev = \".*\";\$|  rev = \"$rev\";|" "$LOCK"
  # Force every hash instead of keeping the old ones as guesses. The price is
  # one extra pnpm store fetch and cargo vendor per bump, worth it against a pin
  # that stops moving without saying so.
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
  echo "t3code: main ${rev:0:7} does not build, keeping ${old_rev:0:7}"
  printf '%s\n' "$log" | tail -40
  notify -u normal "T3 Code update skipped" "main ${rev:0:7} does not build; still on ${old_rev:0:7}"
  exit 0
fi

# An unchanged pin builds from the store and has nothing to commit.
if [ -n "$(git -C "$DOTFILES" status --porcelain -- pkgs/t3code/lock.nix)" ]; then
  git -C "$DOTFILES" add pkgs/t3code/lock.nix
  git -C "$DOTFILES" commit -q --no-gpg-sign -m "chore(t3code): main ${rev:0:7}" \
    -- pkgs/t3code/lock.nix 2>/dev/null || true
  echo "t3code: main ${rev:0:7} built"
else
  echo "t3code: main ${rev:0:7} is current and builds"
fi
