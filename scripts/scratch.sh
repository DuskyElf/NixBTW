#!/usr/bin/env bash
# The numbers that say whether the RAM the machine fakes as disk is about to run
# out: the two tmpfs mounts, the worktrees agents use and /tmp for builds, plus
# what zram swap is holding. All read /proc and /sys, so a status bar refresh
# touches no disk.
set -euo pipefail

worktrees=/mnt/agent-worktrees
tmpdir=/tmp

fmt_bytes() {
  awk -v b="$1" 'BEGIN{
    u[1]="B"; u[2]="K"; u[3]="M"; u[4]="G"; u[5]="T"
    i=1
    while (b>=1024 && i<5) { b/=1024; i++ }
    if (i==1) printf "%dB", b
    else printf "%.1f%s", b, u[i]
  }'
}

# Used and total of a tmpfs mount, in findmnt's own units. Asking findmnt
# about the mountpoint and the fstype is what makes an unmounted path a dash
# instead of the parent filesystem's numbers, and a /tmp that is a real disk
# a dash instead of disk usage reported as RAM.
tmpfs() {
  local label=$1 mnt=$2 used size
  read -r used size < <(findmnt -n -o USED,SIZE -t tmpfs --mountpoint "$mnt" 2>/dev/null) || true
  if [ -z "${used:-}" ]; then
    printf "%s -" "$label"
    return
  fi
  printf "%s %s/%s" "$label" "$used" "$size"
}

# Swap pages stored, then the RAM they cost. TOTAL includes the compression
# bookkeeping, so it is the honest answer to what the swap takes from RAM.
swap() {
  local stored ram sum
  sum=$(zramctl --bytes --noheadings --output DATA,TOTAL 2>/dev/null |
    awk '{ s+=$1; t+=$2 } END { if (NR) printf "%d %d", s, t }') || true
  if [ -z "$sum" ]; then
    printf "sw -"
    return
  fi
  read -r stored ram <<<"$sum"
  printf "sw %s→%s" "$(fmt_bytes "$stored")" "$(fmt_bytes "$ram")"
}

case "${1:-}" in
  worktrees) tmpfs wt "$worktrees" ;;
  tmp) tmpfs tmp "$tmpdir" ;;
  swap) swap ;;
  *)
    printf 'usage: %s worktrees|tmp|swap\n' "${0##*/}" >&2
    exit 2
    ;;
esac
