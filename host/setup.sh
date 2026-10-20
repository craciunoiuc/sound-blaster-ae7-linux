#!/usr/bin/env bash
# setup.sh — One-time host setup for AE-7 VFIO passthrough (modprobe + sudoers).
#
# Usage: sudo host/setup.sh [--dry-run] [--undo] [--user NAME]
# The script never edits the bootloader config; it prints the commands instead.
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../vm/config.sh
source "$HOST_DIR/../vm/config.sh"

MODPROBE_CONF=/etc/modprobe.d/ae7-vfio.conf
SUDOERS_FILE=/etc/sudoers.d/ae7-vm
OLD_BLACKLIST=/etc/modprobe.d/blacklist-ca0132.conf
LIMINE_DEFAULT=/etc/default/limine
KERNEL_CMDLINE=/etc/kernel/cmdline
MKINITCPIO_CONF=/etc/mkinitcpio.conf
ACS_PARAM="pcie_acs_override=downstream,multifunction"
MARKER="# Installed by ae7-investigation host/setup.sh. Remove with: host/setup.sh --undo"

if [[ -t 2 ]]; then
	C_B=$'\033[1;34m' C_Y=$'\033[1;33m' C_R=$'\033[1;31m' C_0=$'\033[0m'
else
	C_B="" C_Y="" C_R="" C_0=""
fi
log()  { printf '%s[setup]%s %s\n' "$C_B" "$C_0" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[err ]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

usage() {
	cat <<-EOF
	Usage: sudo $0 [--dry-run] [--undo] [--user NAME]
	  --dry-run   show the actions and change nothing (root is not necessary)
	  --undo      remove the files that this script installs
	  --user NAME user for the sudoers rule (default: \$SUDO_USER)
	EOF
}

DRY=0
UNDO=0
TARGET_USER=""
while (( $# )); do
	case "$1" in
		--dry-run) DRY=1 ;;
		--undo)    UNDO=1 ;;
		--user)    [[ $# -ge 2 ]] || die "--user needs a name"; TARGET_USER="$2"; shift ;;
		-h|--help) usage; exit 0 ;;
		*)         usage >&2; die "unknown option: $1" ;;
	esac
	shift
done
if (( ! DRY )) && [[ "$EUID" -ne 0 ]]; then
	die "needs root: sudo $0 (or use --dry-run)"
fi

