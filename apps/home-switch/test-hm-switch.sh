#!/usr/bin/env bash
# test-hm-switch: deterministic checks for apps/home-switch/hm-switch.sh.
#
# The script runs against shims placed first in PATH: `nix eval` reports a
# derivation named after the tree's content, `nix build` materialises a fake
# generation (or fails on demand), `nix-env` moves the profile link. The fake
# tree, store and state live in one temp dir, so nothing here touches the real
# /nix/store, the real profile or the real ~/.local/state/hm-switch.
#
# Cases:
#   1. cold tree            one eval, one build, one activation, cache written
#   2. same tree            no nix call at all, reports already active
#   3. same tree, C locale  same key, still no eval (the key must not be collated)
#   4. edited tree          evaluates and activates again
#   4b. mode change         the executable bit is part of the key
#   5. reverted tree        cached generation is activated without an eval
#   6. activation died      marker mismatch re-runs the activation, not the eval
#   7. output collected     cached derivation rebuilds it, no eval
#   7b. and not active      the rebuilt generation gets activated
#   8. derivation gone      falls back to a full evaluation
#   9. --force              re-activates the active generation
#  10. activation fails     marker is not written, next run retries activation
#  11. legacy generation    refuses instead of moving the profile
#  12. bad argument         exits 2
#  13. lock notice          the overridden-lock notice is filtered out
#  14. edit mid-build       nothing is cached, the next run evaluates
#  15. symlink retargeted   the link target is part of the key
#
# Not covered on purpose: the flock (a run has to be in flight to see it, so a
# test here would be a sleep), and the 50-line cache trim (housekeeping, nothing
# reads more than one line).
set -euo pipefail

# Case 3 only means something if the test itself does not run under C.
export LC_ALL=C LANG=C

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/hm-switch.sh
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

repo=$work/dotfiles
store=$work/store
state=$work/state
bin=$work/bin
mkdir -p "$repo/apps/home-switch" "$repo/deploy-system" "$store" "$state/nix/profiles" "$bin" "$work/home"
cp -- "$script" "$repo/apps/home-switch/hm-switch.sh"
under_test=$repo/apps/home-switch/hm-switch.sh
# Dotted names sort before letters under C and after them under en_US.
printf 'ignored\n' > "$repo/.gitignore"

cat > "$bin/nix" <<'SHIM'
#!/usr/bin/env bash
# Stand-in for the two nix calls the switch makes. The derivation is named
# after the tree's content, so an edit produces a different generation and a
# revert reproduces the earlier one.
set -euo pipefail

if [ "${1:-}" = eval ]; then
    case " $* " in
        *' --override-input my-dotfiles path:'"$HM_TEST_REPO"' '*) ;;
        *)
            echo "shim nix: unexpected eval arguments: $*" >&2
            exit 2
            ;;
    esac
    case " $* " in
        *'#homeConfigurations."'*'".activationPackage.drvPath '*) ;;
        *)
            echo "shim nix: unexpected attribute: $*" >&2
            exit 2
            ;;
    esac
    # The notice every overridden input prints; the script filters it.
    printf "warning: not writing modified lock file of flake 'git+file:///nonexistent/deploy-system':\n" >&2
    printf "• Updated input 'my-dotfiles':\n" >&2
    printf "    'git+file:///nonexistent?rev=1111' (2026-11-16)\n" >&2
    printf "  → 'path:%s?lastModified=1' (2026-11-17)\n" "$HM_TEST_REPO" >&2
    if [ -n "${HM_TEST_EVAL_EDIT:-}" ]; then
        printf 'edited by the shim\n' > "$HM_TEST_REPO/edited-by-nix"
    fi
    hash=$( (cd -- "$HM_TEST_REPO" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum) | cut -c1-32)
    drv=$HM_TEST_STORE/$hash-home-manager-generation.drv
    printf 'built from %s\n' "$HM_TEST_REPO" > "$drv"
    printf 'eval\n' >> "$HM_TEST_EVALS"
    printf '%s' "$drv"
    exit 0
