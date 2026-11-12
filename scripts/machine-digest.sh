#!/usr/bin/env bash
# machine-digest: one page health report for this machine.
#
# Usage: machine-digest [--since DURATION]
#
# Prints the report to stdout and exits 0. The default window is 7 days.
# Every number comes from the running system (journal, coredumps, systemd,
# sysfs, df); nothing is cached between runs. The NixOS unit runs it as root so
# the full journal and all coredumps are visible, and tees the output into
# /var/lib/machine-digest/latest.txt.
set -euo pipefail

window="7 days ago"

usage() {
    echo "Usage: machine-digest [--since DURATION]"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --since)
            if [ "$#" -lt 2 ]; then
                echo "machine-digest: --since needs a value" >&2
                exit 2
            fi
            window="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "machine-digest: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

section() {
    printf '\n== %s ==\n' "$1"
}

# One pass over the window. Dumping the journal to a temp file would land on
# PrivateTmp's tmpfs and a week of journal can be hundreds of megabytes, so
# count inline instead. The service prints its own report into the journal, so
# the scan runs twice: once for everything and once for this unit alone, and
# subtracts the unit's own lines. Otherwise each run would count the previous
# run's labels and inflate the failures over time.
scan_window() {
    journalctl --since "$window" --quiet --no-pager -o cat "$@" 2>/dev/null | awk '
        /Failed to start/ {
            if ($0 ~ /Failed to start .*Suspend/) {
                suspend_failed++
            } else {
                failed_starts++
            }
        }
        /Freezing user space processes failed/ { freeze_failed++ }
        /tainting|Tainted:/ { taint_lines++ }
        END { print failed_starts + 0, suspend_failed + 0, freeze_failed + 0, taint_lines + 0 }
    '
}
counts=$(scan_window) || counts="0 0 0 0"
read -r failed_starts suspend_failed freeze_failed taint_lines <<<"$counts"
own_counts=$(scan_window --unit machine-digest.service) || own_counts="0 0 0 0"
read -r own_failed own_suspend own_freeze own_taint <<<"$own_counts"
failed_starts=$((failed_starts - own_failed))
suspend_failed=$((suspend_failed - own_suspend))
freeze_failed=$((freeze_failed - own_freeze))
taint_lines=$((taint_lines - own_taint))

printf 'MACHINE DIGEST\n'
printf 'generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf 'window: since %s\n' "$window"

section "Boots"
boot_count=$(journalctl --list-boots --quiet --no-pager 2>/dev/null | wc -l) || true
printf 'Total boots recorded in the journal: %s\n' "$boot_count"

section "Journal"
printf 'On-disk usage: %s\n' "$(journalctl --disk-usage 2>/dev/null || echo unavailable)"

section "Coredumps"
coredump_total=$(coredumpctl list --since "$window" --no-legend --no-pager 2>/dev/null | wc -l) || true
coredump_total=${coredump_total:-0}
printf 'Coredumps in window: %s\n' "$coredump_total"
if [ "$coredump_total" -gt 0 ]; then
    printf 'Grouped by binary (count, descending):\n'
    # coredumpctl list columns are TIME PID UID GID SIG COREFILE EXE SIZE, and
    # the executable path can contain spaces, so take the second to last field
    # rather than assuming a fixed position. Basename keeps the grouping short.
    coredumpctl list --since "$window" --no-legend --no-pager 2>/dev/null |
        awk '{ print $(NF - 1) }' |
        awk -F/ 'NF { print $NF }' |
        sort |
        uniq -c |
        sort -rn |
        awk '{ printf "%4d  %s\n", $1, $2 }' || true
else
    printf 'none\n'
fi

section "Failed Units"
failed_units=$(systemctl --failed --no-legend --no-pager 2>/dev/null | sed 's/^[[:space:]]*//' || true)
if [ -n "$failed_units" ]; then
    printf '%s\n' "$failed_units"
else
    printf 'Currently failed system units: none\n'
fi
printf 'Failed-to-start journal entries in window (suspend excluded): %s\n' "$failed_starts"

section "Suspend"
printf 'Freeze failures in window: %s\n' "$freeze_failed"
printf 'Suspends that failed to start in window: %s\n' "$suspend_failed"

section "Battery"
# Pick the first battery that exposes capacity data. energy_* is usual on
# laptops, charge_* on some firmware; both give a usable full/design ratio.
battery=""
for dir in /sys/class/power_supply/BAT*; do
    if [ -r "$dir/energy_full" ] || [ -r "$dir/charge_full" ]; then
        battery=$dir
        break
    fi
done
full_field=energy_full
design_field=energy_full_design
unit=uWh
if [ -n "$battery" ] && [ ! -r "$battery/energy_full" ]; then
    full_field=charge_full
    design_field=charge_full_design
    unit=uAh
fi
if [ -n "$battery" ] && [ -r "$battery/$full_field" ] && [ -r "$battery/$design_field" ]; then
    energy_full=$(cat "$battery/$full_field")
    energy_design=$(cat "$battery/$design_field")
    printf '%s: %s %s\n' "$full_field" "$energy_full" "$unit"
    printf '%s: %s %s\n' "$design_field" "$energy_design" "$unit"
    printf 'health: %s\n' "$(awk -v f="$energy_full" -v d="$energy_design" 'BEGIN { if (d > 0) printf "%.1f%%", f * 100 / d; else print "unknown" }')"
    for field in capacity cycle_count status; do
        if [ -r "$battery/$field" ]; then
            printf '%s: %s\n' "$field" "$(cat "$battery/$field")"
        else
            printf '%s: unavailable\n' "$field"
        fi
    done
else
    printf 'Battery: not present\n'
fi

section "Disk"
df -P / /home 2>/dev/null || printf 'df failed\n'
# df on the store is instant. Walking the store with du does not finish in a
# useful time on this machine, so report the filesystem figure instead.
df -P /nix/store 2>/dev/null | tail -n 1 || true

section "Kernel Taint"
taint_value=$(cat /proc/sys/kernel/tainted 2>/dev/null || echo unavailable)
# Bit names from Documentation/admin-guide/tainted-kernels.rst. The undervolt
# MSR writes set cpu_out_of_spec, and loading the dGPU's out-of-tree nvidia
# module sets out_of_tree_module even after the module is unloaded. Both are
# expected here; the line is a status, not a bug report.
taint_flags=(
    gpl_or_proprietary
    forced_module
    cpu_out_of_spec
    forced_rmmod
    machine_check
    bad_page
    user
    die
    acpi_overridden
    warning
    staging_driver
    firmware_workaround
    out_of_tree_module
    unsigned_module
    softlockup
)
if [[ $taint_value =~ ^[0-9]+$ ]]; then
    names=()
    for bit in "${!taint_flags[@]}"; do
        if (((taint_value >> bit) & 1)); then
            names+=("${taint_flags[bit]}")
        fi
    done
    if [ "${#names[@]}" -eq 0 ]; then
        printf 'current taint mask: %s (clean)\n' "$taint_value"
    else
        joined=""
        for name in "${names[@]}"; do
            joined="${joined}${joined:+, }${name}"
        done
        printf 'current taint mask: %s (%s)\n' "$taint_value" "$joined"
    fi
else
    printf 'current taint mask: unavailable\n'
fi
printf 'Taint-related journal entries in window: %s\n' "$taint_lines"
