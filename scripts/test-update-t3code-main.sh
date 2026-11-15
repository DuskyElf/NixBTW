#!/usr/bin/env bash
# test-update-t3code-main: deterministic checks for scripts/update-t3code-main.sh.
#
# The script is driven against shims placed first in PATH: `nix` reports hash
# mismatches in nix's own wording until the lock matches a truth file, and `git`
# serves a fixed main rev, records commits, and restores the committed lock on
# checkout. No network, no build, no real repo.
#
# Cases:
#   1. new rev              three hashes learned, lock committed
#   2. new rev, one log     every mismatch in one log is harvested
#   3. interrupted lock     rev already at target with a placeholder: repaired
#   4. up to date           builds, reports current, writes nothing
#   5. upstream break       dirty lock restored, not the committed one, exit 0
#   6. no lock yet          created from scratch with all three hashes
#   7. SIGTERM mid-build    lock restored, exit 130
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

if [ ! -x "$script" ]; then
    fail "$script is missing or not executable"
fi

mkdir -p "$work/bin" "$work/dotfiles/cli" "$work/deploy-system"
lock=$work/dotfiles/cli/t3code-main.lock.nix
truth=$work/truth.nix
head=$work/head.nix
commits=$work/commits
builds=$work/builds
rev=$work/rev

cat > "$work/bin/nix" <<'SHIM'
#!/usr/bin/env bash
# Stand-in for `nix build --expr ...`: report the hash mismatches nix would
# report, exit 0 once all three match the truth file. T3_TEST_MULTI puts every
# mismatch in one log, T3_TEST_TERM signals the script mid-build.
set -euo pipefail

value() { sed -n "s/^  $1 = \"\(.*\)\";$/\1/p" "$2"; }

case " $* " in
    *" build "*"--expr"*) ;;
    *)
        echo "shim nix: unexpected arguments: $*" >&2
        exit 2
        ;;
esac

printf 'build\n' >> "$T3_TEST_BUILDS"

if [ -n "${T3_TEST_TERM:-}" ]; then
    # build_pkg runs in a command substitution, so the script is two levels up.
    target=$(ps -o ppid= -p "$PPID" | tr -d ' ')
    kill -TERM "$target"
    exit 1
fi

want_rev=$(value rev "$T3_TEST_TRUTH")
have_rev=$(value rev "$T3_TEST_LOCK")

if [ "$want_rev" = broken ]; then
    echo "error: Cannot build '/nix/store/66666666666666666666666666666666-t3code.drv'." >&2
    echo "       Reason: builder failed with exit code 1." >&2
    exit 1
fi
if [ "$want_rev" != "$have_rev" ]; then
    echo "shim nix: lock rev is $have_rev, truth is $want_rev" >&2
    exit 1
fi

failed=0
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
        echo "       Reason: 1 dependency failed." >&2
        echo "       3. Copy the 'got: sha256-' value back into the hash field" >&2
        failed=1
        if [ -z "${T3_TEST_MULTI:-}" ]; then exit 1; fi
    fi
done
[ "$failed" -eq 0 ] || exit 1
SHIM

cat > "$work/bin/git" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-C" ]; then
    [ "${2:-}" = "$T3_TEST_DOTFILES" ] || {
        echo "shim git: -C pointed at ${2:-nothing}, expected $T3_TEST_DOTFILES" >&2
        exit 1
    }
    shift 2
fi
case "${1:-}" in
    ls-remote)
        printf '%s\trefs/heads/main\n' "$(cat "$T3_TEST_REV")"
        ;;
    add)
        [ "${2:-}" = "cli/t3code-main.lock.nix" ] || {
            echo "shim git: add of ${2:-nothing}" >&2
            exit 1
        }
        ;;
    commit)
        printf '%s\n' "$*" >> "$T3_TEST_COMMITS"
        cp "$T3_TEST_LOCK" "$T3_TEST_HEAD"
        ;;
    status)
        cmp -s "$T3_TEST_LOCK" "$T3_TEST_HEAD" || echo " M cli/t3code-main.lock.nix"
        ;;
    checkout)
        # Only the no-previous-lock path reaches this.
        [ "${2:-}" = "--" ] || { echo "shim git: odd checkout: $*" >&2; exit 1; }
        [ -s "$T3_TEST_HEAD" ] && cp "$T3_TEST_HEAD" "$T3_TEST_LOCK"
        ;;
    *)
        echo "shim git: unsupported invocation: $*" >&2
        exit 1
        ;;
