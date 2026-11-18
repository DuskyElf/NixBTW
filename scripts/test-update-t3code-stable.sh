#!/usr/bin/env bash
# test-update-t3code-stable: deterministic checks for scripts/update-t3code-stable.sh.
#
# The script is driven against shims placed first in PATH: `curl` serves one
# release-API answer, `git` serves the tag it is asked for, `nix` reports hash
# mismatches in nix's own wording until the lock matches a truth file, and the
# `git` shim also records commits and restores the committed lock on checkout.
# No network, no build, no real repo.
#
# Cases:
#   1. new stable tag       tag, rev, and three hashes learned, lock committed
#   2. prerelease ignored   API answers stable only, nightly never requested,
#                           every mismatch in one log, annotated tag peeled
#   3. interrupted lock     tag current with a placeholder: repaired
#   4. up to date           builds, reports current, writes nothing
#   5. upstream break       dirty lock restored, not the committed one, exit 0
#   6. no lock yet          created from scratch with all three hashes
#   7. SIGTERM mid-build    lock restored, exit 130
#   8. tag line missing     pre-tag lock rewritten, then bumped like case 1
#   9. rev disagrees        same tag with a stale rev: rev fixed, hashes relearned
#  10. nightly refused      API serves a nightly-shaped tag: pin kept, exit 0
#  11. older refused        API serves an older stable tag: pin kept, exit 0
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/update-t3code-stable.sh
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

mkdir -p "$work/bin" "$work/dotfiles/pkgs/t3code" "$work/deploy-system"
lock=$work/dotfiles/pkgs/t3code/lock.nix
truth=$work/truth.nix
head=$work/head.nix
commits=$work/commits
builds=$work/builds
rev=$work/rev

cat > "$work/bin/curl" <<'SHIM'
#!/usr/bin/env bash
# Stand-in for the GitHub releases/latest call: serve one canned answer and
# record the URL so the test can prove the stable endpoint was used.
set -euo pipefail
printf 'curl %s\n' "$*" >> "$T3_TEST_CURL_ARGS"
cat "$T3_TEST_RELEASE"
SHIM

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
        printf 'git %s\n' "$*" >> "$T3_TEST_GIT_ARGS"
        rev=$(cat "$T3_TEST_REV")
        # The tag the script asked for: the first refs/tags/ argument, peeled
        # suffix stripped. T3_TEST_ANNOTATED answers the way an annotated tag
        # does, with a tag object line plus the peeled commit.
        req=$(printf '%s\n' "$@" | grep -m1 'refs/tags/' | sed 's/.*refs\/tags\///; s/\^{}$//')
        if [ -n "${T3_TEST_ANNOTATED:-}" ]; then
            printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/%s\n' "$req"
            printf '%s\trefs/tags/%s^{}\n' "$rev" "$req"
        else
            printf '%s\trefs/tags/%s\n' "$rev" "$req"
        fi
        ;;
    add)
        [ "${2:-}" = "pkgs/t3code/lock.nix" ] || {
            echo "shim git: add of ${2:-nothing}" >&2
            exit 1
        }
        ;;
    commit)
        printf '%s\n' "$*" >> "$T3_TEST_COMMITS"
        cp "$T3_TEST_LOCK" "$T3_TEST_HEAD"
        ;;
    status)
        cmp -s "$T3_TEST_LOCK" "$T3_TEST_HEAD" || echo " M pkgs/t3code/lock.nix"
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

chmod +x "$work/bin/curl" "$work/bin/nix" "$work/bin/git" "$work/bin/notify-send"

hash() { printf 'sha256-%s=\n' "$1"; }

# Writes the lock shape the script reads and rewrites.
lockfile() {
    cat <<EOF
# Stable release tag of pingdotgg/t3code plus the fixed-output hashes for it.
# Rewritten by scripts/update-t3code-stable.sh; there is no reason to edit by hand.
{
  tag = "$1";
  rev = "$2";
  srcHash = "$3";
  pnpmDepsHash = "$4";
  cargoHash = "$5";
}
EOF
}

# Serves one release-API answer carrying the stable tag.
release() {
    cat <<EOF
{"url": "https://api.github.com/repos/pingdotgg/t3code/releases/1", "tag_name": "$1", "draft": false, "prerelease": false}
EOF
}

# Writes the pre-tag lock shape: rev plus three hashes, no tag line. The
# header wording is not the old one on purpose; only the missing tag line
# matters, and no stale script name stays behind for greps to trip on.
lockfile_notag() {
    cat <<EOF
# Pinned commit of pingdotgg/t3code plus the fixed-output hashes for it.
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
        T3_TEST_RELEASE="$work/release.json" \
        T3_TEST_CURL_ARGS="$work/curl-args" T3_TEST_GIT_ARGS="$work/git-args" \
        T3_TEST_NOTIFY="$work/notify" "$@" \
        "$script"
}