fi

if [ "${1:-}" = build ]; then
    printf 'build\n' >> "$HM_TEST_BUILDS"
    if [ -n "${HM_TEST_BUILD_FAIL:-}" ]; then
        echo "shim nix: error: builder for the cached derivation failed" >&2
        exit 1
    fi
    link= drv= skip=
    for arg in "$@"; do
        if [ -n "$skip" ]; then
            link=$arg
            skip=
            continue
        fi
        case $arg in
            --out-link) skip=1 ;;
            build | --*) ;;
            *) drv=$arg ;;
        esac
    done
    [ -n "$link" ] && [ -n "$drv" ] || {
        echo "shim nix: unexpected build arguments: $*" >&2
        exit 2
    }
    out=${drv%'^*'}
    out=${out%.drv}
    mkdir -p "$out"
    if [ -z "${HM_TEST_NO_GENVERSION:-}" ]; then
        printf '1\n' > "$out/gen-version"
    fi
    cat > "$out/activate" <<'ACT'
#!/usr/bin/env bash
printf '%s\n' "$0" >> "$HM_TEST_ACTS"
[ -z "${HM_TEST_ACT_FAIL:-}" ] || exit 1
ACT
    chmod +x "$out/activate"
    ln -sfn "$out" "$link"
    exit 0
fi

echo "shim nix: unsupported invocation: $*" >&2
exit 2
SHIM

cat > "$bin/nix-env" <<'SHIM'
#!/usr/bin/env bash
# Stand-in for `nix-env --profile <link> --set <generation>`.
set -euo pipefail
[ "${1:-}" = --profile ] && [ "${3:-}" = --set ] || {
    echo "shim nix-env: unexpected arguments: $*" >&2
    exit 2
}
ln -sfn "$4" "$2"
SHIM

chmod +x "$bin/nix" "$bin/nix-env"

# Script arguments for the next run, so an env assignment can come first.
ARGS=
run() {
    env PATH="$bin:$PATH" HOME="$work/home" XDG_STATE_HOME="$state" \
        HM_TEST_REPO="$repo" HM_TEST_STORE="$store" \
        HM_TEST_EVALS="$work/evals" HM_TEST_BUILDS="$work/builds" \
        HM_TEST_ACTS="$work/acts" "$@" \
        "$under_test" $ARGS
}

reset() {
    : > "$work/evals"
    : > "$work/builds"
    : > "$work/acts"
}

