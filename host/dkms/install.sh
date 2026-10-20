#!/usr/bin/env bash
# install.sh — install or remove the ae7-hda DKMS modules on the host.
#
# Usage: sudo host/dkms/install.sh [--uninstall] [--kernel RELEASE]
#
# Install: run host/dkms/mkdkms.sh first (as your user). Then this adds the
# DKMS package, builds and installs it, and changes the vfio-pci claim so that
# it stands down only for kernels that have the patched modules.
# Uninstall: removes the package and restores the plain vfio-pci claim.
set -euo pipefail

# shellcheck source=vm/config.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../vm/config.sh"

CONF=/etc/modprobe.d/ae7-vfio.conf

log() { printf '[ae7-hda] %s\n' "$*" >&2; }
die() { printf '[ae7-hda] error: %s\n' "$*" >&2; exit 1; }

krel="$(uname -r)" mode=install
while (($#)); do
	case "$1" in
	--uninstall) mode=uninstall ;;
	--kernel) krel="${2:?--kernel needs a value}"; shift ;;
	-h | --help) sed -n '3,9s/^# \{0,1\}//p' "$0"; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
	shift
done
((EUID == 0)) || die "needs root: sudo $0"
command -v dkms >/dev/null || die "dkms not found (pacman -S dkms)"
ver="${krel%%-*}"
pkg="ae7-hda/$ver"

if [[ $mode == uninstall ]]; then
	dkms status "$pkg" 2>/dev/null | /usr/bin/grep -q . && dkms remove "$pkg" --all
	rm -rf "/usr/src/ae7-hda-$ver"
	depmod -a "$krel"
	log "removed $pkg; restore the plain vfio-pci claim"
	rm -f "$CONF"
	"$REPO/host/setup.sh" --user "${SUDO_USER:-$(logname)}"
	log "done. Reboot: the stock driver stays away from the card (vfio-pci claims it)."
	exit 0
fi

src="$VM_DIR/build/dkms/ae7-hda-$ver"
[[ -f $src/dkms.conf ]] || die "no $src; run host/dkms/mkdkms.sh --kernel $krel first (as your user)"

if dkms status "$pkg" 2>/dev/null | /usr/bin/grep -q .; then
	log "remove the old $pkg first"
	dkms remove "$pkg" --all
fi
rm -rf "/usr/src/ae7-hda-$ver"
cp -r "$src" "/usr/src/ae7-hda-$ver"
dkms add "$pkg"
dkms build "$pkg" -k "$krel"
dkms install "$pkg" -k "$krel" --force
depmod -a "$krel"

path="$(modinfo -k "$krel" -n snd-hda-intel)"
[[ $path == */updates/* ]] || die "modprobe still picks $path, not the DKMS module"
modinfo -k "$krel" -F parm snd-hda-intel | /usr/bin/grep -q '^flush_writes:' ||
	die "installed snd-hda-intel has no flush_writes parameter"
log "snd-hda-intel for $krel: $path"

# vfio-pci claims the card unless this kernel has the patched modules.
tmp="$(mktemp "$CONF.XXXXXX")"
cat >"$tmp" <<'EOF'
# Installed by ae7-investigation host/dkms/install.sh. Undo: host/dkms/install.sh --uninstall
# vfio-pci claims the AE-7 so the stock driver never probes it, unless the
# patched ae7-hda modules (DKMS, updates/dkms) exist for the running kernel.
options vfio-pci ids=1102:0010 disable_idle_d3=1
softdep snd_hda_intel pre: vfio-pci
install vfio-pci ls /usr/lib/modules/$(uname -r)/updates/dkms/snd-hda-intel.ko* >/dev/null 2>&1 || /sbin/modprobe --ignore-install vfio-pci $CMDLINE_OPTS
EOF
chmod 0644 "$tmp"
mv -f "$tmp" "$CONF"
log "wrote $CONF (guarded vfio-pci claim)"

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