CHANGES=()   # actions done, or planned in a dry run
STEPS=()     # manual next steps for the user
TMPFILES=()
cleanup() {
	if (( ${#TMPFILES[@]} )); then
		rm -f -- "${TMPFILES[@]}"
	fi
}
trap cleanup EXIT

# Record action $* for the summary and log it.
act() {
	CHANGES+=("$*")
	log "$*"
}

if command -v limine-mkinitcpio >/dev/null 2>&1; then
	REBUILD="sudo limine-mkinitcpio"
else
	REBUILD="sudo mkinitcpio -P"
fi

# Validate sudoers file $1 without installing it.
check_sudoers() {
	visudo -qcf "$1" >/dev/null
}

# Install text $3 as file $1 with mode $2 through a temp file and a rename.
# Optional function $4 must accept the temp file before the install.
write_file() {
	local dest="$1" mode="$2" content="$3" check="${4:-}" dir tmp verb="create"
	if [[ -r "$dest" ]]; then
		if [[ "$(cat -- "$dest")" == "$content" ]]; then
			log "$dest: already up to date"
			return 0
		fi
		verb="replace"
	elif [[ ! -r "$(dirname -- "$dest")" ]]; then
		log "$(dirname -- "$dest") is not readable as $(id -un); $dest can already exist"
	fi
	# modprobe.d and sudoers.d ignore file names that start with a dot.
	if (( DRY )); then
		dir="${TMPDIR:-/tmp}"
	else
		dir="$(dirname -- "$dest")"
	fi
	tmp="$(mktemp "$dir/.ae7-setup.XXXXXX")"
	TMPFILES+=("$tmp")
	printf '%s\n' "$content" > "$tmp"
	chmod "$mode" "$tmp"
	if [[ -n "$check" ]] && ! "$check" "$tmp"; then
		die "$dest: the generated file is not valid; nothing installed"
	fi
	if (( DRY )); then
		act "would $verb $dest (mode $mode)"
		sed 's/^/        /' "$tmp" >&2
		return 0
	fi
	chown root:root "$tmp"
	mv -f -- "$tmp" "$dest"
	act "${verb}d $dest (mode $mode)"
}

# Remove file $1 when it exists; $2 tells why.
remove_file() {
	local f="$1" why="$2"
	if [[ -e "$f" ]]; then
		if (( DRY )); then
			act "would remove $f ($why)"
		else
			rm -f -- "$f"
			act "removed $f ($why)"
		fi
	elif [[ ! -r "$(dirname -- "$f")" ]]; then
		log "$f: cannot check as $(id -un); with root it is removed if present"
	else
		log "$f: not present"
	fi
}

report_host() {
	local n out b
	n="$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
	if (( n == 0 )); then
		warn "the IOMMU is off: enable IOMMU in firmware and add amd_iommu=on"
		STEPS+=("Turn the IOMMU on (firmware + amd_iommu=on) and reboot")
	else
		log "IOMMU is on ($n groups)"
	fi
	if out="$(ae7_bdfs)"; then
		log "AE-7 found: $(paste -sd' ' <<<"$out")"
		while IFS= read -r b; do
			if [[ "$(readlink "/sys/bus/pci/devices/$b/driver" 2>/dev/null)" == */snd_hda_intel ]]; then
				warn "snd_hda_intel holds $b now; this can destabilize the chipset"
			fi
		done <<<"$out"
	else
		log "AE-7 is not plugged in; the config applies at the next boot with the card"
	fi
}

setup_modprobe() {
	local where
	where="$(modinfo -F filename vfio-pci 2>/dev/null || true)"
	if [[ -z "$where" ]]; then
		warn "no vfio-pci module for kernel $(uname -r)"
	elif [[ "$where" == "(builtin)" ]]; then
		warn "vfio-pci is built in: modprobe options do not apply to it"
		STEPS+=("Add vfio-pci.ids=$AE7_ID vfio-pci.disable_idle_d3=1 to the kernel cmdline")
	fi
	# Keep the guarded claim of host/dkms/install.sh; it frees the card for the patched driver.
	if /usr/bin/grep -qs 'host/dkms/install.sh' "$MODPROBE_CONF"; then
		log "$MODPROBE_CONF: guarded claim from host/dkms/install.sh, not changed"
		remove_file "$OLD_BLACKLIST" "obsolete global snd_hda_intel blacklist"
		return 0
	fi
	write_file "$MODPROBE_CONF" 0644 "$MARKER
# vfio-pci claims the AE-7 first, so snd_hda_intel never probes it.
options vfio-pci ids=$AE7_ID disable_idle_d3=1
softdep snd_hda_intel pre: vfio-pci"
	remove_file "$OLD_BLACKLIST" "obsolete global snd_hda_intel blacklist"
}

check_initramfs() {
	local img list imgs=() hda=() vfio=() modconf=1
	if ! /usr/bin/grep -Eq '^[^#]*HOOKS=.*\bmodconf\b' "$MKINITCPIO_CONF" 2>/dev/null; then
		modconf=0
	fi
	if [[ ! -r /boot ]] || ! command -v lsinitcpio >/dev/null 2>&1; then
		warn "initramfs check skipped (needs root and lsinitcpio): sudo $0 --dry-run"
		return 0
	fi
	mapfile -d '' -t imgs < <(find /boot -maxdepth 3 -type f -name 'initramfs-*' -print0 2>/dev/null)
	if (( ${#imgs[@]} == 0 )); then
		warn "no initramfs images found under /boot"
		return 0
	fi
	for img in "${imgs[@]}"; do
		if ! list="$(lsinitcpio "$img" 2>/dev/null)"; then
			warn "cannot list $img"
			continue
		fi
		if /usr/bin/grep -q '/snd-hda-intel\.ko' <<<"$list"; then
			hda+=("$img")
		fi
		if /usr/bin/grep -q '/vfio-pci\.ko' <<<"$list"; then
			vfio+=("$img")
		fi
	done
	if (( ${#hda[@]} )); then
		warn "snd-hda-intel is in the initramfs: ${hda[*]}"
		STEPS+=("Add vfio-pci to the initramfs: add vfio_pci vfio vfio_iommu_type1 to MODULES=() in $MKINITCPIO_CONF, then run: $REBUILD")
	elif (( ${#vfio[@]} )); then
		log "vfio-pci is in the initramfs: ${vfio[*]}"
		STEPS+=("Rebuild the initramfs so that it holds the new vfio-pci options: $REBUILD")
	else
		log "initramfs: no snd-hda-intel and no vfio-pci; no rebuild necessary"
	fi
	if (( ${#hda[@]} + ${#vfio[@]} )) && (( ! modconf )); then
		warn "HOOKS in $MKINITCPIO_CONF has no modconf: the initramfs does not get $MODPROBE_CONF"
		STEPS+=("Add modconf to HOOKS in $MKINITCPIO_CONF, or add vfio-pci.ids=$AE7_ID to the cmdline")
	fi
}

SUDO_RULE_USER=""
SUDO_RULE_QEMU=""
SUDO_RULE=""
# Find the user and binary paths for the sudoers rule before the script changes files.
resolve_sudo_rule() {
	local user="$TARGET_USER" dmesg_bin lspci_bin p tmp
	if [[ -z "$user" ]]; then
		user="${SUDO_USER:-}"
	fi
	if [[ -z "$user" ]] && (( DRY )); then
		user="$(id -un)"
	fi
	if [[ -z "$user" || "$user" == root ]]; then
		die "cannot find the target user: run through sudo from your account, or pass --user NAME"
	fi
	[[ "$user" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || die "user name not safe for sudoers: $user"
	id -u -- "$user" >/dev/null 2>&1 || die "no such user: $user"
	SUDO_RULE_QEMU="$(command -v -- "$QEMU" || true)"
	dmesg_bin="$(command -v dmesg || true)"
	lspci_bin="$(command -v lspci || true)"
	for p in "$SUDO_RULE_QEMU" "$dmesg_bin" "$lspci_bin"; do
		# sudoers needs plain absolute paths; commas and spaces break the rule.
		[[ "$p" =~ ^/[A-Za-z0-9._/+-]+$ ]] || die "need plain absolute paths for $QEMU, dmesg, lspci (got '$p')"
	done
	SUDO_RULE_USER="$user"
	# QEMU drops root after start; it needs this limit to pin guest RAM for vfio.
	SUDO_RULE="Defaults!$SUDO_RULE_QEMU rlimit_memlock=infinity
$user ALL=(root) NOPASSWD: $SUDO_RULE_QEMU, $dmesg_bin, $lspci_bin"
	tmp="$(mktemp)"
	TMPFILES+=("$tmp")
	printf '%s\n' "$SUDO_RULE" > "$tmp"
	chmod 0440 "$tmp"
	check_sudoers "$tmp" || die "the sudoers rule is not valid: $SUDO_RULE"
}

setup_sudoers() {
	write_file "$SUDOERS_FILE" 0440 "$MARKER
$SUDO_RULE" check_sudoers
	if (( ! DRY )) && ! visudo -qc >/dev/null 2>&1; then
		rm -f -- "$SUDOERS_FILE"
		die "the full sudoers check fails with $SUDOERS_FILE; removed it again"
	fi
	warn "$SUDO_RULE_USER can run $SUDO_RULE_QEMU as root without a password; that is root access."
	warn "Remove it with: sudo $0 --undo"
}

# Show the cmdline change for ACS override when it is not active.
cmdline_advice() {
	local f configured=0 any=0
	if /usr/bin/grep -qw splash /proc/cmdline; then
		warn "the running cmdline has 'splash': remove it (Plymouth blocks the boot)"
	fi
	for f in "$LIMINE_DEFAULT" "$KERNEL_CMDLINE"; do
		if [[ ! -r "$f" ]]; then
			continue
		fi
		any=1
		if /usr/bin/grep -Eq '^[^#]*\bsplash\b' "$f"; then
			warn "$f has 'splash': remove it (Plymouth blocks the boot)"
		fi
		if /usr/bin/grep -Eq '^[^#]*pcie_acs_override=' "$f"; then
			configured=1
			log "$f already sets: $(/usr/bin/grep -Eo 'pcie_acs_override=[^ "]*' "$f" | head -n1)"
		fi
	done
	if /usr/bin/grep -q -- "$ACS_PARAM" /proc/cmdline; then
		log "cmdline: $ACS_PARAM is active"
		return 0
	fi
	if (( configured )); then
		STEPS+=("Run 'sudo limine-update' if not done yet, then reboot (pcie_acs_override is set but not active)")
		return 0
	fi
	echo
	echo "== Kernel cmdline change (not applied by this script) =="
	echo "Add $ACS_PARAM (keep 'splash' out):"
	if [[ -f "$LIMINE_DEFAULT" ]]; then
		echo "  echo 'KERNEL_CMDLINE[default]+=\" $ACS_PARAM\"' | sudo tee -a $LIMINE_DEFAULT"
		echo "  sudo limine-update"
	fi
	if [[ -f "$KERNEL_CMDLINE" ]]; then
		echo "  sudo sed -i '1s/\$/ $ACS_PARAM/' $KERNEL_CMDLINE"
		if command -v limine-update >/dev/null 2>&1; then
			echo "  sudo limine-update"
		else
			echo "  then regenerate the boot entries or UKI for your bootloader"
		fi
	fi
	if (( ! any )); then
		echo "  (no $LIMINE_DEFAULT or $KERNEL_CMDLINE: add it to your bootloader's kernel cmdline)"
	fi
	echo "  then reboot"
	STEPS+=("Apply the kernel cmdline change above (pcie_acs_override)")
}

undo_advice() {
	local f
	for f in "$LIMINE_DEFAULT" "$KERNEL_CMDLINE"; do
		if [[ -r "$f" ]] && /usr/bin/grep -Eq '^[^#]*pcie_acs_override=' "$f"; then
			STEPS+=("If ACS override is not needed: remove pcie_acs_override from $f, run 'sudo limine-update', reboot")
		fi
	done
	if /usr/bin/grep -Eq '^[^#]*MODULES=.*vfio' "$MKINITCPIO_CONF" 2>/dev/null; then
		STEPS+=("Remove vfio modules from MODULES in $MKINITCPIO_CONF, then run: $REBUILD")
	else
		STEPS+=("If the initramfs holds vfio-pci, rebuild it: $REBUILD")
	fi
	warn "Without $MODPROBE_CONF, snd_hda_intel probes the AE-7 at the next boot."
	warn "That destabilized the chipset before. Remove the card first, or block"
	warn "snd_hda_intel for all devices (onboard audio stops too):"
	warn "  printf 'blacklist snd_hda_intel\\ninstall snd_hda_intel /bin/false\\n' | sudo tee $OLD_BLACKLIST"
}

summary() {
	local i
	echo
	if (( DRY )); then
		echo "== Dry run: nothing changed. Planned actions =="
	else
		echo "== Summary =="
	fi
	if (( ${#CHANGES[@]} == 0 )); then
		echo "  no changes"
	fi
	for i in "${CHANGES[@]}"; do
		echo "  - $i"
	done
	echo
	echo "== Next steps (in $REPO) =="
	if (( ! UNDO )); then
		STEPS+=("Reboot")
		STEPS+=("host/bind.sh --check   (expect 'OK: AE-7 ready for passthrough')")
		STEPS+=("host/capture.sh        (saves logs/capture-<time>/)")
	fi
	for i in "${!STEPS[@]}"; do
		echo "  $((i + 1)). ${STEPS[$i]}"
	done
}

if (( DRY )); then
	log "dry run: no change is made"
fi
if (( UNDO )); then
	remove_file "$MODPROBE_CONF" "AE-7 vfio-pci claim"
	remove_file "$SUDOERS_FILE" "passwordless qemu, dmesg, lspci"
	undo_advice
else
	resolve_sudo_rule
	report_host
	setup_modprobe
	check_initramfs
	setup_sudoers
	cmdline_advice
fi
summary
