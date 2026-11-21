#!/usr/bin/env bash
# test-update-server: deterministic checks for pkgs/t3code/update-server.sh.
#
# The script runs against shims placed first in PATH: `curl` serves a canned
# release API answer and tarball body with a chosen HTTP code, `nix` reports a
# fixed hash, `git` records the add/commit, and `mv` can fail on demand. No
# network, no build, no real repo.
#
# Cases:
#   1. new tag          lock moved to tag and hash, committed
#   2. up to date       same tag and hash: nothing written or committed
#   3. rehash           same tag, new hash: lock repaired and committed
#   4. empty body       200 with no bytes: exit 1, lock kept
#   5. missing asset    404: exit 0, notified, lock kept
#   6. server error     500: exit 1, lock kept
#   7. transport error  curl fails: exit 1, lock kept
#   8. older tag        pin kept, exit 0
#   9. prerelease       pin kept, exit 0
#  10. kill before mv   lock.new removed, exit 1
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/update-server.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

[ -x "$script" ] || fail "$script is missing or not executable"

mkdir -p "$work/bin" "$work/dotfiles/pkgs/t3code" "$work/dotfiles/.tmp"
lock=$work/dotfiles/pkgs/t3code/server-lock.nix
head=$work/lock.head
release=$work/release.json
body=$work/body
commits=$work/commits
notify=$work/notify
real_mv=$(command -v mv)

cat > "$work/bin/curl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
if [[ $args == *api.github.com* ]]; then
    cat "$T3_TEST_RELEASE"
    exit 0
fi
[ -z "${T3_TEST_CURL_FAIL:-}" ] || exit 7
out=
while [ $# -gt 0 ]; do
    case $1 in
        -o) out=$2; shift 2 ;;
        *) shift ;;
    esac
done
cat "$T3_TEST_BODY" > "$out"
printf '%s' "$T3_TEST_CODE"
SHIM

cat > "$work/bin/nix" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = hash ] || { echo "shim nix: unexpected: $*" >&2; exit 2; }
printf '%s\n' "$T3_TEST_HASH"
SHIM

cat > "$work/bin/git" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" != -C ] || shift 2
case "${1:-}" in
    status)
        cmp -s "$T3_TEST_LOCK" "$T3_TEST_HEAD" || echo " M pkgs/t3code/server-lock.nix"
        ;;
    add)
        printf 'add %s\n' "${2:-}" >> "$T3_TEST_GIT_LOG"
        ;;
    commit)
        printf '%s\n' "$*" >> "$T3_TEST_COMMITS"
        cp "$T3_TEST_LOCK" "$T3_TEST_HEAD"
        ;;
    *)
        echo "shim git: unexpected: $*" >&2
        exit 2
        ;;
esac
SHIM

cat > "$work/bin/mv" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${T3_TEST_FAIL_MV:-}" ] || { printf 'mv %s\n' "$*" >> "$T3_TEST_MV_LOG"; exit 1; }
exec "$T3_TEST_REAL_MV" "$@"
SHIM

cat > "$work/bin/notify-send" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T3_TEST_NOTIFY"
SHIM

chmod +x "$work/bin/"*

hash() { printf 'sha256-%s=\n' "$1"; }
lockfile() {
    cat > "$lock" <<EOF
# The prebuilt Linux server tarball this repo's headless host installs.
{
  tag = "$1";
  hash = "$2";
}
EOF
}
release() {
    printf '{"tag_name": "%s", "name": "release"}\n' "$1" > "$release"
}

# Reset the per-case state. `head` is what git believes is committed.
reset() {
    : > "$commits"; : > "$notify"; : > "$work/git.log"; : > "$work/mv.log"
    printf 'x' > "$body"
    export T3_TEST_RELEASE=$release T3_TEST_BODY=$body T3_TEST_CODE=200
    export T3_TEST_HASH=$(hash newhash) T3_TEST_LOCK=$lock T3_TEST_HEAD=$head
    export T3_TEST_COMMITS=$commits T3_TEST_NOTIFY=$notify
    export T3_TEST_GIT_LOG=$work/git.log T3_TEST_MV_LOG=$work/mv.log
    export T3_TEST_REAL_MV=$real_mv
    unset T3_TEST_CURL_FAIL T3_TEST_FAIL_MV
}

# Run with the shims and capture the message plus exit code without tripping
# the test's own `set -e`.
run() {
    set +e
    msg=$(PATH="$work/bin:$PATH" DOTFILES="$work/dotfiles" "$script" 2>&1)
    rc=$?
    set -e
}

