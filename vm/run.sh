#!/usr/bin/env bash
# vm/run.sh — boot the guest kernel in QEMU and run one guest test.
#
# Usage: vm/run.sh (--emulated | --passthrough) [--test NAME] [--modparams "..."]
#          [--test-args "..."] [--append "kernel args"] [--trace] [--timeout SEC]
#          [--name LABEL] [--mem 2G] [--cpus N] [--interactive] [--dry-run] [--force] [--mmap]
#
# Tests are vm/guest/tests/NAME.sh (default: probe). Output: logs/run-NNN[-LABEL]/.
# Last line: "RESULT: PASS|FAIL|TIMEOUT|NO-RESULT — reason — dir". Exit 0 only on PASS.
# --interactive: console on stdio (Ctrl-A x quits QEMU), no timeout unless --timeout.
# --passthrough traps each BAR access (x-no-mmap) so writes cannot burst; --mmap
# maps the BARs to the guest (real timing; a write burst can stop the card bridge).
# Env AE7_HOST_BDFS="0000:14:00.0 ..." sets the host BDFs for --passthrough.
set -euo pipefail

# shellcheck source=vm/config.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/config.sh"

GUEST_SLOT=10	# Guest PCI slot (hex, bus 0) for the HDA controller in both modes.

die() { echo "run.sh: error: $*" >&2; exit 2; }
warn() { echo "run.sh: warning: $*" >&2; }
note() { echo "run.sh: $*" >&2; }
usage() { sed -n '3,6s/^# \{0,1\}//p' "$0"; }
val() { (($# >= 2)) || die "$1 needs a value"; printf '%s' "$2"; }
# Print the arguments as one shell command line. Quote only words that need it.
shell_join() {
	local a out=()
	for a in "$@"; do
		if [[ $a =~ ^[A-Za-z0-9_./:=,@%+-]+$ ]]; then out+=("$a")
		else out+=("'${a//\'/\'\\\'\'}'"); fi
	done
	echo "${out[*]}"
}

mode="" test=probe modparams="" test_args="" append="" trace=0
timeout="" name="" mem="$VM_MEM" cpus="$VM_CPUS" interactive=0 dry=0 force=0 mmap=0
while (($#)); do
	case $1 in
	--emulated) mode=emulated ;;
	--passthrough) mode=passthrough ;;
	--test) test=$(val "$@"); shift ;;
	--modparams) modparams=$(val "$@"); shift ;;
	--test-args) test_args=$(val "$@"); shift ;;
	--append) append=$(val "$@"); shift ;;
	--trace) trace=1 ;;
	--timeout) timeout=$(val "$@"); shift ;;
	--name) name=$(val "$@"); shift ;;
	--mem) mem=$(val "$@"); shift ;;
	--cpus) cpus=$(val "$@"); shift ;;
	--interactive) interactive=1 ;;
	--dry-run) dry=1 ;;
	--force) force=1 ;;
	--mmap) mmap=1 ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; die "unknown option: $1" ;;
	esac
	shift
done

[[ -n $mode ]] || { usage >&2; die "give --emulated or --passthrough"; }
test_sh="$VM_DIR/guest/tests/$test.sh"
[[ -f $test_sh ]] || die "no test '$test' (have: $(cd "$VM_DIR/guest/tests" && ls -- *.sh | sed 's/\.sh$//' | tr '\n' ' '))"
[[ -z $name || $name =~ ^[A-Za-z0-9._-]+$ ]] || die "--name: use only [A-Za-z0-9._-]"
[[ $cpus =~ ^[0-9]+$ ]] || die "--cpus: not a number: $cpus"
if [[ -z $timeout ]]; then
	((interactive)) && timeout=0 || timeout=$VM_TIMEOUT
fi
[[ $timeout =~ ^[0-9]+$ ]] || die "--timeout: not a number: $timeout"

# The guest test gets less time than the host, so that collection can finish.
guest_timeout=0
if ((timeout > 0)); then
	((timeout >= 30)) && guest_timeout=$((timeout - 15)) || guest_timeout=$((timeout / 2))
fi

