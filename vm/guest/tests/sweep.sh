#!/usr/bin/env bash
# sweep.sh: run probe.sh, then play on each AE-7 output for a set time.
# Speakers in 5.1 with spoken channel names, then Headphone with a 440 Hz tone.
# TEST_ARGS: "SECONDS [all|speakers|headphone] [MASTER]" (default "30 all 60").
# PASS if each phase plays. Logs the BAR2 GPIO registers per phase.
set -euo pipefail

bash "$REPO/vm/guest/tests/probe.sh" || exit 1

verdict() { echo "$*" >"$OUT/verdict"; echo "sweep: $*"; }
say() { echo "sweep: [$(cut -d' ' -f1 /proc/uptime)s] $*"; }

read -r secs outputs master _ <<<"${TEST_ARGS:-}"
secs="${secs:-30}" outputs="${outputs:-all}" master="${master:-60}"
[[ $outputs =~ ^(all|speakers|headphone)$ ]] || { verdict "bad output '$outputs'"; exit 1; }
[[ $secs =~ ^[0-9]+$ && $master =~ ^[0-9]+$ ]] || { verdict "bad TEST_ARGS '${TEST_ARGS:-}'"; exit 1; }

card="$(awk 'tolower($3) ~ /^0x1102/ { print $1; exit }' "$OUT/codecs.txt")"
[[ -n $card ]] || card="$(awk '{ print $1; exit }' "$OUT/codecs.txt")"
pcm="/dev/snd/pcmC${card}D0p"
for _ in {1..25}; do
	[[ -e $pcm ]] && break
	sleep 0.2
done
[[ -e $pcm ]] || { verdict "no playback device $pcm"; exit 1; }

# Control names come from ca0132.c. A missing control is not fatal.
ctl() { amixer -c "$card" -q cset name="$1" "$2" >/dev/null 2>&1 || say "cannot set '$1' to $2"; }
amixer -c "$card" contents >"$OUT/mixer-before.txt" 2>&1 || true
ctl 'HP/Speaker Auto Detect Playback Switch' off
ctl 'Master Playback Volume' "$master"
ctl 'Master Playback Switch' on

# Read the ca0113 GPIO block (BAR2): function select, level, direction, last write.
gpio() {
	local r line="" bdf="${AE7_BDFS%% *}"
	for r in 0x100 0x300 0x304 0x320; do
		line+=" $r=$(python3 -I "$REPO/vm/guest/tools/hda-mmio.py" --bar 2 "$bdf" read "$r" 4 2>&1 | tail -1 || true)"
	done
	say "BAR2 GPIO ($1):$line"
}

voice="-t wav"
[[ -r /usr/share/sounds/alsa/Front_Left.wav ]] || voice="-t sine -f 880"
tone="-t sine -f 440"

# Play sound $3 for $1 seconds on $2 channels. Exit 124 from timeout means it played to the end.
play() {
	local rc=0
	# shellcheck disable=SC2086
	timeout "$1" speaker-test -D "plughw:$card,0" -c "$2" $3 -l 0 >>"$OUT/sweep.txt" 2>&1 || rc=$?
	((rc == 0 || rc == 124))
}

failed=() played=()
if [[ $outputs != headphone ]]; then
	say "phase 1: Output Select=Speakers, 5.1, ${secs}s (voice names each channel)"
	ctl 'Output Select' Speakers
	ctl 'Surround Channel Config' 5.1
	if ! play "$secs" 6 "$voice"; then
		say "6 channels failed, retry in stereo"
		play "$secs" 2 "$voice" || failed+=(speakers)
	fi
	gpio speakers
	played+=("${secs}s Speakers")
fi

if [[ $outputs != speakers ]]; then
	say "phase 2: Output Select=Headphone, stereo, ${secs}s (440 Hz tone)"
	ctl 'Output Select' Headphone
	play "$secs" 2 "$tone" || failed+=(headphone)
	gpio headphone
	played+=("${secs}s Headphone")
fi

amixer -c "$card" contents >"$OUT/mixer-after.txt" 2>&1 || true
if ((${#failed[@]})); then
	verdict "playback failed on: ${failed[*]}"
	exit 1
fi
verdict "played: ${played[*]}"
