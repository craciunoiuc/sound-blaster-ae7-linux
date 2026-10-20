#!/usr/bin/env bash
# mictest.sh: run probe.sh, record the rear mic and play the take back on the headphones.
# Beep = start talking, double beep = stop. TEST_ARGS: "[SECONDS] [MASTER] [BOOST]"
# (default "8 80 0"; BOOST 0-3 = 0/10/20/30 dB). PASS if speech is above the noise floor.
set -euo pipefail

bash "$REPO/vm/guest/tests/probe.sh" || exit 1

verdict() { echo "$*" >"$OUT/verdict"; echo "mictest: $*"; }
say() { echo "mictest: [$(cut -d' ' -f1 /proc/uptime)s] $*"; }

read -r secs master boost _ <<<"${TEST_ARGS:-}"
secs="${secs:-8}" master="${master:-80}" boost="${boost:-0}"
[[ $secs =~ ^[0-9]+$ && $master =~ ^[0-9]+$ && $boost =~ ^[0-3]$ ]] || { verdict "bad TEST_ARGS '${TEST_ARGS:-}'"; exit 1; }

card="$(awk 'tolower($3) ~ /^0x1102/ { print $1; exit }' "$OUT/codecs.txt")"
[[ -n $card ]] || card="$(awk '{ print $1; exit }' "$OUT/codecs.txt")"
for _ in {1..25}; do
	[[ -e /dev/snd/pcmC${card}D0c ]] && break
	sleep 0.2
done

ctl() {
	local rc=0
	amixer -c "$card" cset name="$1" "$2" >>"$OUT/mictest-amixer.txt" 2>&1 || rc=$?
	((rc == 0)) || say "cannot set '$1' to $2"
}
ctl 'HP/Speaker Auto Detect Playback Switch' off
ctl 'Output Select' Headphone
ctl 'Master Playback Volume' "$master"
ctl 'Master Playback Switch' on
ctl 'Input Source' Microphone
ctl 'Capture Switch' on,on
ctl 'Capture Volume' 90,90
ctl 'Mic Boost Capture Switch' "$boost"
amixer -c "$card" contents >"$OUT/mixer-mic.txt" 2>&1 || true

# Make the cue sounds in tmpfs: one beep, and two beeps.
python3 -I - /tmp/beep1.wav /tmp/beep2.wav <<'EOF'
import array, math, sys, wave
def write(path, beeps):
    rate, data = 48000, array.array("h")
    for _ in range(beeps):
        for i in range(rate // 5):
            v = int(12000 * math.sin(2 * math.pi * 880 * i / rate))
            data.extend((v, v))
        data.extend([0] * (rate // 10) * 2)
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(data.tobytes())
write(sys.argv[1], 1)
write(sys.argv[2], 2)
EOF

play() { timeout 30 aplay -q -D "plughw:$card,0" "$1" >>"$OUT/mictest-play.txt" 2>&1; }

say "beep: start talking for ${secs}s"
play /tmp/beep1.wav || say "cue beep failed"
rc=0
timeout $((secs + 5)) arecord -q -D "plughw:$card,0" -f S16_LE -r 48000 -c 2 -d "$secs" "$OUT/mic.wav" \
	>"$OUT/mictest-rec.txt" 2>&1 || rc=$?
play /tmp/beep2.wav || say "cue beep failed"
say "record rc $rc; playing the take back"
play "$OUT/mic.wav" || say "playback of the take failed"

# Print the level of each second. Speech is far above the quietest second.
levels="$(python3 -I - "$OUT/mic.wav" <<'EOF'
import array, sys, wave
try:
    w = wave.open(sys.argv[1])
    rate = w.getframerate()
    a = array.array("h", w.readframes(w.getnframes()))
except Exception as e:
    print("error", e); sys.exit(0)
step = rate * 2
rms = []
for i in range(0, len(a), step):
    chunk = a[i:i + step]
    rms.append((sum(x * x for x in chunk) / len(chunk)) ** 0.5 if chunk else 0)
peak = max((abs(x) for x in a), default=0)
print("peak %d floor %.0f loudest %.0f per-second %s" % (
    peak, min(rms, default=0), max(rms, default=0), " ".join("%.0f" % r for r in rms)))
EOF
)"
say "levels: $levels"
read -r _ peak _ floor _ loud _ <<<"$levels"
if [[ $rc == 0 && $loud =~ ^[0-9]+$ && $floor =~ ^[0-9]+$ ]] && ((loud > 50 && 10 * loud > 16 * (floor + 1))); then
	verdict "mic has signal ($levels)"
	exit 0
fi
verdict "no clear mic signal (rc $rc, $levels)"
exit 1
