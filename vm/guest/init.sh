#!/usr/bin/env bash
# vm/guest/init.sh — guest PID 1 for the AE-7 VM rig (started by vm/run.sh).
#
# Root is the host / (read-only 9p). This script mounts a small runtime, reads
# params.env from the "out" share, runs vm/guest/tests/$TEST.sh, collects logs
# into the share, writes "result" ("PASS|FAIL reason") and powers off.
# TRACE=1 records the hda, hda_controller and hda_intel trace events.
#
# PID 1 must not exit, so there is no errexit or nounset: check errors one by one.
set -o pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
export HOME=/tmp TERM=linux LANG=C LC_ALL=C

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT=/run/out
TRACEFS=/sys/kernel/tracing
finished=0 out_ok=0

log() { echo "init: [$(cut -d ' ' -f 1 /proc/uptime 2>/dev/null)] $*"; }

# Wait $1 seconds with builtins only: after sysrq 'o' the 9p root can be gone.
# Fd 7 is a FIFO that nobody writes, so "read" waits for the full timeout.
pause() {
	read -r -t "$1" -u 7 _ 2>/dev/null
	(($? > 128)) || sleep "$1" 2>/dev/null
}

# Power off. If that fails, reboot (QEMU runs with -no-reboot, so it stops).
power_off() {
	sync
	umount "$OUT" 2>/dev/null
	[[ -e /proc/sysrq-trigger ]] || mount -t proc proc /proc
	echo o >/proc/sysrq-trigger
	pause 10
	echo b >/proc/sysrq-trigger
	while :; do pause 60; done
}

write_result() {
	log "RESULT $1 $2"
	((out_ok)) && echo "$1 $2" >"$OUT/result"
}

# Write the result file and stop. Run this one time only.
finish() {
	((finished)) && return
	finished=1
	write_result "$1" "$2"
	power_off
}
trap 'finish FAIL "init.sh exited early"' EXIT

# No "mountpoint" check: before /proc is mounted, it reads the host /proc over 9p.
mnt() { mount "$@" || log "error: mount $* failed"; }

# Basic runtime on the read-only root.
mnt -t proc proc /proc
mnt -t sysfs sys /sys
mnt -t devtmpfs dev /dev
[[ -c /dev/console ]] && exec </dev/console >/dev/console 2>&1
# Bash process substitution needs /dev/fd. devtmpfs does not supply it.
ln -sfn /proc/self/fd /dev/fd
ln -sf /proc/self/fd/0 /dev/stdin
ln -sf /proc/self/fd/1 /dev/stdout
ln -sf /proc/self/fd/2 /dev/stderr
mkdir -p /dev/pts /dev/shm
mnt -t devpts devpts /dev/pts
mnt -t tmpfs tmpfs /dev/shm
for d in /run /tmp /var/tmp; do
	mnt -t tmpfs -o mode=1777 tmpfs "$d"
done
mkfifo /run/pause.fifo && exec 7<>/run/pause.fifo
log "kernel $(uname -r), repo $REPO"

# Hide the host modprobe config: its vfio-pci softdep and blacklists are for the host.
mkdir -p /run/empty
for d in /etc/modprobe.d /usr/lib/modprobe.d; do
	[[ -d $d ]] && mnt --bind /run/empty "$d"
done

mkdir -p "$OUT"
if mount -t 9p -o trans=virtio,version=9p2000.L,msize=262144 out "$OUT"; then
	out_ok=1
else
	finish FAIL "cannot mount the out share"
fi

# shellcheck source=vm/config.sh
source "$REPO/vm/config.sh"
if [[ -d $MODROOT/lib/modules/$(uname -r) ]]; then
	mount --bind "$MODROOT/lib/modules" /usr/lib/modules ||
		finish FAIL "cannot bind $MODROOT/lib/modules"
else
	finish FAIL "no modules for $(uname -r) in $MODROOT/lib/modules"
fi

if [[ -r $OUT/params.env ]]; then
	set -a
	# shellcheck source=/dev/null
	source "$OUT/params.env"
	set +a
