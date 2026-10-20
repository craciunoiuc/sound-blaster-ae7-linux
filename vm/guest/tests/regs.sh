#!/usr/bin/env bash
# regs.sh: dump the HDA controller registers before a driver loads.
# PASS if each HDA function has a readable BAR0 and GCAP is not 0 or 0xffff.
set -euo pipefail

TOOL="$REPO/vm/guest/tools/hda-mmio.py"
read -ra targs <<<"${TEST_ARGS:-}"

if [[ -z "${AE7_BDFS:-}" ]]; then
	echo "regs: no target device (AE7_BDFS is empty)"
	echo "no target device" >"$OUT/verdict"
	exit 1
fi

pass=0 fail=0 summary=()
for bdf in $AE7_BDFS; do
	tag="${bdf//:/_}"
	lspci -vvv -nn -s "$bdf" >"$OUT/lspci-$tag.txt" 2>&1 || true
	class="$(cat "/sys/bus/pci/devices/$bdf/class" 2>/dev/null || echo unknown)"
	echo "== regs: $bdf class $class =="
	if [[ "$class" != 0x0403* ]]; then
		echo "regs: $bdf is not an HDA controller, skip it"
		continue
	fi
	if python3 -I "$TOOL" "${targs[@]}" "$bdf" dump 2>&1 | tee "$OUT/regs-$tag.txt"; then
		gcap="$(sed -n 's/^dump: OK, GCAP=\(0x[0-9a-f]*\).*/\1/p' "$OUT/regs-$tag.txt")"
		summary+=("$bdf GCAP=$gcap")
		pass=$((pass + 1))
	else
		summary+=("$bdf BAR not readable")
		fail=$((fail + 1))
	fi
done

echo "${summary[*]:-no HDA function}" >"$OUT/verdict"
echo "regs: $pass readable, $fail not readable: ${summary[*]:-no HDA function}"
((pass > 0 && fail == 0))