esac
SHIM

cat > "$work/bin/notify-send" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T3_TEST_NOTIFY"
SHIM

chmod +x "$work/bin/nix" "$work/bin/git" "$work/bin/notify-send"

hash() { printf 'sha256-%s=\n' "$1"; }

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

# Extra knobs are name=value arguments, handed to env so they are real
# assignments for the script.
run() {
    env PATH="$work/bin:$PATH" \
        DOTFILES="$work/dotfiles" DEPLOY="$work/deploy-system" CORES=1 \
        T3_TEST_DOTFILES="$work/dotfiles" T3_TEST_LOCK="$lock" \
        T3_TEST_TRUTH="$truth" T3_TEST_REV="$rev" T3_TEST_HEAD="$head" \
        T3_TEST_COMMITS="$commits" T3_TEST_BUILDS="$builds" \
        T3_TEST_NOTIFY="$work/notify" "$@" \
        "$script"
}

# Clears every fixture so a case cannot inherit state from the one before it.
reset_case() {
    : > "$commits"
    : > "$builds"
    : > "$work/notify"
    rm -f "$lock" "$truth" "$head" "$rev"
}

build_count() { wc -l < "$builds" | tr -d ' '; }

# ---------------------------------------------------------------- fixtures --
old=1111111111111111111111111111111111111111
new=2222222222222222222222222222222222222222
old_src=$(hash "OldSrc/with+base64chars0")
old_pnpm=$(hash "OldPnpm/with+base64chars")
old_cargo=$(hash "OldCargo/with+base64char")
new_src=$(hash "NewSrc/with+base64chars0")
new_pnpm=$(hash "NewPnpm/with+base64chars")
new_cargo=$(hash "NewCargo/with+base64char")
fake=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

# ---------------------------------------------------------------- case 1 ----
# A bump: every hash is a placeholder, so nix reports one mismatch at a time
# (three builds) and the fourth proves the pin.
reset_case
lockfile "$old" "$old_src" "$old_pnpm" "$old_cargo" > "$lock"
cp "$lock" "$head"
lockfile "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
printf '%s\n' "$new" > "$rev"

if ! out=$(run); then
    printf '%s\n' "$out" >&2
    fail "case 1: script exited non-zero"
fi
diff -u "$truth" "$lock" || fail "case 1: lock does not match truth"
grep -Fq "main ${old:0:7} -> ${new:0:7}" <<<"$out" || fail "case 1: rev bump not reported"
for value in "$new_src" "$new_pnpm" "$new_cargo"; do
    grep -Fq "$value" <<<"$out" || fail "case 1: learned hash not reported: $value"
done
[ "$(build_count)" -eq 4 ] || fail "case 1: expected 4 builds, saw $(build_count)"
[ "$(wc -l < "$commits")" -eq 1 ] || fail "case 1: expected exactly one commit"
grep -Fq -- "--no-gpg-sign" "$commits" || fail "case 1: commit is not signed off for the timer"
grep -Fq "chore(t3code): main ${new:0:7}" "$commits" || fail "case 1: commit subject is wrong"
ok "case 1: new rev learns all three hashes and commits"

# ---------------------------------------------------------------- case 2 ----
# Real nix can put several mismatches in one log. One build must learn all of
# them, so the second build is the validating one.
reset_case
lockfile "$old" "$old_src" "$old_pnpm" "$old_cargo" > "$lock"
cp "$lock" "$head"
lockfile "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
printf '%s\n' "$new" > "$rev"

if ! out=$(run T3_TEST_MULTI=1); then
    printf '%s\n' "$out" >&2
    fail "case 2: script exited non-zero"
fi
diff -u "$truth" "$lock" || fail "case 2: lock does not match truth"
[ "$(build_count)" -eq 2 ] || fail "case 2: expected 2 builds, saw $(build_count)"
ok "case 2: every mismatch in one log is harvested"

# ---------------------------------------------------------------- case 3 ----
# The reported bug: an earlier run bumped the rev and died before filling in
# srcHash. The next run must finish the pin instead of trusting the rev.
reset_case
lockfile "$new" "$fake" "$new_pnpm" "$new_cargo" > "$lock"
cp "$lock" "$head"
lockfile "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
printf '%s\n' "$new" > "$rev"

