#!/usr/bin/env bash
# mkdkms.sh — make the ae7-hda DKMS package and test-build it for one host kernel.
#
# Usage: host/dkms/mkdkms.sh [--kernel RELEASE] [--no-build]
#
# Writes vm/build/dkms/ae7-hda/: dkms.conf, ae7-build.sh and the fix patches
# (vm/patches/0002, 0003). DKMS builds it for each kernel; each build fetches
# the linux-stable sources of that kernel (network needed). No root needed.
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
	-h | --help) sed -n '3,8s/^# \{0,1\}//p' "$0"; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
	shift
done

# Package version: date of the last commit that changed the package inputs.
ver="$(git -C "$REPO" log -1 --format=%cd --date=format:%Y%m%d -- vm/patches host/dkms 2>/dev/null || true)"
ver="${ver:-0}"
out="$VM_DIR/build/dkms/ae7-hda"

rm -rf "$VM_DIR"/build/dkms/ae7-hda*
mkdir -p "$out/patches"
cp "$REPO/host/dkms/ae7-build.sh" "$out/"
for n in "${FIX_PATCHES[@]}"; do
	p=("$VM_DIR"/patches/"$n"-*.patch)
	[[ -f ${p[0]} ]] || die "missing patch $n in vm/patches"
	cp "${p[0]}" "$out/patches/"
done

cat >"$out"/dkms.conf <<EOF
PACKAGE_NAME="ae7-hda"
PACKAGE_VERSION="$ver"
# ae7-build.sh fetches the linux-stable sources of each kernel: needs network.
MAKE[0]="bash ./ae7-build.sh \${kernelver} \${kernel_source_dir}"
AUTOINSTALL="yes"
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
log "package: $out (ae7-hda/$ver)"

if ((build)); then
	kdir="/usr/lib/modules/$krel/build"
	[[ -f $kdir/.config ]] || die "no headers for $krel ($kdir); install the matching -headers package"
	# Build a scratch copy, so the package stays clean.
	tb="$(mktemp -d)"
	cp -r "$out"/. "$tb"/
	# Same arguments as DKMS: it adds LLVM=1 for clang kernels.
	llvm=()
	/usr/bin/grep -q '^CONFIG_CC_IS_CLANG=y' "$kdir/.config" && llvm=(LLVM=1)
	log "test build for $krel"
	(cd "$tb" && bash ./ae7-build.sh "$krel" "$kdir" "${llvm[@]}") >"$tb/build.log" 2>&1 ||
		{ tail -30 "$tb/build.log" >&2; die "test build failed (log: $tb/build.log)"; }
	for m in core/snd-hda-core common/snd-hda-codec controllers/snd-hda-intel codecs/snd-hda-codec-ca0132; do
		# DKMS does not install a module with the same srcversion as the stock one.
		stock="$(find "/usr/lib/modules/$krel/kernel" -name "${m#*/}.ko*" -print -quit)"
		if [[ -n $stock && $(modinfo -F srcversion "$stock") == "$(modinfo -F srcversion "$tb/$m.ko")" ]]; then
			die "$m.ko has the srcversion of $stock; DKMS would skip it"
		fi
		log "built $m.ko: $(modinfo -F vermagic "$tb/$m.ko")"
	done
	rm -rf "$tb"
	log "test build OK"
fi
