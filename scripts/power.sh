#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <powersave|ultra-powersave|performance|screenpad>"
    exit 1
fi

MODE=$1

# Pin kmod: sudo inherits the caller's PATH (no secure_path in sudoers), so a
# devshell or profile with busybox in it shadows modprobe with busybox's
# applet, which hard-chdirs into /lib/modules/$(uname -r) and dies if that
# directory is missing. kmod is compiled with /run/current-system/kernel-modules
# as fallback and does not need /lib/modules.
MODPROBE=/run/current-system/sw/bin/modprobe

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
        echo 0 > /sys/class/backlight/asus_screenpad/bl_power
    elif [ "$STATE" = "on" ]; then
        echo 4 > /sys/class/backlight/asus_screenpad/bl_power
    else
        echo "Usage: $0 screenpad <on|off>"
        exit 1
    fi
elif [ "$MODE" = "ultra-powersave" ]; then
    # Switch to ultra-powersave mode (force-remove dGPU)
    auto-cpufreq --force powersave
    undervolt -t 70
    # Remove PCI device first, then unload modules. set -e would abort on
    # "nvidia_drm is in use" when zen's RDD holds renderD129/nvidia0
    # (invisible to nvidia-smi), so use || true and retry after killing holders.
    sh -c 'echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove' || true
    "$MODPROBE" -r nvidia_uvm nvidia_drm nvidia_modeset nvidia || true
    if lsmod | grep -q "^nvidia"; then
        for pid in $(ls -l /proc/*/fd/* 2>/dev/null | grep -E "nvidia|renderD129" | sed -n 's|/proc/\([0-9]*\)/fd.*|\1|p' | sort -u); do
            # Only kill known safe holders (zen RDD); skip niri/compositor
            if [ -r "/proc/$pid/comm" ] && grep -qx "RDD Process" "/proc/$pid/comm" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            fi
        done
        sleep 1
        sh -c 'echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove' || true
        "$MODPROBE" -r nvidia_uvm nvidia_drm nvidia_modeset nvidia || true
    fi
    run_user_cmd notify-send "Power Mode" "Switched to ultra-powersave mode" --expire-time=500
elif [ "$MODE" = "powersave" ]; then
    # Switch to powersave mode (reset CPU, force-remove dGPU like ultra)
    auto-cpufreq --force reset
    undervolt -t 93
    sh -c 'echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove' || true
    "$MODPROBE" -r nvidia_uvm nvidia_drm nvidia_modeset nvidia || true
    if lsmod | grep -q "^nvidia"; then
        for pid in $(ls -l /proc/*/fd/* 2>/dev/null | grep -E "nvidia|renderD129" | sed -n 's|/proc/\([0-9]*\)/fd.*|\1|p' | sort -u); do
            if [ -r "/proc/$pid/comm" ] && grep -qx "RDD Process" "/proc/$pid/comm" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            fi
        done
        sleep 1
        sh -c 'echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove' || true
        "$MODPROBE" -r nvidia_uvm nvidia_drm nvidia_modeset nvidia || true
    fi
    run_user_cmd notify-send "Power Mode" "Switched to powersave mode" --expire-time=500
elif [ "$MODE" = "performance" ]; then
    # Switch to performance mode
    auto-cpufreq --force reset
    undervolt -t 93
    echo 1 | sudo tee /sys/bus/pci/rescan
    "$MODPROBE" nvidia nvidia_modeset nvidia_drm
    run_user_cmd notify-send "Power Mode" "Switched to performance mode" --expire-time=500
else
    echo "Error: Invalid mode '$MODE'"
    echo "Usage: $0 <powersave|ultra-powersave|performance>"
    exit 1
fi
