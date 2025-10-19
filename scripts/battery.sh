#!/usr/bin/env bash
set -euo pipefail

HEALTHY_LIMIT=80
BATTERY="/sys/class/power_supply/BAT0"

capacity="$(cat "$BATTERY/capacity" 2>&1)"
case "$(cat "$BATTERY/status" 2>&1)" in
  "Not charging")
    if [ "$capacity" -gt "$HEALTHY_LIMIT" ]; then
      printf "󰂄"
    else
      printf "󱈑"
    fi
    ;;
  Discharging)
    if [ "$capacity" -gt "$HEALTHY_LIMIT" ]; then
      printf "󱟞"
    elif [ "$capacity" -gt 70 ]; then
      printf "󰂂"
    elif [ "$capacity" -gt 60 ]; then
      printf "󰂀"
    elif [ "$capacity" -gt 50 ]; then
      printf "󰁿"
    elif [ "$capacity" -gt 40 ]; then
      printf "󰁽"
    elif [ "$capacity" -gt 30 ]; then
      printf "󰁼"
    elif [ "$capacity" -gt 20 ]; then
      printf "󰁻"
    else
      printf "󰂎!"
    fi
    ;;
  Charging)
    if [ "$capacity" -gt "$HEALTHY_LIMIT" ]; then
      printf "󰂃󱐋" # Battery shouldn't be charging beyond the healthy limit
    elif [ "$capacity" -gt 70 ]; then
      printf "󰂂󱐋"
    elif [ "$capacity" -gt 60 ]; then
      printf "󰂀󱐋"
    elif [ "$capacity" -gt 50 ]; then
      printf "󰁿󱐋"
    elif [ "$capacity" -gt 40 ]; then
      printf "󰁽󱐋"
    elif [ "$capacity" -gt 30 ]; then
      printf "󰁼󱐋"
    elif [ "$capacity" -gt 20 ]; then
      printf "󰁻󱐋"
    else
      printf "󰂎󱐋"
    fi
    ;;
  Unknown)
    printf "󰂑"
    ;;
esac

printf "$capacity%%"
