#!/usr/bin/env bash
# Creates deploy-system/ for a public-only checkout and locks it to the current
# channel tips. The real wrapper is private; scripts/deploy-system.nix is its
# public recipe.
#
# Usage: scripts/bootstrap-deploy.sh
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
deploy="$root/deploy-system"

if [ -e "$deploy/flake.nix" ]; then
  echo "bootstrap-deploy: $deploy/flake.nix already exists, leaving it alone" >&2
  echo "bootstrap-deploy: run 'nix flake update' there to move the lock" >&2
  exit 0
fi

mkdir -p "$deploy"
sed "s|@ROOT@|$root|g" "$root/scripts/deploy-system.nix" > "$deploy/flake.nix"

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
echo "  home-manager switch --flake $deploy --override-input my-dotfiles path:$root --cores 16"
echo "  sudo nixos-rebuild switch --flake $deploy --override-input my-dotfiles path:$root --cores 16"
