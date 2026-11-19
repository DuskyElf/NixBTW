#!/usr/bin/env bash
set -euo pipefail

temp_avg="$(sensors | grep 'Package id 0' | awk '{print $4}' | cut -b2-)"
load_avg="$(cut -d' ' -f1 /proc/loadavg)"
freq_avg="$(cat /proc/cpuinfo | grep 'cpu MHz' | awk '{ total += $4; count++ } END { print total/count }')"
freq_avg="$(printf %0.f $freq_avg)"
fan_rpm="$(sensors | grep 'cpu_fan' | awk '{print $2}')"

printf "%s %s@%sMHz 💨%s" $temp_avg $load_avg $freq_avg $fan_rpm
