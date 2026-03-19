#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <powersave|performance>"
    exit 1
fi

MODE=$1

if [ "$MODE" = "powersave" ]; then
    # Switch to powersave mode
    auto-cpufreq --force powersave
    undervolt -t 70
    echo "Switched to powersave mode"
elif [ "$MODE" = "performance" ]; then
    # Switch to performance mode
    auto-cpufreq --force reset
    undervolt -t 93
    echo "Switched to performance mode"
else
    echo "Error: Invalid mode '$MODE'"
    echo "Usage: $0 <powersave|performance>"
    exit 1
fi
