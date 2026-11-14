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
# A lock holding a placeholder hash is an unfinished update, so a run that was
# interrupted while it was learning hashes resumes that work instead of
# reporting "already at". Every way out other than a finished build puts the
# previous lock back, so the switch never sees a half-written pin.
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
HASHES=(srcHash pnpmDepsHash cargoHash)

notify() { command -v notify-send >/dev/null && notify-send "$@" || true; }

lock_value() { sed -n "s/^  $1 = \"\(.*\)\";$/\1/p" "$LOCK" 2>/dev/null; }

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

# Every fixed-output hash mismatch in a build log, as "drv hash" lines. The
# apostrophes around the derivation path are dropped first so the pattern
# stays readable. nix prints one block per mismatched output:
#   error: hash mismatch in fixed-output derivation '/nix/store/x-source.drv':
#            specified: sha256-old
#               got:    sha256-new
mismatches() {
  tr -d "'" | awk '
    /in fixed-output derivation / {
      drv = $0
      sub(/.*in fixed-output derivation /, "", drv)
      sub(/:.*/, "", drv)
      next
    }
    /got: *sha256-/ {
      got = $0
      sub(/.*got: */, "", got)
      sub(/[^A-Za-z0-9+\/=-].*/, "", got)
      if (drv != "") print drv, got
      drv = ""
    }
  '
}

is_placeholder() {
  local value
  value=$(lock_value "$1")
  [ -z "$value" ] || [ "$value" = "$FAKE" ]
}

rev=$(git ls-remote "$REMOTE" refs/heads/main | cut -f1)
if [ -z "$rev" ]; then
  echo "t3code: could not resolve main"
  exit 1
fi

old_rev=$(lock_value rev || true)

# A placeholder hash means an earlier run stopped mid-update. Finish that even
# when the rev already matches, or the pin stays unbuildable forever.
unfinished=0
for key in "${HASHES[@]}"; do
  if is_placeholder "$key"; then unfinished=1; fi
done

if [ "$rev" = "$old_rev" ] && [ "$unfinished" -eq 0 ]; then
  echo "t3code: main is already at ${rev:0:7}"
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
      cp "$backup" "$LOCK"
    else
      rm -f "$LOCK"
      git -C "$DOTFILES" checkout -- cli/t3code-main.lock.nix 2>/dev/null || true
    fi
  fi
  rm -f "$backup"
}
trap restore EXIT
trap 'exit 130' INT TERM

# No previous lock at all: start from the comment header plus placeholders so
# the first build can tell us every hash.
if [ ! -s "$backup" ]; then
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

# A new rev always has a new source tarball; a wrong hash there is the cheapest
# way to make nix tell us the right one. The rev can already match when an
# earlier run was interrupted, in which case the lock keeps its current hashes
# and only the placeholders get filled in by the loop below.
if [ "$rev" != "$old_rev" ]; then
  echo "t3code: main ${old_rev:0:7} -> ${rev:0:7}"
  sed -i "s|^  rev = \".*\";\$|  rev = \"$rev\";|" "$LOCK"
  set_lock_value srcHash "$FAKE"
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
    echo "t3code: $key = $got"
    set_lock_value "$key" "$got"
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

git -C "$DOTFILES" add cli/t3code-main.lock.nix
git -C "$DOTFILES" commit -q --no-gpg-sign -m "chore(t3code): main ${rev:0:7}" \
  -- cli/t3code-main.lock.nix 2>/dev/null || true

echo "t3code: main ${rev:0:7} built"
