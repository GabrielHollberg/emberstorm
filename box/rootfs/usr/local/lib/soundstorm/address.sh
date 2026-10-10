#!/bin/sh
# Keeps EmberStorm on the box's address as the network changes under it: a
# router replaced, a power cut handing out a new address, the cable moved to
# another router. prepare.sh writes the address only when EmberStorm starts,
# so the secure name every phone saved went on pointing at the old one until
# the box was switched off and on (the blind reviews, 2026-10-10). Run every
# minute by soundstorm-address.timer; does nothing while nothing changed.
set -eu

cd /opt/soundstorm
lan=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)
dev=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)

# avahi announces soundstorm.local on the home network's port alone: on every
# interface it also answered with Docker's own addresses (10.231.x), which a
# laptop may try first and never reach.
if [ -n "$dev" ]; then
	conf=/etc/avahi/avahi-daemon.conf
	want="allow-interfaces=$dev"
	if [ -f "$conf" ] && ! grep -qx "$want" "$conf"; then
		sed -i '/^allow-interfaces=/d' "$conf"
		sed -i "/^\[server\]/a $want" "$conf"
		grep -qx "$want" "$conf" || printf '[server]\n%s\n' "$want" >> "$conf"
		systemctl try-restart avahi-daemon || true
	fi
fi

[ -n "$lan" ] || exit 0
had=$(sed -n 's/^SOUNDSTORM_TLS_HOSTS=//p' .env 2>/dev/null | tail -n 1)
[ "$lan" = "$had" ] && exit 0

# The rest under up.sh's lock, so an update cannot begin between the look
# and the start (looked at again once it is held: run again from the top).
if [ -z "${SOUNDSTORM_UP_LOCKED:-}" ]; then
	export SOUNDSTORM_UP_LOCKED=1
	exec flock /run/soundstorm-up.lock "$0" "$@"
fi

# Never in the middle of an update or a reset (the caretaker has the stack
# stopped on purpose), and never before EmberStorm's own first start.
[ -e /var/lib/soundstorm-caretaker/pending.json ] && exit 0
systemctl is-active --quiet soundstorm.service || exit 0

echo "the box's address changed from ${had:-none} to $lan"
/usr/local/lib/soundstorm/prepare.sh
# EmberStorm is started again with the new address (its settings changed,
# so compose makes it afresh); the rest are left running.
/usr/local/lib/soundstorm/up.sh
