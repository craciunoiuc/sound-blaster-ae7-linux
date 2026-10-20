#!/usr/bin/env bash
# shell.sh: interactive root shell on the serial console (vm/run.sh --interactive).
# No sound module is loaded. Exit the shell to collect logs and power off.
set -euo pipefail

if [[ ${INTERACTIVE:-0} != 1 ]]; then
	echo "shell test needs vm/run.sh --interactive" | tee "$OUT/verdict"
	exit 1
fi

cat <<EOF

=== AE-7 guest shell ($MODE) ===
  AE7_BDFS=$AE7_BDFS  OUT=$OUT  MODPARAMS='$MODPARAMS'
  modprobe snd-hda-intel $MODPARAMS        # load the driver
  bash \$REPO/vm/guest/tests/probe.sh      # or any other test
  exit                                     # collect logs and power off
  Ctrl-A x stops QEMU at once (no log collection).

EOF

# ttyS0, not /dev/console, so that the shell gets job control.
rc=0
PS1='ae7-guest:\w# ' setsid -c -w bash --norc -i </dev/ttyS0 >/dev/ttyS0 2>&1 || rc=$?
echo "interactive shell exited (status $rc)" >"$OUT/verdict"
exit "$rc"
