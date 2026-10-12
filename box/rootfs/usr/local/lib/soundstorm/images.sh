#!/bin/sh
# Loads the container images built into the box, the first time it starts,
# and deletes each archive once loaded so the system disk gets the room back.
# An archive that fails to load is kept, for the next boot to try again, and
# said on the box's screen (storage-problem, screen.sh): EmberStorm would
# otherwise try for ever to download images named only for this box, the
# screen saying "starting" (the box's blind review).
#
# How far it has got goes in /run/soundstorm/progress (phase, step, done,
# total - bytes of the archives), for the box's screen and the phone's search
# (the caretaker's starting.go answers it until EmberStorm can). The whole is
# remembered the first time (images-total), so a start cut short and begun
# again carries on from where the bar was.
set -eu
dir=/var/lib/soundstorm-images
progress=/run/soundstorm/progress
mkdir -p /run/soundstorm /var/lib/soundstorm

size_left() {
	total=0
	for f in "$dir"/*.tar; do
		[ -f "$f" ] || continue
		total=$(( total + $(stat -c %s "$f") ))
	done
	echo "$total"
}
count_left() {
	n=0
	for f in "$dir"/*.tar; do
		[ -f "$f" ] && n=$((n + 1))
	done
	echo "$n"
}
say() {
	tmp="$progress.$$"
	printf 'phase=%s\nstep=%s\ndone=%s\ntotal=%s\n' "$1" "$2" "$3" "$4" >"$tmp"
	mv -f "$tmp" "$progress"
}

[ -s /var/lib/soundstorm/images-total ] || {
	printf '%s %s\n' "$(size_left)" "$(count_left)" >/var/lib/soundstorm/images-total
}
read -r whole count </var/lib/soundstorm/images-total || { whole=$(size_left); count=$(count_left); }
[ "${whole:-0}" -gt 0 ] || whole=1

failed=""
for tar in "$dir"/*.tar; do
	[ -f "$tar" ] || continue
	left=$(size_left)
	n=$(( count - $(count_left) + 1 ))
	say images "Preparing EmberStorm's programs ($n of $count)" $(( whole - left )) "$whole"
	echo "soundstorm-images: loading $(basename "$tar")"
	if docker load -q -i "$tar"; then
		rm -f "$tar"
	else
		echo "soundstorm-images: could not load $tar; keeping it" >&2
		failed=1
	fi
done
if [ -n "$failed" ]; then
	rm -f "$progress"
	printf '%s\n' "EmberStorm's programs could not be loaded from the box's built-in drive. Switch the box off and on again; if this stays, contact support." >/run/soundstorm/storage-problem
	exit 1
fi
rm -f /var/lib/soundstorm/images-total
# Unpacked: EmberStorm is started next, and the caretaker lets go of its port
# (up.sh waits for that).
say starting "Starting EmberStorm" "$whole" "$whole"
