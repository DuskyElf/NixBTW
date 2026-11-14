#!/usr/bin/env bash
# test-update-t3code-main: deterministic checks for scripts/update-t3code-main.sh.
#
# The script is driven against shims placed first in PATH: `nix` reports one
# hash mismatch per run in nix's own wording until the lock matches a truth
# file, and `git` serves a fixed main rev, records commits, and restores the
# committed lock on checkout. No network, no build, no real repo.
#
# Cases:
#   1. new rev           three hashes learned, lock committed
#   2. interrupted run   rev already at target, placeholder hash: repaired
#   3. up to date        early exit, no write, no commit
#   4. upstream break    lock restored byte for byte, exit 0
#   5. no lock yet       created from scratch with all three hashes
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/update-t3code-main.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() { echo "ok: $*"; }

mkdir -p "$work/bin" "$work/dotfiles/cli" "$work/deploy-system"
lock=$work/dotfiles/cli/t3code-main.lock.nix
truth=$work/truth.nix
head=$work/head.nix
commits=$work/commits
rev=$work/rev

cat > "$work/bin/nix" <<'SHIM'
#!/usr/bin/env bash
# Stand-in for `nix build --expr ...`: emit the first hash mismatch nix would
# report, exit 0 once all three hashes match the truth file.
set -euo pipefail

value() { sed -n "s/^  $1 = \"\(.*\)\";$/\1/p" "$2"; }

want_rev=$(value rev "$T3_TEST_TRUTH")
have_rev=$(value rev "$T3_TEST_LOCK")

if [ "$want_rev" = "broken" ]; then
  echo "error: Cannot build '/nix/store/66666666666666666666666666666666-t3code.drv'." >&2
  echo "       Reason: builder failed with exit code 1." >&2
  exit 1
fi

if [ "$want_rev" != "$have_rev" ]; then
  echo "error: shim: lock rev is $have_rev, expected $want_rev" >&2
  exit 1
fi

for key in srcHash pnpmDepsHash cargoHash; do
  case $key in
    srcHash) drv=/nix/store/00000000000000000000000000000000-source.drv ;;
    pnpmDepsHash) drv=/nix/store/11111111111111111111111111111111-t3code-unwrapped-pnpm-deps.drv ;;
    cargoHash) drv=/nix/store/22222222222222222222222222222222-t3code-resource-monitor-vendor.drv ;;
  esac
  want=$(value "$key" "$T3_TEST_TRUTH")
  have=$(value "$key" "$T3_TEST_LOCK")
  if [ "$want" != "$have" ]; then
    echo "error: hash mismatch in fixed-output derivation '$drv':" >&2
    echo "         specified: $have" >&2
    echo "            got:    $want" >&2
    echo "error: Cannot build '/nix/store/33333333333333333333333333333333-t3code-unwrapped.drv'." >&2
    exit 1
  fi
done
SHIM

cat > "$work/bin/git" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-C" ]; then shift 2; fi
case "${1:-}" in
  ls-remote)
    printf '%s\trefs/heads/main\n' "$(cat "$T3_TEST_REV")"
    ;;
  add) : ;;
  commit)
    printf '%s\n' "$*" >> "$T3_TEST_COMMITS"
    cp "$T3_TEST_LOCK" "$T3_TEST_HEAD"
    ;;
  checkout)
    if [ -s "$T3_TEST_HEAD" ]; then cp "$T3_TEST_HEAD" "$T3_TEST_LOCK"; fi
    ;;
  *)
    echo "shim git: unsupported invocation: $*" >&2
    exit 1
    ;;
esac
SHIM

printf '#!/bin/sh\nexit 0\n' > "$work/bin/notify-send"
chmod +x "$work/bin/nix" "$work/bin/git" "$work/bin/notify-send"

# Writes the lock shape the script reads and rewrites.
lockfile() {
  cat <<EOF
# Commit of pingdotgg/t3code main plus the fixed-output hashes for it.
# Rewritten by scripts/update-t3code-main.sh; there is no reason to edit by hand.
{
  rev = "$1";
  srcHash = "$2";
  pnpmDepsHash = "$3";
  cargoHash = "$4";
}
EOF
}

run() {
  PATH="$work/bin:$PATH" \
    DOTFILES="$work/dotfiles" DEPLOY="$work/deploy-system" CORES=1 \
    T3_TEST_LOCK="$lock" T3_TEST_TRUTH="$truth" T3_TEST_REV="$rev" \
    T3_TEST_HEAD="$head" T3_TEST_COMMITS="$commits" \
    "$script"
}

reset_case() {
  rm -f "$commits"
  : > "$commits"
}