# A failed precondition stops a real run. A dry run only reports it.
blocked=0
problem() {
	if ((dry)); then warn "$*"; blocked=1; else die "$*"; fi
}

if [[ ! -f $BZIMAGE ]]; then
	problem "guest kernel not found: $BZIMAGE"
elif ! compgen -G "$MODROOT/lib/modules/*/modules.dep" >/dev/null; then
	problem "guest modules not found: $MODROOT/lib/modules/*/modules.dep"
fi
qemu_bin="$(command -v "$QEMU" || true)"
[[ -n $qemu_bin ]] || die "QEMU not found: $QEMU"
qemu_bin="$(readlink -f "$qemu_bin")"
[[ -r /dev/kvm && -w /dev/kvm ]] || problem "/dev/kvm is not usable"

# Passthrough: find host functions and check the host is ready.
host_bdfs=()
if [[ $mode == passthrough ]]; then
	if [[ -n ${AE7_HOST_BDFS:-} ]]; then
		read -r -a host_bdfs <<<"$AE7_HOST_BDFS"
	else
		mapfile -t host_bdfs < <(ae7_bdfs || true)
	fi
	if ((${#host_bdfs[@]} == 0)); then
		problem "AE-7 ($AE7_ID) not found on the host (lspci -d $AE7_ID)"
		host_bdfs=("DDDD:BB:SS.0")
	fi
	if [[ -x $REPO/host/bind.sh ]]; then
		if ! "$REPO/host/bind.sh" --check; then
			if ((force)); then warn "host/bind.sh --check failed; continue (--force)"
			else problem "host/bind.sh --check failed (use --force to override)"; fi
		fi
	elif ((force)); then
		warn "host/bind.sh not found; vfio binding is not checked (--force)"
	else
		problem "host/bind.sh not found; cannot check vfio binding (use --force)"
	fi
	sudo -n -l "$qemu_bin" >/dev/null 2>&1 ||
		problem "no passwordless sudo for $qemu_bin (run host/setup.sh)"
	# vfio pins guest RAM. After QEMU drops root, new DMA maps need RLIMIT_MEMLOCK.
	ulimit -l unlimited 2>/dev/null || true
	if [[ $(ulimit -l) != unlimited ]] && ! sudo -n -l 2>/dev/null | /usr/bin/grep -q rlimit_memlock; then
		warn "RLIMIT_MEMLOCK is $(ulimit -l) KiB and sudoers sets no rlimit_memlock for qemu;" \
			"QEMU can abort on a vfio DMA map after it drops to user $(id -un)"
	fi
fi

# Make the run directory. The lock on logs/ keeps run numbers unique.
mkdir -p "$LOGS_DIR"
if ((dry)); then
	run_dir="$LOGS_DIR/run-NNN${name:+-$name}"
else
	exec 9<"$LOGS_DIR"
	flock 9
	last="$(find "$LOGS_DIR" -maxdepth 1 -name 'run-[0-9][0-9][0-9]*' -printf '%f\n' |
		sed -n 's/^run-\([0-9]\{3\}\).*/\1/p' | sort -n | tail -n 1)"
	run_dir="$(printf '%s/run-%03d%s' "$LOGS_DIR" $((10#${last:-0} + 1)) "${name:+-$name}")"
	mkdir "$run_dir"
	exec 9<&-
fi
rel_dir="${run_dir#"$REPO"/}/"

kcmd="console=ttyS0 panic=-1 root=hostroot rootfstype=9p"
kcmd+=" rootflags=trans=virtio,version=9p2000.L ro init=$VM_DIR/guest/init.sh"
[[ -n $append ]] && kcmd+=" $append"

args=(
	-name "ae7-${run_dir##*/}"
	-machine q35,accel=kvm -cpu host -m "$mem" -smp "$cpus"
	-nodefaults -nographic -no-reboot
	-kernel "$BZIMAGE" -append "$kcmd"
	-virtfs "local,path=/,mount_tag=hostroot,security_model=none,readonly=on,multidevs=remap"
	-virtfs "local,path=$run_dir,mount_tag=out,security_model=none"
	-pidfile "$run_dir/qemu.pid"
)
if ((interactive)); then
	args+=(-chardev "stdio,id=con0,mux=on,signal=off,logfile=$run_dir/serial.log"
		-serial chardev:con0 -monitor chardev:con0)
else
	args+=(-chardev "file,id=con0,path=$run_dir/serial.log" -serial chardev:con0)
fi

launcher=() trace_events=()
if [[ $mode == emulated ]]; then
	# debug=2 logs each controller register access to qemu.log.
	hda="intel-hda,bus=pcie.0,addr=0x$GUEST_SLOT"
	((trace)) && hda+=",debug=2"
	args+=(-audiodev "wav,id=snd0,path=$run_dir/audio.wav"
		-device "$hda" -device hda-duplex,audiodev=snd0)
	trace_events=('hda_audio_*')
else
	# Keep the host function numbers on one guest slot. No option ROM is needed.
	for bdf in "${host_bdfs[@]}"; do
		fn="${bdf##*.}"
		dev="vfio-pci,host=$bdf,bus=pcie.0,addr=0x$GUEST_SLOT.$fn,rombar=0"
		((${#host_bdfs[@]} > 1)) && [[ $fn == 0 ]] && dev+=",multifunction=on"
		((trace || !mmap)) && dev+=",x-no-mmap=on"
		args+=(-device "$dev")
	done
	trace_events=(vfio_region_read vfio_region_write 'vfio_intx*' 'vfio_msi*'
		vfio_pci_read_config vfio_pci_write_config 'vfio_pci_reset*' 'vfio_pci_hot_reset*')
	args+=(-run-with "user=$(id -un),exit-with-parent=on")
	launcher=(sudo -n)
fi
# One -trace option keeps only its last enable=, so give the events in a file.
((trace)) && args+=(-trace "events=$run_dir/qemu-trace-events,file=$run_dir/qemu-trace.log")
cmd=("${launcher[@]}" "$qemu_bin" "${args[@]}")

if ((dry)); then
	echo "# run dir: $rel_dir"
	printf '# params.env: TEST=%q MODE=%q MODPARAMS=%q TEST_ARGS=%q TRACE=%s GUEST_TIMEOUT=%s\n' \
		"$test" "$mode" "$modparams" "$test_args" "$trace" "$guest_timeout"
	((trace)) && echo "# qemu-trace-events: ${trace_events[*]}"
	shell_join "${cmd[@]}"
	exit "$blocked"
fi

{
	printf '%s=%q\n' TEST "$test" MODE "$mode" MODPARAMS "$modparams" TEST_ARGS "$test_args"
	printf '%s=%q\n' TRACE "$trace" GUEST_TIMEOUT "$guest_timeout" INTERACTIVE "$interactive"
	printf '%s=%q\n' GUEST_SLOT "00:$GUEST_SLOT" RUN_NAME "${run_dir##*/}"
} >"$run_dir/params.env"
shell_join "${cmd[@]}" >"$run_dir/qemu-cmd.txt"
# Make the files that QEMU opens as root, so that they stay owned by the user.
: >"$run_dir/serial.log"
: >"$run_dir/qemu.pid"
if ((trace)); then
	: >"$run_dir/qemu-trace.log"
	printf '%s\n' "${trace_events[@]}" >"$run_dir/qemu-trace-events"
fi

host_dmesg() { sudo -n dmesg 2>/dev/null || dmesg 2>/dev/null; }
dmesg_mark="" dmesg_ok=0
if [[ $mode == passthrough ]]; then
	sync
	if dmesg_mark="$(host_dmesg | tail -n 1)" && [[ -n $dmesg_mark ]]; then
		dmesg_ok=1
	else
		warn "host dmesg is not readable; host-dmesg.txt is not made"
	fi
fi

# True if PID $1 exists and is not a zombie.
alive() {
	local s
	[[ -n ${1:-} && -r /proc/$1/stat ]] || return 1
	read -r _ _ s _ <"/proc/$1/stat" 2>/dev/null && [[ $s != Z ]]
}
qemu_pid() { cat "$run_dir/qemu.pid" 2>/dev/null || true; }
qemu_running() { alive "$(qemu_pid)" || alive "${qpid:-}"; }

# Send TERM, then KILL, to QEMU and its launcher. Return 1 if QEMU stays.
stop_qemu() {
	local sig p i
	for sig in TERM KILL; do
		for p in $(qemu_pid) ${qpid:-}; do kill -s "$sig" "$p" 2>/dev/null || true; done
		for ((i = 0; i < 50; i++)); do
			qemu_running || return 0
			sleep 0.1
		done
	done
	return 1
}

watchdog() {
	local end=$((SECONDS + timeout))
	while ((SECONDS < end)); do sleep 1; done
	: >"$run_dir/.timeout"
	note "timeout after ${timeout}s: stopping QEMU"
	stop_qemu || kill -USR1 $$
}

note "$mode run ($test) -> $rel_dir"
start=$SECONDS
gave_up=0 interrupted=0
trap 'gave_up=1' USR1
trap 'interrupted=1' INT TERM HUP
if ((interactive)); then
	"${cmd[@]}" <&0 2> >(tee "$run_dir/qemu.log" >&2) &
	qpid=$!
	tpid=""
else
	"${cmd[@]}" </dev/null >"$run_dir/qemu.log" 2>&1 &
	qpid=$!
	tail -n +1 -s 0.2 -f --pid="$qpid" "$run_dir/serial.log" &
	tpid=$!
fi
wpid=""
if ((timeout > 0)); then
	watchdog &
	wpid=$!
fi

# Wait for QEMU. A trapped signal stops "wait" early, so wait again.
rc=0
while :; do
	rc=0
	wait "$qpid" || rc=$?
	alive "$qpid" || break
	((gave_up)) && break
	if ((interrupted)); then
		note "interrupted: stopping QEMU"
		stop_qemu || { gave_up=1; break; }
	fi
done
[[ -n $wpid ]] && { kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true; }
if [[ -n $tpid ]]; then
	alive "$qpid" && kill "$tpid" 2>/dev/null
	wait "$tpid" 2>/dev/null || true
fi
((interactive)) && [[ -t 0 ]] && stty sane 2>/dev/null
trap - USR1 INT TERM HUP
wall=$((SECONDS - start))

if ((dmesg_ok)); then
	host_dmesg | LAST="$dmesg_mark" awk '{ l[NR] = $0 } $0 == ENVIRON["LAST"] { m = NR }
		END { for (i = m + 1; i <= NR; i++) print l[i] }' >"$run_dir/host-dmesg.txt"
fi

result_file="$run_dir/result"
status="" reason=""
if [[ -e $run_dir/.timeout ]]; then
	status=TIMEOUT
	reason="guest did not power off within ${timeout}s"
	[[ -s $result_file ]] && reason+=" (guest result: $(head -n 1 "$result_file"))"
	((gave_up)) && reason+="; QEMU pid $(qemu_pid) still runs as root: sudo kill -9 $(qemu_pid)"
elif [[ -s $result_file ]]; then
	read -r status reason <"$result_file" || true
	if [[ $status != PASS && $status != FAIL ]]; then
		reason="bad result line: $status $reason"
		status=NO-RESULT
	fi
else
	status=NO-RESULT
	panic="$(/usr/bin/grep -m 1 -o 'Kernel panic - not syncing:.*' "$run_dir/serial.log" || true)"
	if ((interrupted)); then
		reason="interrupted"
	elif [[ -n $panic ]]; then
		reason="guest ${panic%$'\r'}"
	elif ((rc != 0)); then
		reason="QEMU exit $rc: $(/usr/bin/grep -v '^\s*$' "$run_dir/qemu.log" | tail -n 1)"
	else
		reason="guest wrote no result (see serial.log)"
	fi
fi
if [[ -s $run_dir/host-dmesg.txt ]]; then
	n="$(/usr/bin/grep -c -i -E 'IO_PAGE_FAULT|AER|vfio|DMAR|iommu' "$run_dir/host-dmesg.txt" || true)"
	((n > 0)) && reason+="; host dmesg: $n IOMMU/AER/vfio lines"
fi

note "wall time ${wall}s"
echo "RESULT: $status — $reason — $rel_dir"
[[ $status == PASS ]]
