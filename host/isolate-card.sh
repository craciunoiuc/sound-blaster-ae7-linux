#!/usr/bin/env bash
# isolate-card.sh — Detect the AE-7, verify its IOMMU grouping, bind to vfio-pci.
#
# Run this AFTER: enable-iommu.md (IOMMU on + reboot) AND blacklist-ca0132.conf
# installed. It is idempotent — safe to re-run.
#
# Usage:  sudo ./host/isolate-card.sh
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- helpers (inlined; this script no longer depends on vm/common.sh) ---
log()  { printf '\033[1;34m[isolate]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n'  "$*" >&2; }
die()  { printf '\033[1;31m[err ]\033[0m %s\n'  "$*" >&2; exit 1; }

command -v lspci >/dev/null 2>&1 || die "lspci not found (pacman -S pciutils)"
[[ "$(id -u)" -eq 0 ]] || die "needs root: sudo $0"

# --- 1. Find the card -----------------------------------------------------------
BDF="$(lspci -D -n -d 1102:0081 2>/dev/null | awk '{print $1}' | head -1)"
# 1102:0081 is the codec subsystem; the HDA controller is 1102:0010. Either way
# we want to isolate the whole card. Try the controller too.
if [[ -z "$BDF" ]]; then
    BDF="$(lspci -D -n -d 1102:0010 2>/dev/null | awk '{print $1}' | head -1)"
fi
if [[ -z "$BDF" ]]; then
    die "AE-7 (1102:0081 or 1102:0010) not found. Is the card installed?
         Check:  lspci -nn | /usr/bin/grep -i creative"
fi
log "AE-7 found: $BDF"
lspci -nn -s "0000:$BDF"

DEV="/sys/bus/pci/devices/0000:$BDF"

# --- 2. Verify IOMMU group ------------------------------------------------------
if [[ ! -L "$DEV/iommu_group" ]]; then
    die "No IOMMU group for $BDF. Enable AMD IOMMU first — see host/enable-iommu.md"
fi
GROUP="$(basename "$(readlink "$DEV/iommu_group")")"
log "IOMMU group: $GROUP"
echo "Devices in this group:" >&2
ls "/sys/kernel/iommu_groups/$GROUP/devices/" >&2

OTHERS="$(ls "/sys/kernel/iommu_groups/$GROUP/devices/" | /usr/bin/grep -v "^0000:$BDF$")"
if [[ -n "$OTHERS" ]]; then
    warn "Group $GROUP is shared with other host devices. Passthrough will grab them ALL:"
    echo "$OTHERS" >&2
    warn "If any of those is a device you need on the host, STOP."
fi

# --- 3. Load vfio-pci and bind --------------------------------------------------
modprobe vfio-pci || true

# Unbind the controller AND any sibling function (e.g. 14:00.1) from current drivers.
for fn in /sys/bus/pci/devices/0000:*; do
    # only touch devices under the AE-7's bridge (same slot, function varies)
    parent="$(echo "$BDF" | cut -d: -f1-2)"
    cur="$(basename "$fn")"
    if [[ "$cur" == 0000:${parent}:* ]] && [[ -L "$fn/driver" ]]; then
        drv="$(basename "$(readlink "$fn/driver")")"
        if [[ "$drv" != "vfio-pci" ]]; then
            log "Unbinding $cur from $drv"
            echo "$cur" > "$fn/driver/unbind" 2>/dev/null || true
        fi
    fi
done

# Set driver_override and probe for the primary function.
log "Setting driver_override=vfio-pci on $BDF"
echo "vfio-pci" > "$DEV/driver_override" 2>/dev/null || true
echo "0000:$BDF" > /sys/bus/pci/drivers_probe 2>/dev/null || \
    echo "0000:$BDF" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true

sleep 0.5
if [[ -e "/sys/bus/pci/drivers/vfio-pci/0000:$BDF" ]]; then
    log "SUCCESS: $BDF is now bound to vfio-pci."
    log "Device file: /dev/vfio/$GROUP"
    log "Next: pass it through to a Windows VM."
else
    die "Bind failed. Inspect:
         ls -la /sys/bus/pci/devices/0000:$BDF/driver
         dmesg | tail -30"
fi
