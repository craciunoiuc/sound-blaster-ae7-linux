#!/usr/bin/env bash
# pio.sh: query the codecs with the Immediate Command interface (MMIO only).
# PASS if one codec gives a vendor id that is not 0 and not 0xffffffff.
set -euo pipefail

TOOL="$REPO/vm/guest/tools/hda-mmio.py"
read -ra targs <<<"${TEST_ARGS:-}"

if [[ -z "${AE7_BDFS:-}" ]]; then
	echo "pio: no target device (AE7_BDFS is empty)"
	echo "no target device" >"$OUT/verdict"
	exit 1
fi

found=()
for bdf in $AE7_BDFS; do
	tag="${bdf//:/_}"
	class="$(cat "/sys/bus/pci/devices/$bdf/class" 2>/dev/null || echo unknown)"
	echo "== pio: $bdf class $class =="
	if [[ "$class" != 0x0403* ]]; then
		echo "pio: $bdf is not an HDA controller, skip it"
		continue
	fi
	python3 -I "$TOOL" "${targs[@]}" "$bdf" dump >"$OUT/pio-before-$tag.txt" 2>&1 || true
	rc=0
	python3 -I "$TOOL" "${targs[@]}" "$bdf" probe 2>&1 | tee "$OUT/pio-$tag.txt" || rc=$?
	python3 -I "$TOOL" "$bdf" dump >"$OUT/pio-after-$tag.txt" 2>&1 || true
	echo "pio: hda-mmio probe exit $rc"
	hits="$(/usr/bin/grep '^FOUND: codec [0-9]* vendor_id 0x' "$OUT/pio-$tag.txt" || true)"
	while read -r _ _ addr _ vid; do
		[[ -n "$vid" ]] || continue
		note=""
		if [[ "$MODE" == passthrough ]]; then
			if [[ "${vid:2:4}" == 1102 ]]; then
				note=" (Creative)"
			else
				note=" (not Creative)"
			fi
		fi
		found+=("$bdf codec $addr vendor_id $vid$note")
	done <<<"$hits"
done

if ((${#found[@]})); then
	printf 'pio: %s\n' "${found[@]}"
	echo "${found[*]}" >"$OUT/verdict"
	exit 0
fi
echo "pio: no codec gave a valid vendor id through IC/IR"
echo "no codec answered IC/IR" >"$OUT/verdict"
exit 1