else
	finish FAIL "no params.env in the out share"
fi
TEST="${TEST:-probe}" MODE="${MODE:-emulated}" GUEST_TIMEOUT="${GUEST_TIMEOUT:-0}"
export TEST MODE MODPARAMS="${MODPARAMS:-}" TEST_ARGS="${TEST_ARGS:-}" OUT REPO

# The HDA functions: the slot that run.sh uses, else all audio-class devices.
if [[ -n ${GUEST_SLOT:-} ]]; then
	AE7_BDFS="$(lspci -D -n -s "$GUEST_SLOT" | awk '{print $1}' | xargs)"
fi
[[ -n ${AE7_BDFS:-} ]] || AE7_BDFS="$(lspci -D -n -d ::0403 | awk '{print $1}' | xargs)"
export AE7_BDFS
log "mode=$MODE test=$TEST AE7_BDFS='$AE7_BDFS' modparams='$MODPARAMS'"

# Arm the trace events now. Events of a module start when the module loads.
if [[ ${TRACE:-0} == 1 ]]; then
	mnt -t tracefs tracefs "$TRACEFS"
	echo 16384 >"$TRACEFS/buffer_size_kb"
	for m in snd_hda_core snd_hda_codec snd_hda_intel; do
		echo ":mod:$m" >>"$TRACEFS/set_event" || log "error: cannot arm events of $m"
	done
	echo 1 >"$TRACEFS/tracing_on"
fi

test_sh="$REPO/vm/guest/tests/$TEST.sh"
rc=1
if [[ ! -f $test_sh ]]; then
	echo "no test script $test_sh" >"$OUT/verdict"
elif [[ ${INTERACTIVE:-0} == 1 ]]; then
	log "running $TEST.sh on the console"
	bash "$test_sh"
	rc=$?
else
	log "running $TEST.sh (guest timeout ${GUEST_TIMEOUT}s)"
	if ((GUEST_TIMEOUT > 0)); then
		timeout -k 5 "$GUEST_TIMEOUT" bash "$test_sh" </dev/null 2>&1 | tee "$OUT/test.log"
	else
		bash "$test_sh" </dev/null 2>&1 | tee "$OUT/test.log"
	fi
	rc=${PIPESTATUS[0]}
	if ((GUEST_TIMEOUT > 0 && (rc == 124 || rc == 137))); then
		echo "test timed out after ${GUEST_TIMEOUT}s" >"$OUT/verdict"
	fi
fi
log "$TEST.sh exited with $rc"

# Write the result before collection: a hung codec can block the codec# reads.
verdict="$(head -n 1 "$OUT/verdict" 2>/dev/null)"
if ((rc == 0)); then
	status=PASS reason="${verdict:-$TEST: exit 0}"
else
	status=FAIL reason="${verdict:-$TEST: exit $rc}"
fi
finished=1
write_result "$status" "$reason"

# Common collection. Each step can fail without effect on the others.
log "collecting logs"
dmesg >"$OUT/dmesg.txt" 2>&1
lspci -nnvvv >"$OUT/lspci.txt" 2>&1
for bdf in $AE7_BDFS; do
	lspci -nnvvv -xxxx -s "$bdf"
done >"$OUT/lspci-ae7.txt" 2>&1
cat /proc/interrupts >"$OUT/interrupts.txt" 2>&1
lsmod >"$OUT/lsmod.txt" 2>&1
for f in /proc/asound/cards /proc/asound/pcm /proc/asound/card*/codec#*; do
	[[ -e $f ]] || continue
	echo "==> $f <=="
	timeout 10 cat "$f" || echo "(read failed or timed out)"
	echo
done >"$OUT/asound.txt" 2>&1
if [[ ${TRACE:-0} == 1 ]]; then
	echo 0 >"$TRACEFS/tracing_on"
	cat "$TRACEFS/trace" >"$OUT/trace.txt" 2>&1
fi
log "done"
power_off
