#!/usr/bin/env bash
# capture.sh — Save a PCI, IOMMU and kernel-log snapshot of the AE-7 for analysis.
#
# Usage: host/capture.sh    (no root; uses "sudo -n" for lspci and dmesg if allowed)
# Output: logs/capture-<YYYYmmdd-HHMMSS>/. Exit 1 when the card is absent.
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../vm/config.sh
source "$HOST_DIR/../vm/config.sh"

SYS_PCI=/sys/bus/pci/devices
SYS_GROUPS=/sys/kernel/iommu_groups

log()  { printf '[capture] %s\n' "$*" >&2; }
die()  { printf '[capture] error: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
	"") ;;
	-h|--help) sed -n '2,5s/^# \{0,1\}//p' "$0"; exit 0 ;;
	*) die "unknown option: $1 (try --help)" ;;
esac

command -v lspci >/dev/null 2>&1 || die "lspci not found (pacman -S pciutils)"

OUT="$LOGS_DIR/capture-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
NOTES="$OUT/NOTES.txt"
echo "date: $(date -Is)" > "$NOTES"

# Add a line to NOTES.txt and show it.
note() {
	printf '%s\n' "$*" >> "$NOTES"
	log "$*"
}

# Print the driver of device $1, or "-" when the device has no driver.
pci_driver() {
	local link="$SYS_PCI/$1/driver"
	if [[ -L "$link" ]]; then
		basename "$(readlink "$link")"
	else
		echo "-"
	fi
}

# Print sysfs attribute $2 of device $1, or "-" when it cannot be read.
pci_attr() {
	local f="$SYS_PCI/$1/$2" v=""
	if [[ -r "$f" ]]; then
		v="$(cat "$f" 2>/dev/null || true)"
	fi
	echo "${v:--}"
}