# ---------------------------------------------------------------- case 1 ----
old=1111111111111111111111111111111111111111
new=2222222222222222222222222222222222222222
old_src=sha256-oldSrcOldSrcOldSrcOldSrcOldSrcOldSrcOldSrcOldSrc0=
old_pnpm=sha256-oldPnpmOldPnpmOldPnpmOldPnpmOldPnpmOldPnpmOldPnpm=
old_cargo=sha256-oldCargoOldCargoOldCargoOldCargoOldCargoOldCargoOldC=
new_src=sha256-newSrcNewSrcNewSrcNewSrcNewSrcNewSrcNewSrcNewSrc0=
new_pnpm=sha256-newPnpmNewPnpmNewPnpmNewPnpmNewPnpmNewPnpmNewPnpm=
new_cargo=sha256-newCargoNewCargoNewCargoNewCargoNewCargoNewCargoNewC=

reset_case
lockfile "$old" "$old_src" "$old_pnpm" "$old_cargo" > "$lock"
cp "$lock" "$head"
lockfile "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
printf '%s\n' "$new" > "$rev"

if ! out=$(run); then
  printf '%s\n' "$out" >&2
  fail "case 1: script exited non-zero"
fi
diff -u "$truth" "$lock" >/dev/null || {
  printf '%s\n' "$out" >&2
  fail "case 1: lock does not match truth"
}
[ "$(wc -l < "$commits")" -eq 1 ] || fail "case 1: expected exactly one commit"
grep -Fq "main ${old:0:7} -> ${new:0:7}" <<<"$out" || fail "case 1: rev bump not reported"
for hash in "$new_src" "$new_pnpm" "$new_cargo"; do
  grep -Fq "$hash" <<<"$out" || fail "case 1: learned hash not reported: $hash"
done
ok "case 1: new rev learns all three hashes and commits"

# ---------------------------------------------------------------- case 2 ----
# The reported bug: an earlier run bumped the rev and died before filling in
# srcHash. The next run must resume, not report "already at".
fake=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
reset_case
lockfile "$new" "$fake" "$old_pnpm" "$old_cargo" > "$lock"
cp "$lock" "$head"
if ! out=$(run); then
  printf '%s\n' "$out" >&2
  fail "case 2: script exited non-zero"
fi
if grep -Fq "already at" <<<"$out"; then
  fail "case 2: placeholder hash treated as finished work"
fi
diff -u "$truth" "$lock" >/dev/null || {
  printf '%s\n' "$out" >&2
  fail "case 2: interrupted lock was not repaired"
}
[ "$(wc -l < "$commits")" -eq 1 ] || fail "case 2: repaired lock was not committed"
ok "case 2: interrupted lock is repaired on the next run"

# ---------------------------------------------------------------- case 3 ----
reset_case
lockfile "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$lock"
cp "$lock" "$head"
out=$(run)
if ! grep -Fq "already at" <<<"$out"; then
  printf '%s\n' "$out" >&2
  fail "case 3: up-to-date lock did not take the early exit"
fi
if [ -s "$commits" ]; then fail "case 3: up-to-date lock was committed"; fi
diff -u "$truth" "$lock" >/dev/null || fail "case 3: up-to-date lock was rewritten"
ok "case 3: up-to-date lock exits without writing"

# ---------------------------------------------------------------- case 4 ----
# Upstream broke: the build fails with no hash mismatch to learn from. The lock
# must come back byte for byte and the script must still exit 0 so the rest of
# the daily update runs.
reset_case
lockfile "$old" "$old_src" "$old_pnpm" "$old_cargo" > "$lock"
cp "$lock" "$head"
lockfile broken "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
printf '%s\n' "$new" > "$rev"
cp "$lock" "$work/before.nix"
if ! out=$(run); then
  printf '%s\n' "$out" >&2
  fail "case 4: script exited non-zero on an upstream break"
fi
cmp -s "$work/before.nix" "$lock" || fail "case 4: lock was not restored"
if [ -s "$commits" ]; then fail "case 4: broken pin was committed"; fi
grep -Fq "does not build" <<<"$out" || fail "case 4: break not reported"
ok "case 4: broken upstream restores the previous lock"

# ---------------------------------------------------------------- case 5 ----
# First run on a checkout without the lock: everything has to be created.
reset_case
rm -f "$lock" "$head"
lockfile "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
if ! out=$(run); then
  printf '%s\n' "$out" >&2
  fail "case 5: script exited non-zero"
fi
diff -u "$truth" "$lock" >/dev/null || {
  printf '%s\n' "$out" >&2
  fail "case 5: lock was not created from scratch"
}
[ "$(wc -l < "$commits")" -eq 1 ] || fail "case 5: new lock was not committed"
ok "case 5: missing lock is created from scratch"

echo
echo "PASS: 5 cases"
