#!/usr/bin/env bash
# verbs.sh: run probe.sh, then send GET_PARAMETER verbs through hda-verb (hwdep).
# Dumps vendor id, revision and node counts per codec to $OUT/verbs.txt.
# PASS if each codec's vendor id from the verb matches /proc/asound and is valid.
set -euo pipefail

bash "$REPO/vm/guest/tests/probe.sh" || exit 1

verdict() { echo "$*" >"$OUT/verdict"; echo "verbs: $*"; }
say() { echo "$*"; echo "$*" >>"$OUT/verbs.txt"; }
# Print the response value of verb $2 with payload $3 to node $1 on $dev.
verb() { hda-verb "$dev" "$1" "$2" "$3" 2>/dev/null | sed -n 's/^value = //p'; }

: >"$OUT/verbs.txt"
ok=() bad=()
while read -r card addr pvid _; do
	dev="/dev/snd/hwC${card}D${addr}"
	say "== $dev (proc vendor id $pvid) =="
	if [[ ! -e $dev ]]; then
		bad+=("$dev missing")
		continue
	fi
	vid="$(verb 0x00 PARAMETERS 0x00)"
	rev="$(verb 0x00 PARAMETERS 0x02)"
	nodes="$(verb 0x00 PARAMETERS 0x04)"
	say "vendor_id=${vid:-none} revision=${rev:-none} node_count=${nodes:-none}"
	# NODE_COUNT: start node in bits 23:16, number of nodes in bits 7:0.
	if [[ $nodes =~ ^0x[0-9a-f]+$ ]]; then
		first=$(((nodes >> 16) & 0xff)) n=$((nodes & 0xff))
		for ((nid = first; nid < first + n; nid++)); do
			fg="$(printf '0x%02x' "$nid")"
			say "  fg $fg: type=$(verb "$fg" PARAMETERS 0x05)" \
				"node_count=$(verb "$fg" PARAMETERS 0x04)"
		done
	fi
	if [[ ! $vid =~ ^0x[0-9a-f]+$ ]] || ((vid == 0 || vid == 0xffffffff)); then
		bad+=("$dev vendor_id=${vid:-none}")
	elif ((vid != pvid)); then
		bad+=("$dev vendor_id=$vid but proc has $pvid")
	else
		ok+=("$dev $vid rev $rev")
	fi
done <"$OUT/codecs.txt"

if ((${#bad[@]})); then
	verdict "bad: ${bad[*]}${ok:+; ok: ${ok[*]}}"
	exit 1
fi
verdict "verbs OK: ${ok[*]}"
