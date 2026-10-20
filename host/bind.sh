#!/usr/bin/env bash
# bind.sh — Check, show or change the vfio-pci binding of all AE-7 slot functions.
#
# Usage: host/bind.sh --check | --status       (read-only, no root)
#        sudo host/bind.sh --bind | --unbind
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../vm/config.sh
source "$HOST_DIR/../vm/config.sh"

SYS_PCI=/sys/bus/pci/devices
SYS_GROUPS=/sys/kernel/iommu_groups
DEV_VFIO=/dev/vfio
ACS_PARAM="pcie_acs_override=downstream,multifunction"

if [[ -t 2 ]]; then
	C_B=$'\033[1;34m' C_Y=$'\033[1;33m' C_R=$'\033[1;31m' C_0=$'\033[0m'
else
	C_B="" C_Y="" C_R="" C_0=""
fi
log()  { printf '%s[bind]%s %s\n' "$C_B" "$C_0" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[err ]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

usage() {
	cat <<-EOF
	Usage: $0 COMMAND
	  --check    read-only; exit 0 only when the AE-7 is ready for passthrough
	  --status   read-only; show drivers, IOMMU group, reset methods, link state
	  --bind     (root) bind every function in the AE-7 slot to vfio-pci
	  --unbind   (root) release every slot function and leave it unbound
	EOF
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

# Print the IOMMU group of device $1, or an empty line when it has none.
pci_group() {
	local link="$SYS_PCI/$1/iommu_group"
	if [[ -L "$link" ]]; then
		basename "$(readlink "$link")"
	else
		echo ""
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

# Print "vvvv:dddd" for device $1.
pci_ids() {
	local v d
	v="$(pci_attr "$1" vendor)"
	d="$(pci_attr "$1" device)"
	echo "${v#0x}:${d#0x}"
}

# Print the class code of device $1 without the 0x prefix.
pci_class() {
	local c
	c="$(pci_attr "$1" class)"
	echo "${c#0x}"
}

# Print one line with the BDF, IDs, class and driver of device $1.
pci_brief() {
	printf '%s [%s] class=%s driver=%s' "$1" "$(pci_ids "$1")" "$(pci_class "$1")" "$(pci_driver "$1")"
}

# Print the lspci name of device $1.
pci_name() {
	lspci -s "$1" 2>/dev/null | cut -d' ' -f2-
}

# Print the parent PCI device of $1. Print nothing when the parent is a root bus.
pci_parent() {
	local p
	p="$(basename "$(dirname "$(readlink -f "$SYS_PCI/$1")")")"
	if [[ "$p" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; then
		echo "$p"
	fi
}

SLOT=()
# Put all functions of the AE-7 slot in SLOT. Return 1 when the card is absent.
find_card() {
	local out
	out="$(ae7_bdfs)" || return 1
	mapfile -t SLOT <<<"$out"
}

# Return 0 when device $1 is a function of the AE-7 slot.
in_slot() {
	local b
	for b in "${SLOT[@]}"; do
		if [[ "$b" == "$1" ]]; then
			return 0
		fi
	done
	return 1
}

# Print the unique IOMMU groups of the slot functions, one per line.
slot_groups() {
	local b g
	for b in "${SLOT[@]}"; do
		g="$(pci_group "$b")"
		if [[ -n "$g" ]]; then
			echo "$g"
		fi
	done | sort -un
}

# Print the devices of IOMMU group $1, one BDF per line.
group_members() {
	local d
	for d in "$SYS_GROUPS/$1/devices/"*; do
		if [[ -e "$d" ]]; then
			echo "${d##*/}"
		fi
	done
}

need_root() {
	[[ "$EUID" -eq 0 ]] || die "needs root: sudo $0 $1"
}

PROBLEMS=0
problem() {
	PROBLEMS=$((PROBLEMS + 1))
	printf 'FAIL: %s\n' "$*" >&2
}

cmd_check() {
	local b g d drv cls groups=() shared=0
	if ! find_card; then
		problem "AE-7 ($AE7_ID) not found on the PCI bus"
		return 1
	fi
	for b in "${SLOT[@]}"; do
		drv="$(pci_driver "$b")"
		if [[ "$drv" != vfio-pci ]]; then
			problem "$b [$(pci_ids "$b")]: driver is '$drv', not vfio-pci (run: sudo $0 --bind)"
		fi
		if [[ -z "$(pci_group "$b")" ]]; then
			problem "$b: no IOMMU group (the IOMMU is off)"
		fi
	done
	mapfile -t groups < <(slot_groups)
	for g in "${groups[@]}"; do
		while IFS= read -r d; do
			if in_slot "$d"; then
				continue
			fi
			drv="$(pci_driver "$d")"
			cls="$(pci_class "$d")"
			# VFIO accepts unbound devices, vfio-pci devices and bridges in the group.
			if [[ "$drv" == - || "$drv" == vfio-pci || "$cls" == 0604* ]]; then
				continue
			fi
			problem "$d [$(pci_ids "$d")] class $cls in group $g is bound to $drv"
			shared=1
		done < <(group_members "$g")
		if [[ ! -e "$DEV_VFIO/$g" ]]; then
			problem "$DEV_VFIO/$g is missing (vfio-pci does not own group $g)"
		fi
	done
	if (( PROBLEMS )); then
		if (( shared )) && ! /usr/bin/grep -q -- "pcie_acs_override" /proc/cmdline; then
			printf 'hint: %s is not in /proc/cmdline (see host/setup.sh)\n' "$ACS_PARAM" >&2
		fi
		return 1
	fi
	printf 'OK: AE-7 ready for passthrough: %s (IOMMU group %s)\n' "${SLOT[*]}" "${groups[*]}"
}

# Print identity and PCIe link state of device $2 under label $1.
print_port() {
	local label="$1" dev="$2"
	printf '%s: %s\n' "$label" "$(pci_brief "$dev")"
	printf '    %s\n' "$(pci_name "$dev")"
	if [[ -r "$SYS_PCI/$dev/current_link_speed" ]]; then
		printf '    link: %s x%s (max %s x%s)\n' \
			"$(pci_attr "$dev" current_link_speed)" "$(pci_attr "$dev" current_link_width)" \
			"$(pci_attr "$dev" max_link_speed)" "$(pci_attr "$dev" max_link_width)"
	else
		echo "    link: not readable"
	fi
}

cmd_status() {
	local b g d br up brs groups=()
	if ! find_card; then
		echo "AE-7 ($AE7_ID): not found on the PCI bus"
		brs="$(lspci -D -n -d "$BRIDGE_ID" | awk '{print $1}' | paste -sd' ')"
		if [[ -n "$brs" ]]; then
			echo "bridge $BRIDGE_ID is present without the card function: $brs"
		fi
		return 1
	fi
	echo "AE-7 slot functions:"
	for b in "${SLOT[@]}"; do
		printf '  %s\n' "$(pci_brief "$b")"
		printf '    %s\n' "$(pci_name "$b")"
		printf '    group=%s reset_method=%s driver_override=%s power_state=%s\n' \
			"$(pci_group "$b")" "$(pci_attr "$b" reset_method)" \
			"$(pci_attr "$b" driver_override | sed 's/(null)/-/')" "$(pci_attr "$b" power_state)"
	done
	br="$(pci_parent "${SLOT[0]}")"
	if [[ -n "$br" ]]; then
		print_port "bridge" "$br"
		if [[ "$(pci_ids "$br")" != "$BRIDGE_ID" ]]; then
			echo "    note: expected bridge $BRIDGE_ID"
		fi
		up="$(pci_parent "$br")"
		if [[ -n "$up" ]]; then
			print_port "upstream port" "$up"
		fi
	fi
	mapfile -t groups < <(slot_groups)
	if (( ${#groups[@]} == 0 )); then
		echo "IOMMU group: none (the IOMMU is off)"
	fi
	for g in "${groups[@]}"; do
		echo "IOMMU group $g:"
		while IFS= read -r d; do
			printf '  %s\n' "$(pci_brief "$d")"
			printf '    %s\n' "$(pci_name "$d")"
		done < <(group_members "$g")
		if [[ -e "$DEV_VFIO/$g" ]]; then
			echo "  $DEV_VFIO/$g: present"
		else
			echo "  $DEV_VFIO/$g: missing"
		fi
	done
	if /usr/bin/grep -q -- "pcie_acs_override" /proc/cmdline; then
		echo "cmdline: pcie_acs_override is active"
	else
		echo "cmdline: pcie_acs_override is not active"
	fi
	if [[ -r /sys/module/vfio_pci/parameters/disable_idle_d3 ]]; then
		echo "vfio-pci: loaded, disable_idle_d3=$(cat /sys/module/vfio_pci/parameters/disable_idle_d3)"
	else
		echo "vfio-pci: not loaded"
	fi
}

cmd_bind() {
	local b drv
	need_root --bind
	find_card || die "AE-7 ($AE7_ID) not found on the PCI bus"
	# Skip the install rule of the guarded claim (host/dkms/install.sh).
	modprobe --ignore-install vfio-pci
	for b in "${SLOT[@]}"; do
		drv="$(pci_driver "$b")"
		if [[ "$drv" == vfio-pci ]]; then
			log "$b: already on vfio-pci"
			continue
		fi
		echo vfio-pci > "$SYS_PCI/$b/driver_override"
		if [[ "$drv" != - ]]; then
			if [[ "$drv" == snd_hda_intel ]]; then
				warn "$b: snd_hda_intel holds the card; the unbind can hang the host"
			fi
			log "$b: unbind from $drv"
			echo "$b" > "$SYS_PCI/$b/driver/unbind"
		fi
		if ! echo "$b" > /sys/bus/pci/drivers_probe; then
			warn "$b: drivers_probe failed"
		fi
		drv="$(pci_driver "$b")"
		if [[ "$drv" == vfio-pci ]]; then
			log "$b: bound to vfio-pci"
		else
			warn "$b: driver is '$drv' after probe (see: sudo dmesg | tail)"
		fi
	done
	cmd_check
}

cmd_unbind() {
	local b drv
	need_root --unbind
	find_card || die "AE-7 ($AE7_ID) not found on the PCI bus"
	log "a VM that uses the card blocks the unbind until the VM stops"
	for b in "${SLOT[@]}"; do
		# An empty write clears driver_override.
		echo > "$SYS_PCI/$b/driver_override"
		drv="$(pci_driver "$b")"
		if [[ "$drv" == - ]]; then
			log "$b: already unbound"
			continue
		fi
		log "$b: unbind from $drv"
		echo "$b" > "$SYS_PCI/$b/driver/unbind"
	done
	warn "The AE-7 is now unbound. Do NOT let snd_hda_intel probe it: on this host"
	warn "that destabilized the chipset (sibling xHCI/AHCI died). A reload of the"
	warn "snd_hda_intel module binds it. To return it to vfio-pci: sudo $0 --bind"
}

command -v lspci >/dev/null 2>&1 || die "lspci not found (pacman -S pciutils)"

case "${1:-}" in
	--check)  cmd_check ;;
	--status) cmd_status ;;
	--bind)   cmd_bind ;;
	--unbind) cmd_unbind ;;
	-h|--help) usage ;;
	*) usage >&2; exit 2 ;;
esac