# Clears every fixture so a case cannot inherit state from the one before it.
reset_case() {
    : > "$commits"
    : > "$builds"
    : > "$work/notify"
    : > "$work/curl-args"
    : > "$work/git-args"
    rm -f "$lock" "$truth" "$head" "$rev" "$work/release.json"
}

build_count() { wc -l < "$builds" | tr -d ' '; }

# ---------------------------------------------------------------- fixtures --
old_tag=v0.1.9
new_tag=v0.1.10
nightly_tag=v0.1.10-nightly.20261117.4600
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
# A stable bump: every hash is a placeholder, so nix reports one mismatch at a
# time (three builds) and the fourth proves the pin.
reset_case
lockfile "$old_tag" "$old" "$old_src" "$old_pnpm" "$old_cargo" > "$lock"
cp "$lock" "$head"
lockfile "$new_tag" "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
release "$new_tag" > "$work/release.json"
printf '%s\n' "$new" > "$rev"

if ! out=$(run); then
    printf '%s\n' "$out" >&2
    fail "case 1: script exited non-zero"
fi
diff -u "$truth" "$lock" || fail "case 1: lock does not match truth"
grep -Fq "stable $old_tag -> $new_tag" <<<"$out" || fail "case 1: tag bump not reported"
for value in "$new_src" "$new_pnpm" "$new_cargo"; do
    grep -Fq "$value" <<<"$out" || fail "case 1: learned hash not reported: $value"
done
[ "$(build_count)" -eq 4 ] || fail "case 1: expected 4 builds, saw $(build_count)"
[ "$(wc -l < "$commits")" -eq 1 ] || fail "case 1: expected exactly one commit"
grep -Fq -- "--no-gpg-sign" "$commits" || fail "case 1: commit is not signed off for the timer"
grep -Fq "chore(t3code): $new_tag" "$commits" || fail "case 1: commit subject is wrong"
ok "case 1: new stable tag learns all three hashes and commits"

# ---------------------------------------------------------------- case 2 ----
# A newer nightly exists upstream, but the release API answers the stable tag
# only, so the script pins stable and never asks git for the nightly ref. The
# tag is annotated here, so the commit comes from the peeled line, and real nix
# can put several mismatches in one log, so one build learns all of them.
reset_case
lockfile "$old_tag" "$old" "$old_src" "$old_pnpm" "$old_cargo" > "$lock"
cp "$lock" "$head"
lockfile "$new_tag" "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
release "$new_tag" > "$work/release.json"
printf '%s\n' "$new" > "$rev"

if ! out=$(run T3_TEST_MULTI=1 T3_TEST_ANNOTATED=1); then
    printf '%s\n' "$out" >&2
    fail "case 2: script exited non-zero"
fi
diff -u "$truth" "$lock" || fail "case 2: lock does not match truth"
grep -Fq "releases/latest" "$work/curl-args" || fail "case 2: stable endpoint was not used"
grep -Fq "refs/tags/$new_tag" "$work/git-args" || fail "case 2: stable tag was not resolved"
if grep -Fq "$nightly_tag" "$work/git-args"; then fail "case 2: nightly tag was requested"; fi
[ "$(build_count)" -eq 2 ] || fail "case 2: expected 2 builds, saw $(build_count)"
ok "case 2: prerelease never selected, annotated tag peeled, one log harvested"

# ---------------------------------------------------------------- case 3 ----
# The reported bug: an earlier run bumped the tag and died before filling in
# srcHash. The next run must finish the pin instead of trusting the tag.
reset_case
lockfile "$new_tag" "$new" "$fake" "$new_pnpm" "$new_cargo" > "$lock"
cp "$lock" "$head"
lockfile "$new_tag" "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
release "$new_tag" > "$work/release.json"
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
lockfile "$new_tag" "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$lock"
cp "$lock" "$head"
cp "$lock" "$truth"
release "$new_tag" > "$work/release.json"
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
lockfile "$old_tag" "$old" "$old_src" "$old_pnpm" "$old_cargo" > "$lock"
cp "$lock" "$head"
lockfile "$old_tag" "$old" "$old_src" "$old_pnpm" "$(hash "HandEditedDirtyLock")" > "$lock"
cp "$lock" "$work/before.nix"
next_tag=v0.1.11
lockfile broken broken "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
release "$next_tag" > "$work/release.json"
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
lockfile "$new_tag" "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
release "$new_tag" > "$work/release.json"
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
lockfile "$old_tag" "$old" "$old_src" "$old_pnpm" "$old_cargo" > "$lock"
cp "$lock" "$head"
cp "$lock" "$work/before.nix"
lockfile "$new_tag" "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
release "$new_tag" > "$work/release.json"
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

