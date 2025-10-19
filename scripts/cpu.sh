#!/usr/bin/env bash
set -euo pipefail

temp_avg="$(sensors | grep 'Package id 0' | awk '{print $4}' | cut -b2-)"
load_avg="$(cut -d' ' -f1 /proc/loadavg)"
freq_avg="$(cat /proc/cpuinfo | grep 'cpu MHz' | awk '{ total += $4; count++ } END { print total/count }')"
freq_avg="$(printf %0.f $freq_avg)"

if [ $freq_avg -gt 2000 ]; then
  printf "󰓅"
elif [ $freq_avg -gt 1000 ]; then
  printf "󰾅"
else
  printf "󰾆"
fi

printf " %s %s@%sMHz" $temp_avg $load_avg $freq_avg
