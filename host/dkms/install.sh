#!/usr/bin/env bash
# install.sh — install or remove the ae7-hda DKMS package on the host.
#
# Usage: sudo host/dkms/install.sh [--uninstall]
#
# Install: run host/dkms/mkdkms.sh first (as your user). Then this replaces any
# installed ae7-hda version, builds it for each kernel with headers, and changes
# the vfio-pci claim so that it stands down only for kernels with the patched
# modules. DKMS builds it for new kernels on its own (network needed).
# Uninstall: removes the package and restores the plain vfio-pci claim.
set -euo pipefail

# shellcheck source=vm/config.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../vm/config.sh"

CONF=/etc/modprobe.d/ae7-vfio.conf

log() { printf '[ae7-hda] %s\n' "$*" >&2; }
die() { printf '[ae7-hda] error: %s\n' "$*" >&2; exit 1; }

mode=install
while (($#)); do
	case "$1" in
	--uninstall) mode=uninstall ;;
	-h | --help) sed -n '3,10s/^# \{0,1\}//p' "$0"; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
	shift
done
((EUID == 0)) || die "needs root: sudo $0"
command -v dkms >/dev/null || die "dkms not found (pacman -S dkms)"

# Remove every ae7-hda version from DKMS and its sources from /usr/src.
remove_all() {
	local v
	for v in $(dkms status ae7-hda 2>/dev/null | sed -nE 's|^ae7-hda/([^,: ]+).*|\1|p' | sort -u); do
		log "remove ae7-hda/$v"
		dkms remove "ae7-hda/$v" --all || true
	done
	rm -rf /usr/src/ae7-hda-*
}

if [[ $mode == uninstall ]]; then
	remove_all
	log "removed ae7-hda; restore the plain vfio-pci claim"
	rm -f "$CONF"
	"$REPO/host/setup.sh" --user "${SUDO_USER:-$(logname)}"
	log "done. Reboot: the stock driver stays away from the card (vfio-pci claims it)."
	exit 0
fi

src="$VM_DIR/build/dkms/ae7-hda"
[[ -f $src/dkms.conf ]] || die "no $src; run host/dkms/mkdkms.sh first (as your user)"
ver="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "$src/dkms.conf")"
[[ -n $ver ]] || die "no PACKAGE_VERSION in $src/dkms.conf"
pkg="ae7-hda/$ver"

# vfio-pci claims the card unless this kernel has all four patched modules.
tmp="$(mktemp "$CONF.XXXXXX")"
cat >"$tmp" <<'EOF'
# Installed by ae7-investigation host/dkms/install.sh. Undo: host/dkms/install.sh --uninstall
# vfio-pci claims the AE-7 so the stock driver never probes it, unless all four
# patched ae7-hda modules (DKMS, updates/dkms) exist for the running kernel.
options vfio-pci ids=1102:0010 disable_idle_d3=1
softdep snd_hda_intel pre: vfio-pci
install vfio-pci cd /usr/lib/modules/$(uname -r)/updates/dkms 2>/dev/null && ls snd-hda-core.ko* snd-hda-codec.ko* snd-hda-intel.ko* snd-hda-codec-ca0132.ko* >/dev/null 2>&1 || /sbin/modprobe --ignore-install vfio-pci $CMDLINE_OPTS
EOF
chmod 0644 "$tmp"
mv -f "$tmp" "$CONF"
log "wrote $CONF (guarded vfio-pci claim)"

# True if modprobe picks the tagged ae7-hda build of all four modules for kernel $1.
verify() {
	local m path
	for m in snd-hda-core snd-hda-codec snd-hda-intel snd-hda-codec-ca0132; do
		path="$(modinfo -k "$1" -n "$m" 2>/dev/null)" || { log "$1: no $m"; return 1; }
		[[ $path == */updates/* && -n $(modinfo -F ae7_hda "$path") ]] ||
			{ log "$1: modprobe picks $path for $m, not the ae7-hda build"; return 1; }
	done
	modinfo -k "$1" -F parm snd-hda-intel | /usr/bin/grep -q '^flush_writes:' ||
		{ log "$1: snd-hda-intel has no flush_writes parameter"; return 1; }
}

remove_all
cp -r "$src" "/usr/src/ae7-hda-$ver"
dkms add "$pkg"
built=()
for kdir in /usr/lib/modules/*/build; do
	[[ -f $kdir/.config ]] || continue
	k="${kdir%/build}" k="${k##*/}"
	if ! dkms install "$pkg" -k "$k"; then
		log "WARNING: no build for $k; there the card stays on vfio-pci"
	elif ! verify "$k"; then
		dkms uninstall "$pkg" -k "$k" || true
		log "WARNING: removed the incomplete build for $k; there the card stays on vfio-pci"
	else
		built+=("$k")
		log "ae7-hda modules for $k: OK"
	fi
done
[[ " ${built[*]} " == *" $(uname -r) "* ]] ||
	log "WARNING: no modules for the running kernel $(uname -r)"

# A stock snd-hda-intel in the initramfs would load before the DKMS one.
found=0
while IFS= read -r img; do
	if command -v lsinitcpio >/dev/null && lsinitcpio -l "$img" 2>/dev/null | /usr/bin/grep -q 'snd-hda-intel'; then
		log "WARNING: $img contains snd-hda-intel; rebuild it: sudo limine-mkinitcpio"
		found=1
	fi
done < <(find /boot -maxdepth 3 -name 'initramfs-*.img' 2>/dev/null)
((found)) || log "initramfs images do not contain snd-hda-intel (good)"

log "done. Next: sync, then reboot and stay at the machine."
