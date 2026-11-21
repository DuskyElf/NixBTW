#!/usr/bin/env bash
# Creates deploy-system/ for a public-only checkout and locks it to the current
# channel tips. The real wrapper is private; lib/deploy/deploy-system.nix is its
# public recipe.
#
# A clone has neither deploy-system/ nor its lock, both gitignored: on the
# laptop the directory is restored from the private repo, and this script is how
# a public-only checkout gets an equivalent. The wrapper is what the machines
# switch with, so nothing rebuilds until one exists.
#
# Take the tree with its submodules. The flake reads apps/nvim/neovimBTW and
# apps/wallpaper/wallpaper-guardian as path inputs, so clone
# https://github.com/DuskyElf/NixBTW with --recurse-submodules. A checkout that
# predates their move under apps/ needs `git submodule sync --recursive` and
# then `git submodule update --init` after pulling, or those inputs are empty
# directories and the lock fails.
#
# Usage: lib/deploy/bootstrap.sh
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
deploy="$root/deploy-system"

if [ -e "$deploy/flake.nix" ]; then
  echo "bootstrap-deploy: $deploy/flake.nix already exists, leaving it alone" >&2
  echo "bootstrap-deploy: run 'nix flake update' there to move the lock" >&2
  exit 0
fi

mkdir -p "$deploy"
sed "s|@ROOT@|$root|g" "$root/lib/deploy/deploy-system.nix" > "$deploy/flake.nix"

# Nix ignores a flake file inside a git repo unless it is tracked. A nested
# repo, like the private wrapper, keeps deploy-system/ out of the parent index.
if [ ! -e "$deploy/.git" ]; then
  git -C "$deploy" init -q
fi
git -C "$deploy" add flake.nix
git -C "$deploy" -c user.name="deploy-bootstrap" -c user.email="deploy-bootstrap@localhost" \
  commit -q -m "deploy wrapper" || true

echo "bootstrap-deploy: locking $deploy"
nix flake lock "$deploy" --allow-dirty-locks

git -C "$deploy" add flake.lock
git -C "$deploy" -c user.name="deploy-bootstrap" -c user.email="deploy-bootstrap@localhost" \
  commit -q -m "deploy lock" || true

echo
echo "deploy lock written to $deploy/flake.lock"
echo "rebuild with:"
echo "  $root/apps/home-switch/hm-switch.sh"
echo "  sudo nixos-rebuild switch --no-write-lock-file --flake $deploy#<host> --override-input my-dotfiles path:$root --cores <cores>"
echo "    (<host> is the hosts/ directory name and <cores> is that host's"
echo "     dailyUpdate.cores: 16 on the laptop, 2 on the homelab. The raw form is"
echo "     for the first switch; after it, sudo /usr/local/sbin/nixos-switch.sh is"
echo "     what the daily run calls.)"
