#!/usr/bin/env bash
# Move pkgs/t3code/server-lock.nix to upstream's latest stable release.
#
# The headless host installs the prebuilt Linux tarball, so this only resolves
# the tag and hashes the asset: no build, no vendor hashes. It refuses a tag
# that is not a plain vX.Y.Z or that sorts older than the locked one, and it
# leaves the lock alone when the asset is missing (a release whose uploads are
# still in flight).
#
# The hash is always re-downloaded and compared, even when the tag has not
# moved, so a half-written lock or a re-uploaded asset is repaired. The lock is
# written through a sibling file and renamed, so a kill cannot leave it
# truncated. It commits the change; pushing is the user's call, and the homelab
# only sees it after that push.
set -euo pipefail

DOTFILES=${DOTFILES:-$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)}
RELEASE_API=https://api.github.com/repos/pingdotgg/t3code/releases/latest
LOCK=$DOTFILES/pkgs/t3code/server-lock.nix

notify() { command -v notify-send >/dev/null && notify-send "$@" || true; }

lock_value() {
  if [ -f "$LOCK" ]; then sed -n "s/^  $1 = \"\(.*\)\";$/\1/p" "$LOCK"; fi
}

release_json=$(curl -fsSL --connect-timeout 10 --max-time 60 "$RELEASE_API") || {
  echo "t3code server: could not fetch the latest stable release"
  exit 1
}
tag=$(printf '%s\n' "$release_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
tag=${tag%%$'\n'*}
if [ -z "${tag:-}" ]; then
  echo "t3code server: could not resolve the latest stable release"
  exit 1
fi

old_tag=$(lock_value tag)
old_hash=$(lock_value hash)

if [[ ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "t3code server: refusing non-stable tag $tag, keeping ${old_tag:-none}"
  exit 0
fi

if [ -n "${old_tag:-}" ] && [ "$tag" != "$old_tag" ] \
  && ! printf '%s\n%s\n' "$old_tag" "$tag" | sort -V -C 2>/dev/null; then
  echo "t3code server: stable $tag is older than $old_tag, keeping the pin"
  exit 0
fi

version=${tag#v}
url="https://github.com/pingdotgg/t3code/releases/download/$tag/t3-$version-linux-x64.tar.gz"
# This repo's own .tmp, not the host's shared /tmp: a large asset written there
# can come back empty, which would hash as the empty file.
mkdir -p "$DOTFILES/.tmp"
tmp=$(mktemp "$DOTFILES/.tmp/t3-server.XXXXXX")
trap 'rm -f "$tmp" "$LOCK.new"' EXIT
# No -f: a 404 has to be told apart from a transport error. A missing asset
# means the release uploads are still in flight, so keep the pin and wait; a
# timeout, TLS failure or short body is a real error and must not be hidden.
http_code=$(curl -sSL -o "$tmp" -w '%{http_code}' \
  --connect-timeout 10 --max-time 600 --retry 2 --retry-connrefused \
  "$url") || {
  echo "t3code server: could not download the $tag tarball, keeping ${old_tag:-none}"
  exit 1
}
if [ "$http_code" = 404 ] || [ "$http_code" = 403 ]; then
  echo "t3code server: $tag has no linux-x64 tarball yet, keeping ${old_tag:-none}"
  notify -u normal "T3 Code server update skipped" "$tag has no linux-x64 tarball yet"
  exit 0
fi
if [ "$http_code" != 200 ] || [ ! -s "$tmp" ]; then
  echo "t3code server: HTTP $http_code or empty $tag tarball, keeping ${old_tag:-none}"
  exit 1
fi
hash=$(nix hash file "$tmp")

if [ "$tag" = "$old_tag" ] && [ "$hash" = "$old_hash" ]; then
  echo "t3code server: $tag is current"
  exit 0
fi

cat > "$LOCK.new" <<EOF
# The prebuilt Linux server tarball this repo's headless host installs, by
# release tag and fixed-output hash. Kept apart from ./lock.nix on purpose: the
# laptop's source pin moves every day and rebuilds there, while the homelab
# only takes a new server when this file moves, so a laptop tag bump cannot
# change what that host fetches. Bump it with ./update-server.sh.
{
  tag = "$tag";
  hash = "$hash";
}
EOF
mv -f "$LOCK.new" "$LOCK"

if [ "$(lock_value tag)" != "$tag" ] || [ "$(lock_value hash)" != "$hash" ]; then
  echo "t3code server: could not write $tag into the lock"
  exit 1
fi

if [ -n "$(git -C "$DOTFILES" status --porcelain -- pkgs/t3code/server-lock.nix)" ]; then
  git -C "$DOTFILES" add pkgs/t3code/server-lock.nix
  if ! git -C "$DOTFILES" commit -q --no-gpg-sign -m "chore(t3code): server $tag" \
    -- pkgs/t3code/server-lock.nix; then
    echo "t3code server: wrote $tag but could not commit it"
    exit 1
  fi
fi
echo "t3code server: $tag ($hash); push before the homelab switches"
