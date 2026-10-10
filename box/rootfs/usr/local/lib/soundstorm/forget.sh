#!/bin/sh
# Starting over or erasing (the caretaker's Reset, with the mode): what the
# box keeps beside the data drive goes too, once the stack is down. The data
# drive's volumes and caches, and on erase the library, the caretaker has
# emptied itself; this is the rest, which an erased box being sold or given
# away still carried (the twelfth security pass): the system's logs, naming
# people and what they played; a volume Docker keeps on the system disk -
# Tailscale's sign-in - and any a container made for itself; and on erase
# every setting but the sticker's setup code.
set -u
mode="${1:-start-over}"
cd /opt/soundstorm || exit 1

docker volume ls -q --filter label=com.docker.compose.project=soundstorm |
	while read -r v; do
		case "$v" in *_tailscale-state) docker volume rm -f "$v" >/dev/null ;; esac
	done
# Unnamed volumes only: the named ones are the data drive's folders.
docker volume prune -f >/dev/null 2>&1 || true

journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true

if [ "$mode" = erase ]; then
	code=$(sed -n 's/^SOUNDSTORM_SETUP_CODE=//p' .env | tail -n 1)
	# Never written empty: the box would make a new code that no longer
	# matches its sticker.
	if [ -n "$code" ]; then
		umask 077
		printf 'SOUNDSTORM_SETUP_CODE=%s\n' "$code" > .env.new && mv .env.new .env
	fi
	rm -f tailscale-serve.json
	# The box's own settings are written again, as at every start.
	/usr/local/lib/soundstorm/prepare.sh
fi
