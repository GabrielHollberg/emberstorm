#!/bin/sh
# Starts SoundStorm's containers (or stops them, with "stop" - never down -v:
# the volumes are people's accounts and settings). The images built into the
# box are used when compose.images.yml is there; a box without it downloads.
set -eu
# One at a time: the caretaker's updates and resets and the address check
# (address.sh, which holds the lock across its own look and start) never
# start and stop the stack at once.
if [ -z "${SOUNDSTORM_UP_LOCKED:-}" ]; then
	export SOUNDSTORM_UP_LOCKED=1
	exec flock /run/soundstorm-up.lock "$0" "$@"
fi
cd /opt/soundstorm
set -- "${1:-up}"
files="-f compose.yml -f compose.box.yml"
[ -f compose.images.yml ] && files="$files -f compose.images.yml"
case "$1" in
stop) exec docker compose $files stop ;;
# A reset's: the containers go, the volumes stay (never -v).
down) exec docker compose $files down --remove-orphans ;;
*) exec docker compose $files up -d --remove-orphans ;;
esac
