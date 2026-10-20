#!/usr/bin/env bash
# mkdkms.sh — make the ae7-hda DKMS source tree for one host kernel and test-build it.
#
# Usage: host/dkms/mkdkms.sh [--kernel RELEASE] [--no-build]
#
# Takes linux-stable at the kernel's base version, applies only the fix patches
# (vm/patches/0002, 0003), and writes vm/build/dkms/ae7-hda-<ver>/. No root needed.
set -euo pipefail

# shellcheck source=vm/config.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../vm/config.sh"

FIX_PATCHES=(0002 0003)	# Fix only; 0001 and 0004 are debug aids.

log() { printf '[mkdkms] %s\n' "$*" >&2; }
die() { printf '[mkdkms] error: %s\n' "$*" >&2; exit 1; }

krel="$(uname -r)" build=1
while (($#)); do
	case "$1" in
	--kernel) krel="${2:?--kernel needs a value}"; shift ;;
	--no-build) build=0 ;;
	-h | --help) sed -n '3,7s/^# \{0,1\}//p' "$0"; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
	shift
done

kdir="/usr/lib/modules/$krel/build"
[[ -f $kdir/.config ]] || die "no headers for $krel ($kdir); install the matching -headers package"
base="${krel%%-*}"	# 7.2.10-1-cachyos -> 7.2.10
[[ $base =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "cannot get the base version from $krel"
tag="v$base"
ver="$base"
out="$VM_DIR/build/dkms/ae7-hda-$ver"

[[ -d $LINUX_SRC/.git ]] || die "no $LINUX_SRC; run vm/kernel/fetch.sh first"
if ! git -C "$LINUX_SRC" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
	log "fetch $tag"
	git -C "$LINUX_SRC" fetch -q --depth 1 origin tag "$tag"
fi

wt="$(mktemp -d)"
cleanup() { git -C "$LINUX_SRC" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"; }
trap cleanup EXIT
git -C "$LINUX_SRC" worktree add -q --detach "$wt" "$tag"
name="$(git -C "$REPO" config user.name || echo ae7)"
email="$(git -C "$REPO" config user.email || echo ae7@localhost)"
for n in "${FIX_PATCHES[@]}"; do
	p=("$VM_DIR"/patches/"$n"-*.patch)
	[[ -f ${p[0]} ]] || die "missing patch $n in vm/patches"
	git -C "$wt" -c user.name="$name" -c user.email="$email" am -q "${p[0]}" ||
		die "patch ${p[0]##*/} does not apply on $tag"
	log "applied ${p[0]##*/}"
done

# Copy only the sources of the four modules, with our own Kbuild files.
rm -rf "$out"
mkdir -p "$out"/{include/sound,core,common,controllers,codecs}
cp "$wt"/include/sound/hdaudio.h "$out"/include/sound/
cp "$wt"/sound/hda/core/*.[ch] "$out"/core/
cp "$wt"/sound/hda/common/*.[ch] "$out"/common/
cp "$wt"/sound/hda/controllers/intel{.c,.h,_trace.h} "$out"/controllers/
cp "$wt"/sound/hda/codecs/{ca0132.c,ca0132_regs.h,generic.h} "$out"/codecs/

# The patched hdaudio.h must come before the kernel copy, so put it in NOSTDINC_FLAGS.
inc='NOSTDINC_FLAGS += -I$(src)/../include'
cat >"$out"/Kbuild <<'EOF'
obj-m += core/ common/ controllers/ codecs/
EOF
cat >"$out"/core/Kbuild <<EOF
$inc
snd-hda-core-y := hda_bus_type.o bus.o device.o sysfs.o regmap.o controller.o \\
	stream.o array.o hdmi_chmap.o trace.o
snd-hda-core-\$(CONFIG_SND_HDA_COMPONENT) += component.o
snd-hda-core-\$(CONFIG_SND_HDA_I915) += i915.o
CFLAGS_trace.o := -I\$(src)
obj-m += snd-hda-core.o
EOF
cat >"$out"/common/Kbuild <<EOF
$inc
snd-hda-codec-y := bind.o codec.o jack.o auto_parser.o sysfs.o controller.o
snd-hda-codec-\$(CONFIG_SND_PROC_FS) += proc.o
snd-hda-codec-\$(CONFIG_SND_HDA_HWDEP) += hwdep.o
snd-hda-codec-\$(CONFIG_SND_HDA_INPUT_BEEP) += beep.o
CFLAGS_controller.o := -I\$(src)
obj-m += snd-hda-codec.o
EOF
cat >"$out"/controllers/Kbuild <<EOF
$inc
ccflags-y += -I\$(src)/../common
CFLAGS_intel.o := -I\$(src)
snd-hda-intel-y := intel.o
obj-m += snd-hda-intel.o
EOF
cat >"$out"/codecs/Kbuild <<EOF
$inc
ccflags-y += -I\$(src)/../common
snd-hda-codec-ca0132-y := ca0132.o
obj-m += snd-hda-codec-ca0132.o
EOF

llvm=""
/usr/bin/grep -q '^CONFIG_CC_IS_CLANG=y' "$kdir/.config" && llvm=" LLVM=1"
kre="${base//./\\.}"
cat >"$out"/dkms.conf <<EOF
PACKAGE_NAME="ae7-hda"
PACKAGE_VERSION="$ver"
# Sources are linux $tag; build only for that kernel version.
BUILD_EXCLUSIVE_KERNEL="^$kre-"
AUTOINSTALL="yes"
MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build$llvm modules"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"
BUILT_MODULE_NAME[0]="snd-hda-core"
BUILT_MODULE_LOCATION[0]="core/"
DEST_MODULE_LOCATION[0]="/updates/dkms"
BUILT_MODULE_NAME[1]="snd-hda-codec"
BUILT_MODULE_LOCATION[1]="common/"
DEST_MODULE_LOCATION[1]="/updates/dkms"
BUILT_MODULE_NAME[2]="snd-hda-intel"
BUILT_MODULE_LOCATION[2]="controllers/"
DEST_MODULE_LOCATION[2]="/updates/dkms"
BUILT_MODULE_NAME[3]="snd-hda-codec-ca0132"
BUILT_MODULE_LOCATION[3]="codecs/"
DEST_MODULE_LOCATION[3]="/updates/dkms"
EOF
log "source tree: $out"

if ((build)); then
	# Build a scratch copy, so the DKMS source tree stays clean.
	tb="$(mktemp -d)"
	cp -r "$out"/. "$tb"/
	log "test build against $kdir$llvm"
	# shellcheck disable=SC2086
	make -s -C "$kdir" M="$tb"$llvm -j"$JOBS" modules >"$tb/build.log" 2>&1 ||
		{ tail -30 "$tb/build.log" >&2; die "test build failed (log: $tb/build.log)"; }
	for m in core/snd-hda-core common/snd-hda-codec controllers/snd-hda-intel codecs/snd-hda-codec-ca0132; do
		[[ -f $tb/$m.ko ]] || die "missing $m.ko"
		log "built $m.ko: $(modinfo -F vermagic "$tb/$m.ko")"
	done
	modinfo -F parm "$tb/controllers/snd-hda-intel.ko" | /usr/bin/grep -q '^flush_writes:' ||
		die "snd-hda-intel.ko has no flush_writes parameter"
	rm -rf "$tb"
	log "test build OK"
fi
