#!/usr/bin/env bash
# probe.sh: load snd-hda-intel $MODPARAMS and wait (max 20 s) for the codecs.
# PASS if a codec registers; in passthrough mode it must be Creative (0x1102).
# Writes $OUT/codecs.txt with one "card addr vendor_id name" line per codec.
set -euo pipefail

WAIT_S=20
FAIL_RE='no codecs initialized|Cannot probe codecs'

verdict() { echo "$*" >"$OUT/verdict"; echo "probe: $*"; }
count() { { compgen -G "$1" || true; } | wc -l; }

echo "probe: modprobe snd-hda-intel $MODPARAMS"
# shellcheck disable=SC2086 # MODPARAMS is a list of key=value words.
if ! modprobe snd-hda-intel $MODPARAMS; then
	verdict "modprobe snd-hda-intel $MODPARAMS failed"
	exit 1
fi

# Done when each bound controller has a card or a probe error in dmesg.
start=$SECONDS bound=0 cards=0 fails=0
while ((SECONDS - start < WAIT_S)); do
	bound="$(count '/sys/bus/pci/drivers/snd_hda_intel/0000:*')"
	cards="$(count '/sys/class/sound/card[0-9]*')"
	fails="$(dmesg | /usr/bin/grep -c -E "$FAIL_RE" || true)"
	((bound > 0 && cards + fails >= bound)) && break
	((bound == 0 && SECONDS - start >= 3)) && break
	sleep 0.2
done
echo "probe: after $((SECONDS - start))s: bound=$bound cards=$cards errors=$fails"

: >"$OUT/codecs.txt"
found=() creative=0
for f in /proc/asound/card[0-9]*/codec#*; do
	[[ -e $f ]] || continue
	card="${f#/proc/asound/card}"
	card="${card%%/*}"
	addr="${f##*#}"
	vid="$(sed -n 's/^Vendor Id: *//p' "$f")"
	name="$(sed -n 's/^Codec: *//p' "$f")"
	echo "$card $addr $vid $name" >>"$OUT/codecs.txt"
	found+=("card$card codec#$addr $vid ($name)")
	[[ ${vid,,} == 0x1102* ]] && creative=1
done
printf 'probe: found %s\n' "${found[@]}"

if ((${#found[@]} == 0)); then
	errs="$(dmesg | /usr/bin/grep -o -E "$FAIL_RE|no codecs found" | sort -u | paste -sd ',' || true)"
	verdict "no codec (bound=$bound cards=$cards${errs:+: $errs})"
	exit 1
fi
if [[ $MODE == passthrough ]] && ((!creative)); then
	verdict "no Creative codec: ${found[*]}"
	exit 1
fi
verdict "codecs: ${found[*]}"
