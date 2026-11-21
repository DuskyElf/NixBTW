#!/usr/bin/env bash
# Exercise apps/t3code/chrome-shim.sh against a fake HOME.
#
#     apps/t3code/test-chrome-shim.sh
#
# The script only reads $HOME, so a temporary home is enough to cover each
# branch: no download yet, no Chromium yet, a real download to replace, a
# download already shimmed, and a download that is already a script.
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/../.." && pwd)
shim=$repo/apps/t3code/chrome-shim.sh
home=$repo/.tmp/chrome-shim-test/home
bash_dir=$home/.t3/tools/chrome-headless-shell/linux64/157.0.8103.78
bin=$bash_dir/chrome-headless-shell

fails=0
check() {
  local name=$1
  shift
  if "$@"; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    fails=$((fails + 1))
  fi
}

cleanup() { rm -rf "$repo/.tmp/chrome-shim-test"; }
trap cleanup EXIT
cleanup
mkdir -p "$home/.nix-profile/bin"

check "no download and no Chromium exits 0" env HOME=$home "$shim"

mkdir -p "$bash_dir"
printf '\177ELF fake download\n' > "$bin"
chmod +x "$bin"
check "a missing Chromium leaves the download alone" \
  test "$(head -c 4 "$bin")" = "$(printf '\177ELF')"

printf '#!/bin/sh\necho chromium\n' > "$home/.nix-profile/bin/chromium"
chmod +x "$home/.nix-profile/bin/chromium"

check "a downloaded binary becomes a shim" env HOME=$home "$shim"
check "the shim execs the profile Chromium" \
  grep -qx "exec $home/.nix-profile/bin/chromium \"\$@\"" <(tail -n 1 "$bin")
check "the shim is executable" test -x "$bin"

cp "$bin" "$repo/.tmp/chrome-shim-test/once"
check "a second run changes nothing" env HOME=$home "$shim"
check "the shim stayed byte-identical" cmp "$bin" "$repo/.tmp/chrome-shim-test/once"

printf '#!/bin/sh\necho already here\n' > "$bin"
check "a download that is already a script is kept" env HOME=$home "$shim"
check "the existing script was not overwritten" grep -q "already here" "$bin"

if [ "$fails" -ne 0 ]; then
  echo
  echo "$fails failed"
  exit 1
fi
echo
echo "all chrome-shim checks passed"
