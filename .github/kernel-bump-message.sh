#!/usr/bin/env bash
# Build the commit subject and PR body for a kernel bump.
#
#   kernel-bump-message.sh title <changes>
#   kernel-bump-message.sh body  <changes>
#
# <changes> is one "host old new" line per kernel that moved, written by the
# compare step in check-kernel-update.yml. The title and the commit subject are
# the same string, so a bump's commit and its PR cannot name different kernels.
# CHANNEL names the channel the pin tracks, for the body's first line.
#
# Why a script: this text is the record of what merging will build, and it is
# built from a file that only the daily job produces. Out of the YAML,
# .github/test-kernel-compare.sh can check it against fixtures directly instead
# of reading it back out of the workflow.
set -euo pipefail

mode=${1:?usage: kernel-bump-message.sh title|body <changes>}
changes=${2:?usage: kernel-bump-message.sh title|body <changes>}
[ -s "$changes" ] || { echo "no kernel changes in $changes" >&2; exit 1; }

# "asus 7.3.5 -> 7.3.6, homelab 6.18.64 -> 6.18.65"
moved=$(awk '{printf "%s %s -> %s, ", $1, $2, $3}' "$changes" | sed 's/, $//')

case $mode in
  title)
    echo "chore(kernel): bump $moved"
    ;;
  body)
    # One host can move alone (an LTS patch the newest series did not get), so
    # the noun follows the file rather than always being plural.
    moved_count=$(wc -l <"$changes")
    noun=kernels
    [ "$moved_count" -eq 1 ] && noun=kernel
    printf '%s moved the pinned %s:\n\n' "${CHANNEL:?CHANNEL must name the channel the pin tracks}" "$noun"
    awk '{printf "- %s: %s -> %s\n", $1, $2, $3}' "$changes"
    cat <<'TXT'

Merging this PR triggers the compile-kernel run for both machines; each leg
builds only a kernel it has not published yet and no-ops otherwise. Once CI
uploads the nars to the release and publishes the narinfos, the next daily
run's system switch substitutes them (cache hit, no 2h compile). A kernel that
is not published yet is the exception: the laptop compiles it, and the homelab
skips its switch instead of building, so a failed run costs a day, not a
night. Nothing reboots, so boot it when you next reboot.
TXT
    ;;
  *)
    echo "unknown mode $mode, want title or body" >&2
    exit 1
    ;;
esac
