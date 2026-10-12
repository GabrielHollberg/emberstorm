#!/bin/sh
# soundstorm.local, the box's name before the rename, answered beside
# emberstorm.local: the labels on the boxes already made, and the start page
# people printed, say soundstorm.local. avahi announces the box's own name;
# this announces the old one as a second name for the same address, again
# whenever the address changes. A second box on the network finds the name
# taken and goes on without it (each has its own emberstorm-2.local).
set -u
address() {
	ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1
}
pid="" had=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; exit 0' TERM INT
while :; do
	now=$(address)
	if [ "$now" != "$had" ] || { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; }; then
		[ -n "$pid" ] && kill "$pid" 2>/dev/null
		pid=""
		if [ -n "$now" ]; then
			avahi-publish -a -R soundstorm.local "$now" >/dev/null 2>&1 &
			pid=$!
		fi
		had=$now
	fi
	sleep 30
done
