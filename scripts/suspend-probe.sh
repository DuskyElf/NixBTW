#!/usr/bin/env bash
# suspend-probe: log the tasks that could block the next freeze.
#
# Run by systemd-suspend.service as ExecStartPre, before the kernel freezes
# user space. Everything goes to the journal under the tag suspend-probe, so an
# aborted suspend is self-diagnosing: find the last "begin:" line before the
# freeze failure and read what was running or blocked at that moment.
#
# D state means a task is blocked in the kernel, which is the usual reason
# freeze times out. R state is logged too because a task that never leaves the
# run queue can starve the freezer. Only main processes are inspected, not
# every thread, and the list is capped, so the probe stays well under the one
# second the suspend path can afford.
#
# This is ExecStartPre for the suspend unit, so it must never fail: a non-zero
# exit aborts the suspend, which is the outcome the probe exists to diagnose.
# Lines are built on stdout and handed to a single logger process, which keeps
# the fork count (and therefore the delay) low.
set -uo pipefail

tag="suspend-probe"
max_lines=40
logged=0

probe() {
    proc_count=0
    for dir in /proc/[0-9]*; do
        proc_count=$((proc_count + 1))
    done

    read -r _ _ _ task_summary _ </proc/loadavg
    printf 'begin: running/total tasks %s, processes %s\n' "$task_summary" "$proc_count"

    for dir in /proc/[0-9]*; do
        pid=${dir#/proc/}
        [ -r "$dir/stat" ] || continue
        read -r stat_line 2>/dev/null <"$dir/stat" || continue
        # /proc/pid/stat is "pid (comm) state ..." and comm can contain spaces
        # and parentheses, so split around the last ")" instead of by field
        # number.
        comm=${stat_line#*(}
        comm=${comm%%)*}
        rest=${stat_line##*) }
        state=${rest%% *}
        case "$state" in
            D | R) ;;
            *) continue ;;
        esac
        if [ "$logged" -ge "$max_lines" ]; then
            continue
        fi
        wchan="?"
        read -r wchan 2>/dev/null <"$dir/wchan" || true
        printf 'task state=%s pid=%s comm=%s wchan=%s\n' "$state" "$pid" "$comm" "$wchan"
        logged=$((logged + 1))
    done

    if [ "$logged" -ge "$max_lines" ]; then
        printf 'task list truncated at %s entries\n' "$max_lines"
    fi

    # Top CPU consumers hint at what was busy when the freeze started. Skip the
    # ps header row, and read to EOF so ps never sees SIGPIPE.
    ps -eo pid,comm,%cpu --sort=-%cpu 2>/dev/null | sed -n '2,6p' |
        while IFS= read -r line; do
            printf 'topcpu %s\n' "$line"
        done

    printf 'end: logged %s D/R processes\n' "$logged"
}

probe | logger -t "$tag" || true
