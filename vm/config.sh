# vm/config.sh — shared settings for the AE-7 VM rig. Source it, do not run it.
# shellcheck shell=bash

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_DIR="$REPO/vm"
LOGS_DIR="$REPO/logs"

# Guest kernel: linux-stable at the host kernel version.
KVER="${KVER:-v7.2.10}"
LINUX_URL="${LINUX_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
LINUX_SRC="$VM_DIR/linux"
LINUX_BRANCH="ae7"
BUILD_DIR="$VM_DIR/build/linux"
MODROOT="$VM_DIR/build/modroot"
BZIMAGE="$BUILD_DIR/arch/x86/boot/bzImage"
JOBS="${JOBS:-$(nproc)}"

# Hardware IDs.
AE7_ID="1102:0010"      # CA0132 HDA controller (CTHDA)
BRIDGE_ID="1b21:1080"   # ASMedia ASM1083/1085 PCIe-to-PCI bridge

# QEMU defaults.
QEMU="${QEMU:-qemu-system-x86_64}"
VM_MEM="${VM_MEM:-2G}"
VM_CPUS="${VM_CPUS:-4}"
VM_TIMEOUT="${VM_TIMEOUT:-120}"

# Print the full BDF of every function in the AE-7 slot, one per line.
ae7_bdfs() {
	local first slot
	first="$(lspci -D -n -d "$AE7_ID" | awk 'NR==1 {print $1}')"
	[[ -n "$first" ]] || return 1
	slot="${first%.*}"
	lspci -D -n -s "$slot" | awk '{print $1}'
}