if ! out=$(run); then
    printf '%s\n' "$out" >&2
    fail "case 3: script exited non-zero"
fi
diff -u "$truth" "$lock" || fail "case 3: interrupted lock was not repaired"
grep -Fq "does not build" <<<"$out" && fail "case 3: interrupted lock was treated as broken"
[ "$(build_count)" -eq 2 ] || fail "case 3: expected 2 builds, saw $(build_count)"
[ "$(wc -l < "$commits")" -eq 1 ] || fail "case 3: repaired lock was not committed"
ok "case 3: interrupted lock is repaired on the next run"

# ---------------------------------------------------------------- case 4 ----
# Nothing moved: the run still builds (a store hit in real life) and writes
# nothing. The inode proves the lock was not rewritten byte for byte.
reset_case
lockfile "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$lock"
cp "$lock" "$head"
cp "$lock" "$truth"
printf '%s\n' "$new" > "$rev"
before_inode=$(stat -c %i "$lock")

if ! out=$(run); then
    printf '%s\n' "$out" >&2
    fail "case 4: script exited non-zero"
fi
grep -Fq "is current and builds" <<<"$out" || fail "case 4: current pin not reported"
[ "$(build_count)" -eq 1 ] || fail "case 4: expected 1 build, saw $(build_count)"
if [ -s "$commits" ]; then fail "case 4: current pin was committed"; fi
[ "$(stat -c %i "$lock")" = "$before_inode" ] || fail "case 4: lock was rewritten"
ok "case 4: current pin builds, writes nothing, commits nothing"

# ---------------------------------------------------------------- case 5 ----
# Upstream broke while the working tree holds an uncommitted lock. Restore must
# bring back that lock, not the committed one, and the run must exit 0.
reset_case
lockfile "$old" "$old_src" "$old_pnpm" "$old_cargo" > "$lock"
cp "$lock" "$head"
lockfile "$old" "$old_src" "$old_pnpm" "$(hash "HandEditedDirtyLock")" > "$lock"
cp "$lock" "$work/before.nix"
lockfile broken "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
printf '%s\n' "$new" > "$rev"

if ! out=$(run); then
    printf '%s\n' "$out" >&2
    fail "case 5: script exited non-zero on an upstream break"
fi
cmp -s "$work/before.nix" "$lock" || fail "case 5: dirty lock was not restored"
if [ -s "$commits" ]; then fail "case 5: broken pin was committed"; fi
grep -Fq "does not build" <<<"$out" || fail "case 5: break not reported"
grep -Fq "still on" "$work/notify" || fail "case 5: no notification"
ok "case 5: broken upstream restores the dirty lock"

# ---------------------------------------------------------------- case 6 ----
# First run on a checkout without the lock: everything has to be created.
reset_case
lockfile "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
printf '%s\n' "$new" > "$rev"

if ! out=$(run); then
    printf '%s\n' "$out" >&2
    fail "case 6: script exited non-zero"
fi
diff -u "$truth" "$lock" || fail "case 6: lock was not created from scratch"
[ "$(build_count)" -eq 4 ] || fail "case 6: expected 4 builds, saw $(build_count)"
[ "$(wc -l < "$commits")" -eq 1 ] || fail "case 6: new lock was not committed"
ok "case 6: missing lock is created from scratch"

# ---------------------------------------------------------------- case 7 ----
# systemd stops the timer mid-build: the lock must come back untouched and the
# script must exit 130 so the interruption is visible.
reset_case
lockfile "$old" "$old_src" "$old_pnpm" "$old_cargo" > "$lock"
cp "$lock" "$head"
cp "$lock" "$work/before.nix"
lockfile "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
printf '%s\n' "$new" > "$rev"

set +e
out=$(run T3_TEST_TERM=1)
status=$?
set -e
[ "$status" -eq 130 ] || {
    printf '%s\n' "$out" >&2
    fail "case 7: expected exit 130, got $status"
}
cmp -s "$work/before.nix" "$lock" || fail "case 7: lock was not restored"
if [ -s "$commits" ]; then fail "case 7: interrupted run committed"; fi
ok "case 7: SIGTERM mid-build restores the lock"

echo
echo "PASS: 7 cases"
