#!/usr/bin/env bash
# Capture evidence from a kernel that hangs at the boot logo.
#
# Why this exists: three rounds of static analysis (vendor hooks, kABI/SYSVIPC,
# symbol gaps) all came back clean, so the hang has no visible cause in the
# binaries. The only remaining source of truth is the kernel's own log from the
# failing boot, and the window to grab it is short: pstore is cleared by a power
# cut, so a forced power-off destroys the evidence.
#
# Two capture paths, tried in order:
#   1. live  - the device shows up on USB while hung. On GKI v4 the first-stage
#              init can be up (USB id 18d1:4e11 = fastbootd/recovery) even with
#              userspace dead, and adbd sometimes comes with it. dmesg then
#              names the failing driver directly.
#   2. pstore - after a WARM reboot (long-press power, do NOT pull power and do
#              NOT enter fastboot) the previous boot's console log survives in
#              /sys/fs/pstore/console-ramoops*. Read it from the stock system.
#
# Usage:
#   scripts/catch-bootlog.sh watch    # run BEFORE flashing; polls until the
#                                     # device appears, then grabs everything
#   scripts/catch-bootlog.sh pstore   # run after a warm reboot into stock
set -uo pipefail

OUT="${OUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/research/bootlog}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$OUT/$STAMP"

# The host adb lives outside this container and needs its own lib dir.
ADB="${ADB}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/run/host/rootfs/usr/lib/x86_64-linux-gnu/android:/run/host/rootfs/usr/lib/x86_64-linux-gnu"
[ -x "$ADB" ] || { echo "::error::adb not found at $ADB (set ADB=...)"; exit 1; }

mkdir -p "$DEST"
say() { printf '%s\n' "$*"; }
grab() { # grab <label> <shell-command>
    local label="$1"; shift
    local f="$DEST/$label.txt"
    if timeout 90 "$ADB" shell "$*" >"$f" 2>&1 && [ -s "$f" ]; then
        say "    [ok]   $label ($(wc -c <"$f") bytes)"
    else
        say "    [miss] $label"
        # keep the file: its error text is itself evidence (EACCES vs ENOENT)
    fi
}

collect() {
    say "==> collecting into $DEST"
    # Kernel log first: it is what we are actually after and it can vanish.
    grab dmesg            "dmesg"
    grab dmesg_su         "su -c dmesg"
    grab pstore_console   "su -c 'cat /sys/fs/pstore/console-ramoops*'"
    grab pstore_dmesg     "su -c 'cat /sys/fs/pstore/dmesg-ramoops*'"
    grab pstore_ls        "su -c 'ls -la /sys/fs/pstore/'"
    grab last_kmsg        "su -c 'cat /proc/last_kmsg'"
    # What loaded, what did not.
    grab modules          "cat /proc/modules"
    grab modules_su       "su -c 'cat /proc/modules'"
    grab kallsyms_count   "su -c 'wc -l /proc/kallsyms'"
    # Identity and boot state.
    grab uname            "uname -a"
    grab cmdline          "cat /proc/cmdline"
    grab bootprops        "getprop | grep -iE 'boot|verified|vbmeta|slot|init'"
    grab version          "cat /proc/version"
    grab config_gz_b64    "su -c 'cat /proc/config.gz' | base64"
    # Userspace side of a logo hang: init's own view.
    grab logcat_kernel    "logcat -d -b kernel -t 2000"
    grab logcat_main      "logcat -d -b main -t 500"
    grab init_props       "getprop | grep -iE 'init\\.svc|sys\\.boot|dev\\.bootcomplete'"
    say "==> done: $DEST"
    ls -la "$DEST" | sed 's/^/    /'
}

case "${1:-watch}" in
watch)
    say "==> waiting for the device (flash and reboot now)"
    say "    IMPORTANT: if it hangs at the logo, do NOT cut power."
    say "    Ctrl-C to stop."
    seen=""
    while :; do
        state="$(timeout 10 "$ADB" get-state 2>/dev/null | tr -d '\r')"
        if [ -n "$state" ] && [ "$state" != "unknown" ]; then
            [ "$state" = "$seen" ] || say "==> device state: $state"
            seen="$state"
            if [ "$state" = "device" ] || [ "$state" = "recovery" ] || [ "$state" = "rescue" ]; then
                collect
                exit 0
            fi
        fi
        # Even with adbd down, the USB id tells us how far boot got.
        if command -v lsusb >/dev/null 2>&1; then
            usb="$(lsusb 2>/dev/null | grep -iE '18d1|2717|05c6' | head -3)"
            [ -n "$usb" ] && say "    usb: $usb"
        fi
        sleep 3
    done
    ;;
pstore|now)
    collect
    ;;
*)
    say "usage: ${0##*/} [watch|pstore]"
    exit 2
    ;;
esac
