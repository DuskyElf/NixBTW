#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <powersave|ultra-powersave|performance|screenpad>"
    exit 1
fi

MODE=$1

run_user_cmd() {
    if [ -n "${SUDO_USER:-}" ]; then
        local user_uid
        user_uid=$(id -u "$SUDO_USER")
        sudo -u "$SUDO_USER" env XDG_RUNTIME_DIR="/run/user/$user_uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$user_uid/bus" "$@"
    else
        "$@"
    fi
}

if [ "$MODE" = "screenpad" ]; then
    STATE=${2:-}
    if [ "$STATE" = "off" ]; then
        echo 4 > /sys/class/backlight/asus_screenpad/bl_power
    elif [ "$STATE" = "on" ]; then
        echo 0 > /sys/class/backlight/asus_screenpad/bl_power
    else
        echo "Usage: $0 screenpad <on|off>"
        exit 1
    fi
elif [ "$MODE" = "ultra-powersave" ]; then
    # Switch to ultra-powersave mode
    run_user_cmd systemctl --user stop voxtype
    auto-cpufreq --force powersave
    undervolt -t 70
    modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
    sh -c 'echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove' || true
    run_user_cmd notify-send "Power Mode" "Switched to ultra-powersave mode" --expire-time=500
elif [ "$MODE" = "powersave" ]; then
    # Switch to powersave mode (reset CPU, disable GPU)
    run_user_cmd systemctl --user stop voxtype
    auto-cpufreq --force reset
    undervolt -t 93
    modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
    sh -c 'echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove' || true
    run_user_cmd notify-send "Power Mode" "Switched to powersave mode" --expire-time=500
elif [ "$MODE" = "performance" ]; then
    # Switch to performance mode
    auto-cpufreq --force reset
    undervolt -t 93
    echo 1 | sudo tee /sys/bus/pci/rescan
    modprobe nvidia nvidia_modeset nvidia_drm
    run_user_cmd systemctl --user start voxtype
    run_user_cmd notify-send "Power Mode" "Switched to performance mode" --expire-time=500
else
    echo "Error: Invalid mode '$MODE'"
    echo "Usage: $0 <powersave|ultra-powersave|performance>"
    exit 1
fi
