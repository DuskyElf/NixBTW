#!/usr/bin/env bash
set -euo pipefail

printf " "
printf "$(free -h | awk '/Mem/{print $3}')"
