#!/usr/bin/env bash
# Exercise the compare step of check-kernel-update.yml against fake nix output.
#
#   nix shell nixpkgs#jq -c ./.github/test-kernel-compare.sh
#
# Why this exists: that step decides whether a kernel bump PR is opened at all,
# and it has six outcomes (every host moves, one host moves, none moves, a host
# whose pinned kernel is ahead of the channel, a host the candidate cannot
# answer for). Nothing runs it until the daily timer does, and a wrong answer
# there is silent: no PR written at all, or a bumped pin for a downgrade. So the
# step is read back out of the YAML and run here with a `nix` that returns fixed
# JSON, which also catches a reshuffle of the file that would leave the
# extraction reading the wrong lines. The bump message is checked by calling
# kernel-bump-message.sh directly.
#
# Needs bash, jq and python3. No network and no nix store access: every value
# the step asks nix for comes from a fixture. Scratch lives under the repo's
# gitignored .tmp/ and is removed on exit.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
workflow=$repo/.github/workflows/check-kernel-update.yml
mkdir -p "$repo/.tmp"
scratch=$(mktemp -d "$repo/.tmp/test-kernel-compare.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/fakebin"

for tool in jq python3; do
  command -v "$tool" >/dev/null || {
    echo "test-kernel-compare: $tool is needed, see the invocation at the top" >&2
    exit 1
  }
done

# Print the `run` block of a named step, dedented, and fail if the step or its
# block is not there: the test reads the real code, it does not keep a copy.
extract() {
  python3 - "$workflow" "$1" <<'PY'
import sys

path, step = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")

def indent_of(line):
    return len(line) - len(line.lstrip())

start = next(
    (i for i, line in enumerate(lines) if line.strip() == f"- name: {step}"), None
)
if start is None:
    raise SystemExit(f"no step named {step!r}")
step_indent = indent_of(lines[start])

# The step owns every following line that is blank or indented deeper than its
# `- name:`, so a step that lost its `run:` fails here instead of handing back
# the next step's block.
end = start + 1
while end < len(lines) and (lines[end].strip() == "" or indent_of(lines[end]) > step_indent):
    end += 1

for j in range(start, end):
    if lines[j].strip() in ("run: |", "run: >"):
        indent = indent_of(lines[j])
        body = []
        for line in lines[j + 1 : end]:
            if line.strip() == "":
                body.append("")
            elif indent_of(line) > indent:
                body.append(line[indent + 2 :])
            else:
                break
        while body and body[-1].strip() == "":
            body.pop()
        print("\n".join(body))
        break
else:
    raise SystemExit(f"step {step!r} has no run block")
PY
}

# A nix that answers the two questions the step asks: the channel rev, and
# kernelVersions for the pinned and the candidate side.
cat >"$scratch/fakebin/nix" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1 $2" = "flake prefetch" ]; then
  printf '{"locked":{"rev":"%s"}}\n' "$FAKE_LATEST_REV"
  exit 0
fi
if [ "$1" = "eval" ]; then
  for arg in "$@"; do
    if [ "$arg" = "--override-input" ]; then
      printf '%s\n' "$FAKE_LATEST"
      exit 0
    fi
  done
  printf '%s\n' "$FAKE_PINNED"
  exit 0
fi
echo "fake nix: unsupported: $*" >&2
exit 1
SH
chmod +x "$scratch/fakebin/nix"

extract "Compare Channel Kernels With Pinned Kernels" >"$scratch/compare.sh"

fail=0

# check_case <name> <pinned json> <candidate json> <expected exit>
#            <expected step output> <expected changes>
# The changes file is seeded first, so "unchanged" proves the step wrote
# nothing, not that it truncated and left an empty file. Output and changes are
# compared as sorted lines, so the test does not pin the order they arrive in.
check_case() {
  local name=$1 pinned=$2 candidate=$3 want_rc=$4 want_out=$5 want_changes=$6
  local dir=$scratch/$name
  mkdir -p "$dir"
  : >"$dir/out"
  printf 'sentinel 1 2\n' >"$dir/changes"
  (
    set +e
    cd "$repo"
    PATH=$scratch/fakebin:$PATH \
      FAKE_PINNED=$pinned FAKE_LATEST=$candidate FAKE_LATEST_REV=deadbeef \
      CHANNEL=release-26.05 CHANGES=$dir/changes GITHUB_OUTPUT=$dir/out \
      bash "$scratch/compare.sh" >"$dir/log" 2>&1
    echo $? >"$dir/rc"
  )

  local rc out changes want ok=1
  rc=$(cat "$dir/rc")
  [ "$rc" = "$want_rc" ] || { echo "FAIL $name: exit $rc, wanted $want_rc"; ok=0; }
  # The pinned rev is whatever flake.nix carries today, so only its shape is
  # checked here; the step already refuses to stage without it.
  grep -qE '^pinned_rev=[0-9a-f]{40}$' "$dir/out" \
    || { echo "FAIL $name: no 40-hex pinned_rev in the step output"; ok=0; }
  out=$( { grep -v '^pinned_rev=' "$dir/out" || true; } | sed '/^$/d' | sort)
  want=$(printf '%s\n' "$want_out" | sed '/^$/d' | sort)
  [ "$out" = "$want" ] \
    || { echo "FAIL $name: step output is"; printf '%s\n' "$out" | awk '{print "    " $0}'; ok=0; }
  changes=$(sort "$dir/changes" | sed '/^$/d')
  want=$(printf '%s\n' "$want_changes" | sed '/^$/d' | sort)
  [ "$changes" = "$want" ] \
    || { echo "FAIL $name: changes are"; printf '%s\n' "$changes" | awk '{print "    " $0}'; ok=0; }
  if [ "$ok" = 1 ]; then echo "ok   $name"; else
    echo "--- log"; awk '{print "    " $0}' "$dir/log"; fail=1
  fi
}

# Both kernels move: the case the old single-output check half-reported.
check_case both-move '{"asus":"7.3.5","homelab":"6.18.64"}' '{"asus":"7.3.6","homelab":"6.18.65"}' 0 \
  'new_rev=deadbeef
hosts=asus homelab' \
  'asus 7.3.5 7.3.6
homelab 6.18.64 6.18.65'

# Only the homelab's LTS patch moves: this opened no PR at all before the change.
check_case homelab-only '{"asus":"7.3.6","homelab":"6.18.64"}' '{"asus":"7.3.6","homelab":"6.18.65"}' 0 \
  'new_rev=deadbeef
hosts=asus homelab' \
  'homelab 6.18.64 6.18.65'

check_case none '{"asus":"7.3.6","homelab":"6.18.65"}' '{"asus":"7.3.6","homelab":"6.18.65"}' 0 \
  '' 'sentinel 1 2'

# A staging pin ahead of the channel holds, even while the other kernel would
# move forward: one rev moves both, so a forward bump would be a downgrade.
check_case hold-ahead '{"asus":"7.3.7","homelab":"6.18.64"}' '{"asus":"7.3.6","homelab":"6.18.65"}' 0 \
  '' 'sentinel 1 2'

# A host the candidate cannot answer for is a broken run, not a partial bump.
check_case missing-host '{"asus":"7.3.5","homelab":"6.18.64"}' '{"asus":"7.3.6"}' 1 \
  '' 'sentinel 1 2'

# An empty answer is a broken flake output, not an up-to-date machine.
check_case no-hosts '{}' '{}' 1 '' 'sentinel 1 2'

# The title and body name every host that moved, with the version it came from,
# and the body still says what merging costs.
title=$("$repo/.github/kernel-bump-message.sh" title "$scratch/both-move/changes")
body=$(CHANNEL=release-26.05 "$repo/.github/kernel-bump-message.sh" body "$scratch/both-move/changes")

want_title='chore(kernel): bump asus 7.3.5 -> 7.3.6, homelab 6.18.64 -> 6.18.65'
if [ "$title" = "$want_title" ]; then
  echo "ok   title"
else
  echo "FAIL title: $title"
  fail=1
fi

if printf '%s\n' "$body" | grep -qxF -- 'release-26.05 moved the pinned kernels:'; then
  echo "ok   body opener"
else
  echo "FAIL body opener"
  printf '%s\n' "$body" | awk '{print "    " $0}'
  fail=1
fi

for bullet in '- asus: 7.3.5 -> 7.3.6' '- homelab: 6.18.64 -> 6.18.65'; do
  if printf '%s\n' "$body" | grep -qxF -- "$bullet"; then
    echo "ok   body has $bullet"
  else
    echo "FAIL body lacks: $bullet"
    printf '%s\n' "$body" | awk '{print "    " $0}'
    fail=1
  fi
done

# The paragraph that tells a human what a merge will cost must survive.
if printf '%s\n' "$body" | grep -qxF -- 'night. Nothing reboots, so boot it when you next reboot.'; then
  echo "ok   body keeps the merge explainer"
else
  echo "FAIL body lost the merge explainer"
  fail=1
fi

# The message script's own refusals: an empty changes file, a body with no
# channel, and a mode it does not have.
empty=$scratch/no-changes
: >"$empty"
check_refusal() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL $name: the script accepted it"
    fail=1
  else
    echo "ok   $name"
  fi
}
check_refusal "empty changes are refused" \
  "$repo/.github/kernel-bump-message.sh" title "$empty"
check_refusal "a body without CHANNEL is refused" \
  env -u CHANNEL "$repo/.github/kernel-bump-message.sh" body "$scratch/both-move/changes"
check_refusal "an unknown mode is refused" \
  "$repo/.github/kernel-bump-message.sh" subject "$scratch/both-move/changes"

# One host moved: the title and the body's first line say so in the singular.
title=$("$repo/.github/kernel-bump-message.sh" title "$scratch/homelab-only/changes")
want_title='chore(kernel): bump homelab 6.18.64 -> 6.18.65'
if [ "$title" = "$want_title" ]; then
  echo "ok   title with one mover"
else
  echo "FAIL title with one mover: $title"
  fail=1
fi
body=$(CHANNEL=release-26.05 "$repo/.github/kernel-bump-message.sh" body "$scratch/homelab-only/changes")
if printf '%s\n' "$body" | grep -qxF -- 'release-26.05 moved the pinned kernel:'; then
  echo "ok   body opener with one mover"
else
  echo "FAIL body opener with one mover"
  printf '%s\n' "$body" | awk '{print "    " $0}'
  fail=1
fi

exit "$fail"
