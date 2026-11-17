#!/usr/bin/env bash
# The two numbers that say whether the agent scratch space is about to run out:
# the tmpfs the worktrees live on, and what zram swap is holding. Both read
# /proc and /sys, so a status bar refresh touches no disk.
set -euo pipefail

worktrees=/mnt/agent-worktrees

fmt_bytes() {
  awk -v b="$1" 'BEGIN{
    u[1]="B"; u[2]="K"; u[3]="M"; u[4]="G"; u[5]="T"
    i=1
    while (b>=1024 && i<5) { b/=1024; i++ }
    if (i==1) printf "%dB", b
    else printf "%.1f%s", b, u[i]
  }'
}

# Used and total of the worktree mount, in findmnt's own units. Asking findmnt
# about the mountpoint is what makes an unmounted path a dash instead of the
# parent filesystem's numbers.
tmpfs() {
  local used size
  read -r used size < <(findmnt -n -o USED,SIZE --mountpoint "$worktrees" 2>/dev/null) || true
  if [ -z "${used:-}" ]; then
    printf "wt -"
    return
  fi
  printf "wt %s/%s" "$used" "$size"
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
  worktrees) tmpfs ;;
  swap) swap ;;
  *)
    printf 'usage: %s worktrees|swap\n' "${0##*/}" >&2
    exit 2
    ;;
esac