export PATH="$work/bin:$PATH" DOTFILES="$work/dotfiles"

# 1. new tag
reset; lockfile v0.1.10 "$(hash oldhash)"; cp "$lock" "$head"; release v0.1.11
run
[ "$rc" -eq 0 ] || fail "new tag: exit $rc: $msg"
grep -q 'v0.1.11' "$lock" || fail "new tag: lock tag"
grep -q "$(hash newhash)" "$lock" || fail "new tag: lock hash"
grep -q 'chore(t3code): server v0.1.11' "$commits" || fail "new tag: commit"
ok "new tag"

# 2. up to date
reset; lockfile v0.1.11 "$(hash newhash)"; cp "$lock" "$head"; release v0.1.11
run
[ "$rc" -eq 0 ] || fail "up to date: exit $rc: $msg"
grep -q 'is current' <<<"$msg" || fail "up to date: message: $msg"
[ ! -s "$commits" ] || fail "up to date: unexpected commit"
ok "up to date"

# 3. rehash
reset; lockfile v0.1.11 "$(hash oldhash)"; cp "$lock" "$head"; release v0.1.11
run
[ "$rc" -eq 0 ] || fail "rehash: exit $rc: $msg"
grep -q "$(hash newhash)" "$lock" || fail "rehash: lock hash"
[ -s "$commits" ] || fail "rehash: no commit"
ok "rehash"

# 4. empty body with 200
reset; lockfile v0.1.10 "$(hash oldhash)"; cp "$lock" "$head"; release v0.1.11
: > "$body"
run
[ "$rc" -eq 1 ] || fail "empty body: exit $rc: $msg"
grep -q 'empty' <<<"$msg" || fail "empty body: message: $msg"
grep -q 'v0.1.10' "$lock" || fail "empty body: lock moved"
ok "empty body"

# 5. missing asset
reset; lockfile v0.1.10 "$(hash oldhash)"; cp "$lock" "$head"; release v0.1.11
T3_TEST_CODE=404 run
[ "$rc" -eq 0 ] || fail "404: exit $rc: $msg"
grep -q 'no linux-x64 tarball yet' <<<"$msg" || fail "404: message: $msg"
[ -s "$notify" ] || fail "404: no notification"
grep -q 'v0.1.10' "$lock" || fail "404: lock moved"
ok "missing asset"

# 6. server error
reset; lockfile v0.1.10 "$(hash oldhash)"; cp "$lock" "$head"; release v0.1.11
T3_TEST_CODE=500 run
[ "$rc" -eq 1 ] || fail "500: exit $rc: $msg"
grep -q 'HTTP 500' <<<"$msg" || fail "500: message: $msg"
grep -q 'v0.1.10' "$lock" || fail "500: lock moved"
ok "server error"

# 7. transport error
reset; lockfile v0.1.10 "$(hash oldhash)"; cp "$lock" "$head"; release v0.1.11
T3_TEST_CURL_FAIL=1 run
[ "$rc" -eq 1 ] || fail "transport: exit $rc: $msg"
grep -q 'could not download' <<<"$msg" || fail "transport: message: $msg"
grep -q 'v0.1.10' "$lock" || fail "transport: lock moved"
ok "transport error"

# 8. older tag
reset; lockfile v0.1.11 "$(hash oldhash)"; cp "$lock" "$head"; release v0.1.9
run
[ "$rc" -eq 0 ] || fail "older: exit $rc: $msg"
grep -q 'older than' <<<"$msg" || fail "older: message: $msg"
grep -q 'v0.1.11' "$lock" || fail "older: lock moved"
ok "older tag"

# 9. prerelease
reset; lockfile v0.1.11 "$(hash oldhash)"; cp "$lock" "$head"; release v0.1.12-rc.1
run
[ "$rc" -eq 0 ] || fail "prerelease: exit $rc: $msg"
grep -q 'non-stable' <<<"$msg" || fail "prerelease: message: $msg"
grep -q 'v0.1.11' "$lock" || fail "prerelease: lock moved"
ok "prerelease"

# 10. kill before mv: the trap must remove the sibling lock.new
reset; lockfile v0.1.10 "$(hash oldhash)"; cp "$lock" "$head"; release v0.1.11
T3_TEST_FAIL_MV=1 run
[ "$rc" -ne 0 ] || fail "fail mv: expected nonzero: $msg"
[ ! -e "$lock.new" ] || fail "fail mv: $lock.new left behind"
grep -q 'v0.1.10' "$lock" || fail "fail mv: lock moved"
ok "kill before mv"

echo "all update-server checks passed"