count() {
    if [ -s "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi
}

# expect <label> <evals> <builds> <activations>
expect() {
    local evals builds acts
    evals=$(count "$work/evals")
    builds=$(count "$work/builds")
    acts=$(count "$work/acts")
    [ "$evals" = "$2" ] || fail "$1: expected $2 evals, saw $evals"
    [ "$builds" = "$3" ] || fail "$1: expected $3 builds, saw $builds"
    [ "$acts" = "$4" ] || fail "$1: expected $4 activations, saw $acts"
}

cache=$state/hm-switch/drv-cache
activated=$state/hm-switch/activated
profile=$state/nix/profiles/home-manager

# ---------------------------------------------------------------- case 1 ----
reset
printf 'first\n' > "$repo/apps.nix"
out=$(run)
grep -Fq 'activating' <<<"$out" || fail "case 1: activation not reported"
expect "case 1" 1 1 1
[ -s "$cache" ] || fail "case 1: cache was not written"
[ -s "$activated" ] || fail "case 1: activation was not recorded"
[ -e "$profile" ] || fail "case 1: profile was not moved"
[ "$(readlink -f "$profile")" = "$(cat "$activated")" ] || fail "case 1: profile and marker disagree"
ok "case 1: cold tree evaluates, builds and activates"

# ---------------------------------------------------------------- case 2 ----
reset
out=$(run)
grep -Fq 'already active' <<<"$out" || fail "case 2: not reported as active"
expect "case 2" 0 0 0
ok "case 2: unchanged tree costs no nix call"

# --------------------------------------------------------------- case 2b ----
# The repo's .git is 24MB against a 2.6MB tree and changes on every git command.
reset
mkdir -p "$repo/.git"
printf 'object\n' > "$repo/.git/junk"
out=$(run)
grep -Fq 'already active' <<<"$out" || fail "case 2b: .git changed the key"
expect "case 2b" 0 0 0
rm -rf "$repo/.git"
ok "case 2b: .git is not part of the key"

# ---------------------------------------------------------------- case 3 ----
# sort collates under the caller's locale; the key must not.
reset
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 out=$(run)
grep -Fq 'already active' <<<"$out" || fail "case 3: locale changed the key"
expect "case 3" 0 0 0
ok "case 3: key is locale independent"

# ---------------------------------------------------------------- case 4 ----
reset
printf 'second\n' > "$repo/apps.nix"
out=$(run)
[ "$(count "$work/evals")" = 1 ] || fail "case 4: edit did not trigger an eval"
[ "$(count "$work/acts")" = 1 ] || fail "case 4: edit was not activated"
ok "case 4: an edited tree evaluates and activates"

# --------------------------------------------------------------- case 4b ----
# The store copy keeps modes, so a chmod must change the key even though the
# bytes did not.
reset
chmod +x "$repo/apps.nix"
out=$(run)
[ "$(count "$work/evals")" = 1 ] || fail "case 4b: a mode change was not seen"
chmod -x "$repo/apps.nix"
ok "case 4b: a mode change is part of the key"

# ---------------------------------------------------------------- case 5 ----
# Back to the first content: its generation is cached, so activate it without a
# build or an eval.
reset
printf 'first\n' > "$repo/apps.nix"
out=$(run)
grep -Fq 'activating' <<<"$out" || fail "case 5: reverted tree was not activated"
expect "case 5" 0 0 1
ok "case 5: a reverted tree activates its cached generation"

# ---------------------------------------------------------------- case 6 ----
# A torn activation: the profile moved but the marker did not. The activation
# has to run again, the generation does not have to be rebuilt.
reset
printf '%s\n' /nix/store/00000000000000000000000000000000-home-manager-generation > "$activated"
out=$(run)
grep -Fq 'activating' <<<"$out" || fail "case 6: torn activation was skipped"
expect "case 6" 0 0 1
[ "$(cat "$activated")" = "$(readlink -f "$profile")" ] || fail "case 6: marker not repaired"
ok "case 6: an unfinished activation is retried"

# ---------------------------------------------------------------- case 7 ----
# The GC took the built generations, the derivations are still there: rebuild
# from the cache, no evaluation. The active one needs no activation after its
# store path comes back, because the path is byte for byte the same one the
# home links already point into.
reset
for dir in "$store"/*-home-manager-generation; do rm -rf "$dir"; done
out=$(run)
grep -Fq 'already active' <<<"$out" || fail "case 7: rebuilt generation was not recognised"
expect "case 7" 0 1 0
ok "case 7: a collected active generation is rebuilt from the cache"

# --------------------------------------------------------------- case 7b ----
# Same rebuild, but for a tree that is not the active generation: that one has
# to be activated.
reset
printf 'second\n' > "$repo/apps.nix"
out=$(run)
grep -Fq 'activating' <<<"$out" || fail "case 7b: rebuilt generation was not activated"
expect "case 7b" 0 1 1
ok "case 7b: a rebuilt inactive generation is activated"

# ---------------------------------------------------------------- case 8 ----
# Both are gone: the only way back is a fresh evaluation.
reset
rm -rf "$store"
mkdir -p "$store"
out=$(run)
[ "$(count "$work/evals")" = 1 ] || fail "case 8: missing derivation did not re-evaluate"
ok "case 8: a collected derivation falls back to an evaluation"

# ---------------------------------------------------------------- case 9 ----
reset
ARGS=--force
out=$(run)
ARGS=
grep -Fq 'activating' <<<"$out" || fail "case 9: --force did not activate"
expect "case 9" 0 0 1
ok "case 9: --force re-activates the active generation"

# --------------------------------------------------------------- case 10 ----
# A failed activation must not be recorded as done; the next run retries it
# without evaluating or building again.
reset
printf 'fifth\n' > "$repo/apps.nix"
set +e
out=$(run HM_TEST_ACT_FAIL=1)
status=$?
set -e
[ "$status" -ne 0 ] || fail "case 10: failed activation exited 0"
grep -Fq 'activating' <<<"$out" || fail "case 10: failed activation was not attempted"
[ "$(cat "$activated")" != "$(readlink -f "$profile")" ] || fail "case 10: failed activation was recorded"
reset
if ! out=$(run); then fail "case 10: retry exited non-zero"; fi
grep -Fq 'activating' <<<"$out" || fail "case 10: retry skipped the activation"
expect "case 10 retry" 0 0 1
ok "case 10: a failed activation is retried, not recorded"

# --------------------------------------------------------------- case 11 ----
reset
printf 'third\n' > "$repo/apps.nix"
set +e
out=$(run HM_TEST_NO_GENVERSION=1 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail "case 11: legacy generation exited 0"
grep -Fq 'no gen-version' <<<"$out" || fail "case 11: legacy generation not explained"
[ "$(count "$work/acts")" = 0 ] || fail "case 11: legacy generation was activated"
ok "case 11: a generation without gen-version is refused"

# --------------------------------------------------------------- case 15 ----
# A symlink's target is in the store copy even though its bytes are not.
reset
ln -sfn first "$repo/link"
out=$(run)
[ "$(count "$work/evals")" = 1 ] || fail "case 15: a new symlink was not seen"
reset
ln -sfn second "$repo/link"
out=$(run)
[ "$(count "$work/evals")" = 1 ] || fail "case 15: a retargeted symlink was not seen"
rm -f "$repo/link"
ok "case 15: a symlink target is part of the key"

# --------------------------------------------------------------- case 12 ----
set +e
ARGS=--nonsense
run > /dev/null 2>&1
status=$?
ARGS=
set -e
[ "$status" -eq 2 ] || fail "case 12: expected exit 2, got $status"
ok "case 12: a bad argument exits 2"

# --------------------------------------------------------------- case 13 ----
# Every eval prints the override notice; none of it may reach the user. Only
# the absence is asserted: the filter runs in a process substitution, so its
# output can land just after the script exits.
reset
printf 'fourth\n' > "$repo/apps.nix"
out=$(run 2>&1)
if grep -Fq 'not writing modified lock file' <<<"$out"; then
    fail "case 13: the lock notice leaked"
fi
if grep -Fq 'Updated input' <<<"$out"; then
    fail "case 13: the lock notice leaked"
fi
ok "case 13: the overridden-lock notice is filtered"

# --------------------------------------------------------------- case 14 ----
# The shim edits the tree before nix copies it, so the generation comes from
# bytes the first key never saw. Nothing may be cached for that key: the run
# after the edit is undone has to evaluate instead of reusing this generation.
reset
printf 'sixth\n' > "$repo/apps.nix"
out=$(run HM_TEST_EVAL_EDIT=1 2>&1)
grep -Fq 'changed during the build' <<<"$out" || fail "case 14: mid-build edit not reported"
rm -f "$repo/edited-by-nix"
reset
if ! out=$(run); then fail "case 14: follow-up run failed"; fi
[ "$(count "$work/evals")" = 1 ] || fail "case 14: the pre-edit tree reused a stale cache line"
ok "case 14: an edit during the build is not cached"

echo
echo "PASS: 18 cases"
