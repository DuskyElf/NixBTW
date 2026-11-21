#!/bin/sh
# Replace T3's downloaded chrome-headless-shell with a shim that execs the
# Nix Chromium. That download wants /lib64/ld-linux-x86-64.so.2, which NixOS
# does not have, so every spawn exits 127. T3 exposes no browser-path setting,
# and the path is pinned to the downloaded version, so the smallest local fix
# is to overwrite each download. T3 only stats the file, so a script satisfies
# it. A download that arrives after this ran is healed by the next home switch,
# or by running this script by hand.
set -eu
root="$HOME/.t3/tools/chrome-headless-shell"
chromium="$HOME/.nix-profile/bin/chromium"
[ -d "$root" ] && [ -x "$chromium" ] || exit 0

for bin in "$root"/*/*/chrome-headless-shell; do
  [ -f "$bin" ] || continue
  if head -c 2 "$bin" 2>/dev/null | grep -q '#!'; then
    continue
  fi
  printf '#!/bin/sh\nexec %s "$@"\n' "$chromium" > "$bin"
  chmod +x "$bin"
done
