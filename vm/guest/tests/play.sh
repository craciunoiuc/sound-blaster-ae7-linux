#!/usr/bin/env bash
# play.sh: run probe.sh, then play a short sine with speaker-test on device 0.
# PASS if speaker-test exits 0. Passthrough uses the card of the Creative codec.
set -euo pipefail

bash "$REPO/vm/guest/tests/probe.sh" || exit 1

verdict() { echo "$*" >"$OUT/verdict"; echo "play: $*"; }

if [[ $MODE == passthrough ]]; then
	card="$(awk 'tolower($3) ~ /^0x1102/ { print $1; exit }' "$OUT/codecs.txt")"
else
	card="$(awk '{ print $1; exit }' "$OUT/codecs.txt")"
fi
pcm="/dev/snd/pcmC${card}D0p"
for _ in {1..25}; do
	[[ -e $pcm ]] && break
	sleep 0.2
done
if [[ ! -e $pcm ]]; then
	verdict "no playback device $pcm"
	exit 1
fi

# The control names change with the codec, so a failure here is not fatal.
amixer -c "$card" sset Master 80% unmute >/dev/null 2>&1 || true

rc=0
timeout 20 speaker-test -D "plughw:$card,0" -c 2 -l 1 -t sine -f 440 2>&1 |
	tee "$OUT/play.txt" || rc=$?
if ((rc == 0)); then
	verdict "speaker-test on plughw:$card,0 OK"
else
	verdict "speaker-test on plughw:$card,0 failed (exit $rc)"
fi
exit "$rc"
