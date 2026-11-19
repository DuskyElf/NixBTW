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
    # Baked into the root-only copy by apps/power.nix from the host config, so
    # no argument can point the NOPASSWD rule at another backlight. The
    # writable ~/.config copy has no value here and always takes the error
    # branch; run the root copy instead.
    DEVICE=${SCREENPAD_DEVICE:-}
    if [ -z "$DEVICE" ]; then
        echo "SCREENPAD_DEVICE is unset; use the root copy at /usr/local/sbin/power.sh" >&2
        exit 1
    fi
    if [ "$STATE" != "off" ] && [ "$STATE" != "on" ]; then
        echo "Usage: $0 screenpad <on|off>"
        exit 1
    fi
    # bl_power follows the backlight class: 0 unblanks (the panel is lit),
    # 4 blanks it (dark). The asus-wmi driver inverts the ACPI argument
    # internally, which is why a raw 0 here is not "off". Verified on this
    # UX581GV with kernel 7.3.4.
    if [ "$STATE" = "off" ]; then
        echo 4 > "/sys/class/backlight/$DEVICE/bl_power"
    else
        echo 0 > "/sys/class/backlight/$DEVICE/bl_power"
    fi
elif [ "$MODE" = "ultra-powersave" ]; then
    # Switch to ultra-powersave mode (force-remove dGPU)
    auto-cpufreq --force powersave
    # Remove PCI device first, then unload modules. set -e would abort on
    # "nvidia_drm is in use" when zen's RDD holds renderD129/nvidia0
    # (invisible to nvidia-smi), so use || true and retry after killing holders.
    echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove || true
    modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia || true
    if lsmod | grep -q "^nvidia"; then
        for pid in $(ls -l /proc/*/fd/* 2>/dev/null | grep -E "nvidia|renderD129" | sed -n 's|/proc/\([0-9]*\)/fd.*|\1|p' | sort -u); do
            # Only kill known safe holders (zen RDD); skip niri/compositor
            if [ -r "/proc/$pid/comm" ] && grep -qx "RDD Process" "/proc/$pid/comm" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            fi
        done
        sleep 1
        echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove || true
        modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia || true
    fi
    run_user_cmd notify-send "Power Mode" "Switched to ultra-powersave mode" --expire-time=500
elif [ "$MODE" = "powersave" ]; then
    # Switch to powersave mode (reset CPU, force-remove dGPU like ultra)
    auto-cpufreq --force reset
    echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove || true
    modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia || true
    if lsmod | grep -q "^nvidia"; then
        for pid in $(ls -l /proc/*/fd/* 2>/dev/null | grep -E "nvidia|renderD129" | sed -n 's|/proc/\([0-9]*\)/fd.*|\1|p' | sort -u); do
            if [ -r "/proc/$pid/comm" ] && grep -qx "RDD Process" "/proc/$pid/comm" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            fi
        done
        sleep 1
        echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove || true
        modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia || true
    fi
    run_user_cmd notify-send "Power Mode" "Switched to powersave mode" --expire-time=500
elif [ "$MODE" = "performance" ]; then
    # Switch to performance mode
    auto-cpufreq --force reset
    echo 1 > /sys/bus/pci/rescan
    # nvidia_uvm backs /dev/nvidia-uvm for CUDA. Without it cuInit fails
    # (999) while nvidia-smi still works, and ollama silently falls back
    # to CPU inference.
    modprobe nvidia nvidia_uvm nvidia_modeset nvidia_drm
    run_user_cmd notify-send "Power Mode" "Switched to performance mode" --expire-time=500
else
    echo "Error: Invalid mode '$MODE'"
    echo "Usage: $0 <powersave|ultra-powersave|performance>"
    exit 1
fi
