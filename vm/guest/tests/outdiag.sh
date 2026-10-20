#!/usr/bin/env bash
# outdiag.sh: run probe.sh, play a sine and record "What U Hear" at the same time.
# Saves PCM status and the codec dump during playback. TEST_ARGS: Speakers|Headphone.
# PASS if the loopback capture has signal (the DSP gets and mixes the stream).
set -euo pipefail

bash "$REPO/vm/guest/tests/probe.sh" || exit 1

verdict() { echo "$*" >"$OUT/verdict"; echo "outdiag: $*"; }
say() { echo "outdiag: [$(cut -d' ' -f1 /proc/uptime)s] $*"; }

out="${TEST_ARGS:-Headphone}"
card="$(awk 'tolower($3) ~ /^0x1102/ { print $1; exit }' "$OUT/codecs.txt")"
[[ -n $card ]] || card="$(awk '{ print $1; exit }' "$OUT/codecs.txt")"
for _ in {1..25}; do
	[[ -e /dev/snd/pcmC${card}D0p ]] && break
	sleep 0.2
done

# Log each control write with its exit code; the put callbacks can fail silently.
ctl() {
	local rc=0
	amixer -c "$card" cset name="$1" "$2" >>"$OUT/outdiag-amixer.txt" 2>&1 || rc=$?
	say "cset '$1' = $2 -> rc $rc"
}
ctl 'HP/Speaker Auto Detect Playback Switch' off
ctl 'Output Select' "$out"
ctl 'Master Playback Volume' 60

speaker-test -D "plughw:$card,0" -c 2 -t sine -f 440 -l 0 >"$OUT/outdiag-play.txt" 2>&1 &
player=$!
sleep 2

sub="/proc/asound/card$card/pcm0p/sub0"
cat "$sub/status" >"$OUT/pcm-status-1.txt" 2>&1 || true
cat "$sub/hw_params" >"$OUT/pcm-hw-params.txt" 2>&1 || true
cat "/proc/asound/card$card/codec#"* >"$OUT/codec-during-play.txt" 2>&1 || true
sleep 1
cat "$sub/status" >"$OUT/pcm-status-2.txt" 2>&1 || true

say "record What U Hear (device 2) for 3s"
rec_rc=0
timeout 10 arecord -D "plughw:$card,2" -f S16_LE -r 48000 -c 2 -d 3 "$OUT/wuh.wav" \
	>"$OUT/outdiag-rec.txt" 2>&1 || rec_rc=$?
kill "$player" 2>/dev/null || true
wait "$player" 2>/dev/null || true

for f in pcm-status-1 pcm-status-2; do
	say "$f: $(/usr/bin/grep -E 'state|hw_ptr' "$OUT/$f.txt" | tr '\n' ' ')"
done
say "converters during play: $(/usr/bin/grep -E '^Node|Converter: stream=[1-9]' "$OUT/codec-during-play.txt" |
	/usr/bin/grep -B1 'stream=[1-9]' | tr '\n' ' ')"

level="$(python3 -I - "$OUT/wuh.wav" <<'EOF'
import array, sys, wave
try:
    w = wave.open(sys.argv[1])
    a = array.array("h", w.readframes(w.getnframes()))
except Exception as e:
    print("error", e); sys.exit(0)
peak = max((abs(x) for x in a), default=0)
rms = (sum(x * x for x in a) / len(a)) ** 0.5 if a else 0
print("peak %d rms %.1f samples %d" % (peak, rms, len(a)))
EOF
)"
say "What U Hear: rc $rec_rc, $level"
peak="$(awk '{ print $2 }' <<<"$level")"
if [[ $peak =~ ^[0-9]+$ ]] && ((peak > 300)); then
	verdict "loopback has signal ($level); DSP gets the stream"
	exit 0
fi
verdict "loopback silent or failed (rc $rec_rc, $level)"
exit 1
