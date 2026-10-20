#!/usr/bin/env bash
# vm/kernel/build.sh — configure and build the guest kernel out of tree in
# $BUILD_DIR, then install stripped modules into $MODROOT/lib/modules.
set -euo pipefail

# shellcheck source=../config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"

FRAGMENT="$VM_DIR/kernel/ae7.config"
KVM_FRAGMENT="$LINUX_SRC/kernel/configs/kvm_guest.config"
DEFCONFIG="$LINUX_SRC/arch/x86/configs/x86_64_defconfig"
STAMP="$BUILD_DIR/.ae7-config.sha256"
MOD_STAGE="$MODROOT.stage"

RECONFIG=0
CONFIG_ONLY=0
MODULES_ONLY=0

usage() {
	cat <<-EOF
	Usage: ${0##*/} [--reconfig] [--config-only] [--modules]

	Build $LINUX_SRC in $BUILD_DIR and install modules to $MODROOT.
	The .config is made again (defconfig + kvm_guest.config + ae7.config)
	if it is missing, if the fragments changed, or with --reconfig.

	  --reconfig     make the .config again from the fragments
	  --config-only  stop after the .config is made and checked
	  --modules      build and install modules only (no bzImage link);
	                 use it only when no built-in code changed
	EOF
}

die() { echo "build.sh: error: $*" >&2; exit 1; }
log() { echo "build.sh: $*"; }

for arg in "$@"; do
	case "$arg" in
	--reconfig) RECONFIG=1 ;;
	--config-only) CONFIG_ONLY=1 ;;
	--modules) MODULES_ONLY=1 ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done

[[ -f "$LINUX_SRC/Makefile" ]] || die "no kernel tree in $LINUX_SRC (run vm/kernel/fetch.sh)"

start=$SECONDS
mkdir -p "$BUILD_DIR"

# Only one build at a time in $BUILD_DIR.
exec 9>"$BUILD_DIR/.build.lock"
if ! flock -n 9; then
	log "waiting for another build in $BUILD_DIR"
	flock 9
fi

# An empty LOCALVERSION stops setlocalversion from adding "+" for the patched tree.
kmake() { make -C "$LINUX_SRC" O="$BUILD_DIR" LOCALVERSION= "$@"; }

configure() {
	log "making .config: defconfig + kvm_guest.config + ae7.config"
	kmake defconfig
	(cd "$BUILD_DIR" && "$LINUX_SRC/scripts/kconfig/merge_config.sh" -m \
		.config "$KVM_FRAGMENT" "$FRAGMENT")
	kmake olddefconfig
	echo "$want_stamp" >"$STAMP"
}

# Print each fragment line that the final .config does not have.
check_config() {
	local line sym want have bad=0
	while IFS= read -r line; do
		if [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_]+)=(.*)$ ]]; then
			sym="${BASH_REMATCH[1]}" want="${BASH_REMATCH[2]}"
		elif [[ "$line" =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
			sym="${BASH_REMATCH[1]}" want=n
		else
			continue
		fi
		have="$(/usr/bin/grep -m1 "^$sym=" "$BUILD_DIR/.config" | cut -d= -f2- || true)"
		have="${have:-n}"
		if [[ "$have" != "$want" ]]; then
			echo "  $sym: want $want, have $have" >&2
			bad=1
		fi
	done <"$FRAGMENT"
	return "$bad"
}

want_stamp="$(cat "$FRAGMENT" "$KVM_FRAGMENT" "$DEFCONFIG" | sha256sum | cut -d' ' -f1)"
if ((RECONFIG)) || [[ ! -f "$BUILD_DIR/.config" ]] ||
	[[ "$(cat "$STAMP" 2>/dev/null || true)" != "$want_stamp" ]]; then
	configure
fi

if ! check_config; then
	die "the .config does not have the ae7.config values above (bad name or unmet dependency)"
fi
log "all ae7.config values are in $BUILD_DIR/.config"
((CONFIG_ONLY)) && exit 0

if ((MODULES_ONLY)); then
	kmake -j"$JOBS" modules
else
	kmake -j"$JOBS" bzImage modules
fi
krel="$(cat "$BUILD_DIR/include/config/kernel.release")"

# Install to a stage dir, then sync, so that a running guest sees no empty dir.
rm -rf "$MOD_STAGE"
kmake -s modules_install INSTALL_MOD_PATH="$MOD_STAGE" INSTALL_MOD_STRIP=1
depmod -a -b "$MOD_STAGE" "$krel"
mkdir -p "$MODROOT/lib/modules"
rsync -a --delete "$MOD_STAGE/lib/modules/" "$MODROOT/lib/modules/"
rm -rf "$MOD_STAGE"

moddir="$MODROOT/lib/modules/$krel"
for m in snd-hda-intel snd-hda-codec-ca0132 snd-hda-codec-generic; do
	/usr/bin/grep -q "/$m.ko:" "$moddir/modules.dep" || die "$m.ko is not in $moddir/modules.dep"
done

[[ -f "$BZIMAGE" ]] || log "warning: no bzImage yet (run without --modules)"
log "bzImage: $BZIMAGE"
log "release: $krel"
log "modules: $moddir ($(/usr/bin/grep -c . "$moddir/modules.dep") modules)"
log "elapsed: $((SECONDS - start))s"