# Print the parent PCI device of $1. Print nothing when the parent is a root bus.
pci_parent() {
	local p
	p="$(basename "$(dirname "$(readlink -f "$SYS_PCI/$1")")")"
	if [[ "$p" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; then
		echo "$p"
	fi
}

# Use root lspci when the sudoers drop-in allows it; root shows full config space.
if sudo -n lspci --version >/dev/null 2>&1; then
	LSPCI=(sudo -n lspci)
	PRIV="yes"
else
	LSPCI=(lspci)
	PRIV="no"
	note "sudo -n lspci is not allowed: dumps lack config space past 64 bytes and most capabilities (run: sudo host/setup.sh)"
fi

# Find the card, the bridge in front of it and the port above the bridge.
SLOT=()
BRIDGE=""
UPSTREAM=""
PRESENT=1
if out="$(ae7_bdfs)"; then
	mapfile -t SLOT <<<"$out"
	BRIDGE="$(pci_parent "${SLOT[0]}")"
else
	PRESENT=0
	note "AE-7 ($AE7_ID) not found on the PCI bus"
	BRIDGE="$(lspci -D -n -d "$BRIDGE_ID" | awk 'NR==1 {print $1}')"
	if [[ -n "$BRIDGE" ]]; then
		note "bridge $BRIDGE_ID is present at $BRIDGE without the card function"
	fi
fi
if [[ -n "$BRIDGE" ]]; then
	ids="$(pci_attr "$BRIDGE" vendor):$(pci_attr "$BRIDGE" device)"
	ids="${ids//0x/}"
	if [[ "$ids" != "$BRIDGE_ID" ]]; then
		note "parent $BRIDGE of the card is $ids, not $BRIDGE_ID"
	fi
	UPSTREAM="$(pci_parent "$BRIDGE")"
fi

{
	echo "card present: $PRESENT"
	echo "slot functions: ${SLOT[*]:--}"
	echo "bridge: ${BRIDGE:--}"
	echo "upstream port: ${UPSTREAM:--}"
	echo "root lspci: $PRIV"
} >> "$NOTES"

lspci -nn -tv > "$OUT/lspci-tree.txt" 2>&1 || note "lspci -tv failed"
lspci -D -nn -k > "$OUT/lspci-list.txt" 2>&1 || note "lspci -k failed"

# Save "lspci -vvv -nn -xxxx" of device $2 in a file named after role $1.
dump_dev() {
	local role="$1" bdf="$2"
	if ! "${LSPCI[@]}" -vvv -nn -xxxx -s "$bdf" > "$OUT/lspci-$role-${bdf//:/-}.txt" 2>&1; then
		note "lspci -vvv failed for $role $bdf"
	fi
}
if [[ -n "$UPSTREAM" ]]; then
	dump_dev upstream "$UPSTREAM"
fi
if [[ -n "$BRIDGE" ]]; then
	dump_dev bridge "$BRIDGE"
fi
for b in "${SLOT[@]}"; do
	dump_dev card "$b"
done

# List every IOMMU group with the driver and name of each device.
declare -A NAME=()
while read -r bdf rest; do
	NAME[$bdf]="$rest"
done < <(lspci -D -nn)
mapfile -t GROUPS_SORTED < <(
	for p in "$SYS_GROUPS"/*; do
		if [[ -e "$p" ]]; then
			echo "${p##*/}"
		fi
	done | sort -n
)
{
	if (( ${#GROUPS_SORTED[@]} == 0 )); then
		echo "no IOMMU groups: the IOMMU is off"
	fi
	for b in "${SLOT[@]}"; do
		if [[ -L "$SYS_PCI/$b/iommu_group" ]]; then
			echo "AE-7 $b is in group $(basename "$(readlink "$SYS_PCI/$b/iommu_group")")"
		fi
	done
	for g in "${GROUPS_SORTED[@]}"; do
		echo "group $g:"
		for p in "$SYS_GROUPS/$g/devices/"*; do
			d="${p##*/}"
			printf '  %s driver=%s  %s\n' "$d" "$(pci_driver "$d")" "${NAME[$d]:-?}"
		done
	done
} > "$OUT/iommu-groups.txt"

# Record reset and power state of the bridge and each card function.
{
	for b in "$BRIDGE" "${SLOT[@]}"; do
		if [[ -z "$b" ]]; then
			continue
		fi
		printf '%s reset_method=%s driver=%s driver_override=%s power_state=%s d3cold_allowed=%s\n' \
			"$b" "$(pci_attr "$b" reset_method)" "$(pci_driver "$b")" \
			"$(pci_attr "$b" driver_override)" "$(pci_attr "$b" power_state)" \
			"$(pci_attr "$b" d3cold_allowed)"
	done
	if (( ! PRESENT )); then
		echo "AE-7 absent: no card functions"
	fi
} > "$OUT/reset-method.txt"

cat /proc/cmdline > "$OUT/cmdline.txt"
uname -a > "$OUT/kernel.txt"

{
	echo "# lsmod (vfio, snd_hda)"
	lsmod | /usr/bin/grep -E '^(vfio|snd_hda)' || true
	for f in /etc/modprobe.d/ae7-vfio.conf /etc/modprobe.d/blacklist-ca0132.conf; do
		if [[ -r "$f" ]]; then
			echo "# $f"
			cat "$f"
		fi
	done
	if [[ -r /sys/module/vfio_pci/parameters/disable_idle_d3 ]]; then
		echo "# vfio_pci disable_idle_d3=$(cat /sys/module/vfio_pci/parameters/disable_idle_d3)"
	fi
} > "$OUT/modules.txt"

# Kernel log: root dmesg first, then plain dmesg, then the journal.
DMESG="$OUT/dmesg-full.txt"
# shellcheck disable=SC2024 # The output file belongs to the user on purpose.
if sudo -n dmesg > "$DMESG" 2>/dev/null; then
	:
elif dmesg > "$DMESG" 2>/dev/null; then
	note "sudo -n dmesg is not allowed: used plain dmesg"
elif journalctl -k -b --no-pager -o short-monotonic > "$DMESG" 2>/dev/null; then
	note "sudo -n dmesg is not allowed: used journalctl -k for this boot"
else
	: > "$DMESG"
	note "no access to the kernel log (sudo -n dmesg, dmesg and journalctl -k failed)"
fi

pat='AMD-Vi|IOMMU|IO_PAGE_FAULT|AER|vfio|pcieport|1b21|1102'
for b in "$UPSTREAM" "$BRIDGE" "${SLOT[@]}"; do
	if [[ -n "$b" ]]; then
		e="${b//./\\.}"
		pat+="|$e|${e#*:}"
	fi
done
/usr/bin/grep -E -- "$pat" "$DMESG" > "$OUT/dmesg-ae7.txt" || true

log "capture saved in $OUT"
if (( ! PRESENT )); then
	exit 1
fi