# ---------------------------------------------------------------- case 8 ----
# A lock from before the tag field existed: the header is rewritten around the
# kept rev, the tag counts as changed, and the bump relearns every hash.
reset_case
lockfile_notag "$old" "$old_src" "$old_pnpm" "$old_cargo" > "$lock"
cp "$lock" "$work/before.nix"
lockfile "$new_tag" "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
release "$new_tag" > "$work/release.json"
printf '%s\n' "$new" > "$rev"

# The committed copy cannot hold a tag either, so point head at the pre-tag
# shape and let the commit record the rewritten one.
cp "$lock" "$head"
if ! out=$(run); then
    printf '%s\n' "$out" >&2
    fail "case 8: script exited non-zero"
fi
diff -u "$truth" "$lock" || fail "case 8: pre-tag lock was not rewritten and bumped"
grep -Fq "stable none -> $new_tag" <<<"$out" || fail "case 8: tag move from empty not reported"
[ "$(build_count)" -eq 4 ] || fail "case 8: expected 4 builds, saw $(build_count)"
[ "$(wc -l < "$commits")" -eq 1 ] || fail "case 8: rewritten lock was not committed"
ok "case 8: lock without a tag line is rewritten, then bumped"

# ---------------------------------------------------------------- case 9 ----
# Split brain: the tag is current but the rev is stale (a kill landed between
# the tag and rev writes). The rev is reconciled and the hashes relearned,
# not trusted from the stale rev.
reset_case
lockfile "$new_tag" "$old" "$old_src" "$old_pnpm" "$old_cargo" > "$lock"
cp "$lock" "$head"
lockfile "$new_tag" "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$truth"
release "$new_tag" > "$work/release.json"
printf '%s\n' "$new" > "$rev"

if ! out=$(run); then
    printf '%s\n' "$out" >&2
    fail "case 9: script exited non-zero"
fi
diff -u "$truth" "$lock" || fail "case 9: stale rev was not reconciled"
grep -Fq "rev ${old:0:7} -> ${new:0:7}" <<<"$out" || fail "case 9: rev repair not reported"
[ "$(build_count)" -eq 4 ] || fail "case 9: expected 4 builds, saw $(build_count)"
[ "$(wc -l < "$commits")" -eq 1 ] || fail "case 9: reconciled lock was not committed"
ok "case 9: stale rev under a current tag is repaired"

# --------------------------------------------------------------- case 10 ----
# The API serves a nightly-shaped tag with no flags to filter on. The shape
# guard refuses it before git is even asked, the pin stays byte-identical,
# and the run exits 0.
reset_case
lockfile "$new_tag" "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$lock"
cp "$lock" "$head"
cp "$lock" "$truth"
cp "$lock" "$work/before.nix"
printf '{"tag_name": "%s"}\n' "$nightly_tag" > "$work/release.json"
printf '%s\n' "$new" > "$rev"
before_inode=$(stat -c %i "$lock")

if ! out=$(run); then
    printf '%s\n' "$out" >&2
    fail "case 10: script exited non-zero on a refused tag"
fi
grep -Fq "refusing non-stable tag $nightly_tag" <<<"$out" || fail "case 10: refusal not reported"
if [ -s "$work/git-args" ]; then fail "case 10: git was asked about a refused tag"; fi
if [ ! -s "$work/curl-args" ]; then fail "case 10: release API was not consulted"; fi
cmp -s "$work/before.nix" "$lock" || fail "case 10: lock was touched by a refusal"
[ "$(stat -c %i "$lock")" = "$before_inode" ] || fail "case 10: lock was rewritten"
if [ -s "$commits" ]; then fail "case 10: refused tag was committed"; fi
grep -Fq "non-stable tag" "$work/notify" || fail "case 10: no notification"
ok "case 10: nightly-shaped tag is refused, pin untouched"

# --------------------------------------------------------------- case 11 ----
# The API serves an older stable tag (a re-published patch). Version compare
# refuses it, the pin stays, and the run exits 0.
reset_case
lockfile "$new_tag" "$new" "$new_src" "$new_pnpm" "$new_cargo" > "$lock"
cp "$lock" "$head"
cp "$lock" "$work/before.nix"
release "$old_tag" > "$work/release.json"
printf '%s\n' "$old" > "$rev"
before_inode=$(stat -c %i "$lock")

if ! out=$(run); then
    printf '%s\n' "$out" >&2
    fail "case 11: script exited non-zero on an older tag"
fi
grep -Fq "is older than $new_tag" <<<"$out" || fail "case 11: backwards move not reported"
cmp -s "$work/before.nix" "$lock" || fail "case 11: lock was touched by a refusal"
[ "$(stat -c %i "$lock")" = "$before_inode" ] || fail "case 11: lock was rewritten"
if [ -s "$commits" ]; then fail "case 11: older tag was committed"; fi
ok "case 11: older stable tag is refused, pin untouched"

echo
echo "PASS: 11 cases"
