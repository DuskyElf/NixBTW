#!/usr/bin/env bash
# test-machine-digest: sanity check for scripts/machine-digest.sh.
#
# Runs the digest against the live machine over a one day window and asserts
# that it exits 0 and prints every section heading. The numbers are not
# asserted: they change every day and on every machine, so only the shape of
# the report is a stable contract.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
digest="$here/machine-digest.sh"

if [ ! -x "$digest" ]; then
    echo "FAIL: $digest is missing or not executable" >&2
    exit 1
fi

if ! out=$("$digest" --since "1 day ago"); then
    echo "FAIL: machine-digest --since '1 day ago' exited non-zero" >&2
    printf '%s\n' "$out" >&2
    exit 1
fi

headings=(
    "MACHINE DIGEST"
    "window: since 1 day ago"
    "== Boots =="
    "== Journal =="
    "== Coredumps =="
    "== Failed Units =="
    "== Suspend =="
    "== Battery =="
    "== Disk =="
    "== Kernel Taint =="
)

missing=0
for heading in "${headings[@]}"; do
    if ! grep -Fq -- "$heading" <<<"$out"; then
        echo "FAIL: missing report line: $heading" >&2
        missing=1
    fi
done

if [ "$missing" -ne 0 ]; then
    echo "FAIL: report is incomplete, full output follows" >&2
    printf '%s\n' "$out" >&2
    exit 1
fi

# The argument contract is part of the interface: bad input must be rejected
# with the usage error code, and must not print a report.
if "$digest" --nonsense >/dev/null 2>&1; then
    echo "FAIL: machine-digest accepted an unknown argument" >&2
    exit 1
fi
if ! grep -Fq "health:" <<<"$out"; then
    echo "FAIL: battery health line missing (fallback report?)" >&2
    exit 1
fi

# The service writes its report to the journal, so a second run must not count
# the first run's output. Compare the counts that the scan derives from the
# journal; they must not drift.
if ! out2=$("$digest" --since "1 day ago"); then
    echo "FAIL: second run exited non-zero" >&2
    exit 1
fi
for pattern in "Failed-to-start journal entries" "Taint-related journal entries"; do
    first=$(grep -F -- "$pattern" <<<"$out" || true)
    second=$(grep -F -- "$pattern" <<<"$out2" || true)
    if [ "$first" != "$second" ]; then
        echo "FAIL: count drifted between runs: $pattern" >&2
        echo "  run 1: $first" >&2
        echo "  run 2: $second" >&2
        exit 1
    fi
done

echo "PASS: all ${#headings[@]} report lines present"
echo
printf '%s\n' "$out"
