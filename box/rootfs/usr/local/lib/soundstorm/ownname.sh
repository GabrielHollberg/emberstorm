#!/bin/sh
# Each box also answers to a name of its own on the home network, made from
# its serial (EM-7K4P-XQ2M answers as em-7k4p-xq2m.local), beside
# emberstorm.local - which is whichever box took it first: a second box on one
# network becomes emberstorm-2.local, so the label's QR code, carrying
# emberstorm.local, opened the first box and its setup code was refused (the
# owner's asking, 2026-10-12). The label's QR code carries this name, so it
# always opens the box it is stuck to. Kept up as the box's address changes;
# run by soundstorm-ownname.service.
set -u
unit=$(sed -n 's/^SOUNDSTORM_UNIT=//p' /opt/soundstorm/.env 2>/dev/null | tail -n 1 | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')
case "$unit" in em-????-????) ;; *) echo "ownname: no serial yet"; sleep 60; exit 1 ;; esac
name="$unit.local"
pid=""
had=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; exit 0' TERM INT
while :; do
	lan=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)
	if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then pid=""; fi
	if [ "$lan" != "$had" ] || { [ -n "$lan" ] && [ -z "$pid" ]; }; then
		[ -n "$pid" ] && kill "$pid" 2>/dev/null
		pid=""
		if [ -n "$lan" ]; then
			# -R: no reverse entry, which is the box's own hostname's.
			avahi-publish -a -R "$name" "$lan" >/dev/null 2>&1 &
			pid=$!
			echo "ownname: $name is $lan"
		fi
		had=$lan
	fi
	sleep 30
done
