#!/usr/bin/env bash
# Moves cli/t3code-main.lock.nix to the tip of pingdotgg/t3code main.
#
# Runs from the daily flake auto-update, between `nix flake update` and the
# home-manager switch:
#   1. resolve main
#   2. rewrite the lock with the new rev, keeping the old pnpm and cargo hashes
#      as guesses (they only move when the lockfile or the rust side moves)
#   3. build the package through the deploy wrapper's nixpkgs pins, and each
#      time nix reports a fixed-output hash mismatch, write the hash it reports
#      and build again
#   4. commit the lock
#
# A build failure (nixpkgs changed the recipe under us, or main is broken)
# restores the previous lock and exits 0, so the old T3 keeps working and the
# rest of the update still runs. Run it by hand to skip the wait for 08:30.
set -euo pipefail

DOTFILES=${DOTFILES:-/home/duskyelf/dotfiles}
DEPLOY=${DEPLOY:-/home/duskyelf/dotfiles/deploy-system}
REMOTE=https://github.com/pingdotgg/t3code
LOCK=$DOTFILES/cli/t3code-main.lock.nix
PKG=$DOTFILES/cli/t3code-main.nix
FAKE=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

notify() { command -v notify-send >/dev/null && notify-send "$@" || true; }

lock_value() { sed -n "s/^  $1 = \"\(.*\)\";$/\1/p" "$LOCK"; }

set_lock_value() { sed -i "s|^  $1 = \".*\";\$|  $1 = \"$2\";|" "$LOCK"; }

# Builds the package exactly the way `home-manager switch` will: the deploy
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

rev=$(git ls-remote "$REMOTE" refs/heads/main | cut -f1)
if [ -z "$rev" ]; then
  echo "t3code: could not resolve main"
  exit 1
fi

old_rev=$(lock_value rev 2>/dev/null || true)
if [ "$rev" = "$old_rev" ]; then
  echo "t3code: main is already at ${rev:0:7}"
  exit 0
fi

echo "t3code: main ${old_rev:0:7} -> ${rev:0:7}"

backup=$(mktemp)
trap 'rm -f "$backup"' EXIT
[ -f "$LOCK" ] && cp "$LOCK" "$backup" || true

# Seed the rev and the src hash; a wrong src hash is the cheapest way to make
# nix tell us the right one.
if [ -s "$backup" ]; then
  cp "$backup" "$LOCK"
else
  cat > "$LOCK" <<EOF
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
sed -i "s|^  rev = \".*\";\$|  rev = \"$rev\";|" "$LOCK"
set_lock_value srcHash "$FAKE"

built=0
for _ in 1 2 3 4 5; do
  if log=$(build_pkg 2>&1); then
    built=1
    break
  fi
  drv=$(printf '%s\n' "$log" | sed -n "s/.*fixed-output derivation '\([^']*\)'.*/\1/p" | head -1)
  got=$(printf '%s\n' "$log" | sed -n 's/.*got: *\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' | head -1)
  key=$(classify "$drv")
  if [ -z "$key" ] || [ -z "$got" ]; then
    break
  fi
  echo "t3code: $key = $got"
  set_lock_value "$key" "$got"
done

if [ "$built" -ne 1 ]; then
  if [ -s "$backup" ]; then
    cp "$backup" "$LOCK"
  else
    # No previous lock to fall back to: take whatever git has committed.
    git -C "$DOTFILES" checkout -- cli/t3code-main.lock.nix 2>/dev/null || true
  fi
  echo "t3code: main ${rev:0:7} does not build, keeping ${old_rev:0:7}"
  printf '%s\n' "$log" | tail -40
  notify -u normal "T3 Code update skipped" "main ${rev:0:7} does not build; still on ${old_rev:0:7}"
  exit 0
fi

git -C "$DOTFILES" add cli/t3code-main.lock.nix
git -C "$DOTFILES" commit -q --no-gpg-sign -m "chore(t3code): main ${rev:0:7}" \
  -- cli/t3code-main.lock.nix 2>/dev/null || true

echo "t3code: main ${rev:0:7} built"
