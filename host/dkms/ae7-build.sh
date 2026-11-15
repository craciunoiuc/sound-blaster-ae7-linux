#!/usr/bin/env bash
# ae7-build.sh — build the ae7-hda modules for one kernel. DKMS runs it as MAKE.
#
# Usage: ae7-build.sh KERNELRELEASE KERNEL_BUILD_DIR [VAR=VALUE...]
#
# Gets the linux-stable sources of the kernel base version (sparse clone of a
# mirror, commit checked against kernel.org), applies patches/*.patch and builds
# the four modules in the current directory. Needs network access. VAR=VALUE
# arguments go to make (DKMS adds LLVM=1 for clang kernels).
set -euo pipefail

MIRROR="${AE7_LINUX_MIRROR:-https://github.com/gregkh/linux.git}"
ORIGIN=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
# sound/hda directory and the one module to build from it.
MODULES=(core:snd-hda-core common:snd-hda-codec controllers:snd-hda-intel codecs:snd-hda-codec-ca0132)

log() { printf '[ae7-build] %s\n' "$*" >&2; }
die() { printf '[ae7-build] error: %s\n' "$*" >&2; exit 1; }

(($# >= 2)) || die "usage: $0 KERNELRELEASE KERNEL_BUILD_DIR [VAR=VALUE...]"
krel="$1" kdir="$2"
shift 2
for v in "$@"; do
	[[ $v =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "not a VAR=VALUE make argument: $v"
done
here="$PWD"
[[ -f $kdir/.config ]] || die "no kernel config in $kdir"
for c in SND_HDA_CORE SND_HDA SND_HDA_INTEL SND_HDA_CODEC_CA0132; do
	/usr/bin/grep -q "^CONFIG_$c=m" "$kdir/.config" || die "CONFIG_$c is not =m in $krel"
done

base="${krel%%-*}"	# 7.3.4-1-cachyos -> 7.3.4
[[ $base =~ ^([0-9]+\.[0-9]+)(\.([0-9]+))?$ ]] || die "cannot get the base version from $krel"
tag="v$base"
[[ ${BASH_REMATCH[3]} == 0 ]] && tag="v${BASH_REMATCH[1]}"	# 7.3.0 -> v7.3

rm -rf linux include Kbuild "${MODULES[@]%%:*}"
log "fetch $tag from $MIRROR"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" \
	--filter=blob:none --sparse "$MIRROR" linux
git -C linux sparse-checkout set --no-cone /sound/hda/ /include/sound/hdaudio.h
# The peeled line of an annotated tag comes last.
want="$(git ls-remote "$ORIGIN" "refs/tags/$tag" "refs/tags/$tag^{}" | awk 'END { print $1 }')"
got="$(git -C linux rev-parse HEAD)"
[[ -n $want && $got == "$want" ]] || die "$tag is $got on the mirror, ${want:-not found} on kernel.org"

for p in patches/*.patch; do
	git -C linux apply "$here/$p" || die "${p##*/} does not apply on $tag"
	log "applied ${p##*/}"
done

mkdir -p include/sound
cp linux/include/sound/hdaudio.h include/sound/
dirs=("${MODULES[@]%%:*}")
echo "obj-m += ${dirs[*]/%//}" >Kbuild
for m in "${MODULES[@]}"; do
	d="${m%%:*}" mod="${m#*:}"
	cp -r "linux/sound/hda/$d" "$d"
	/usr/bin/grep -Eq "^$mod-(y|objs)[[:space:]]*[:+]?=" "$d/Makefile" ||
		die "no $mod-y object list in sound/hda/$d/Makefile"
	# The tag gives a srcversion that is not the stock one: DKMS skips equal modules.
	printf '#include <linux/module.h>\nMODULE_INFO(ae7_hda, "%s");\n' "$tag" >"$d/ae7-tag.c"
	# Upstream object lists, one module only, patched hdaudio.h before the kernel copy.
	cat >"$d/Kbuild" <<-EOF
	NOSTDINC_FLAGS += -I\$(src)/../include
	include \$(src)/Makefile
	obj-y :=
	obj-m := $mod.o
	$mod-y += ae7-tag.o
	EOF
done
rm -rf linux

llvm=()
/usr/bin/grep -q '^CONFIG_CC_IS_CLANG=y' "$kdir/.config" && llvm=(LLVM=1)
log "build for $krel${llvm:+ with LLVM=1}"
make -C "$kdir" M="$here" "${llvm[@]}" "$@" -j"$(nproc)" modules

for m in "${MODULES[@]}"; do
	ko="${m%%:*}/${m#*:}.ko"
	[[ -f $ko ]] || die "missing $ko"
	[[ -n $(modinfo -F ae7_hda "$ko") ]] || die "$ko has no ae7_hda tag"
done
modinfo -F parm controllers/snd-hda-intel.ko | /usr/bin/grep -q '^flush_writes:' ||
	die "snd-hda-intel.ko has no flush_writes parameter"
log "built $tag + $(cd patches && echo *.patch) for $krel"
