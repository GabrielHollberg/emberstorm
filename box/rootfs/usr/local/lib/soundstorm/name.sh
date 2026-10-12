#!/bin/sh
# The box's name on the home network is emberstorm (routers list it so, and
# emberstorm.local reaches it) - it was soundstorm before the rename, and a
# box made then is renamed here at its next start, once (2026-10-12, the
# owner's asking: his father's router listed "soundstorm"). Any other name
# somebody gave the box is left alone.
set -eu
[ "$(hostname)" = soundstorm ] || exit 0
hostnamectl set-hostname emberstorm
if grep -q '[[:space:]]soundstorm\([[:space:]]\|$\)' /etc/hosts; then
	sed -i 's/\([[:space:]]\)soundstorm\([[:space:]]\|$\)/\1emberstorm\2/' /etc/hosts
fi
systemctl try-restart avahi-daemon || true
