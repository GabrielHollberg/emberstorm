#!/bin/sh
# The box's own screen. A monitor plugged into the box shows, in big text,
# how to reach EmberStorm: before it has an owner, the address to open on
# any computer or tablet at home, the setup code and a QR code carrying
# both; after, its name and the address to use. Somebody with no
# smartphone can set the box up from any other screen in the house, and
# "what does the box's screen say?" is a question support can ask.
#
# Run by soundstorm-screen.service on tty1, in place of the login prompt,
# and redrawn when anything on it changes (checked every 10 seconds).
set -u

env=/opt/soundstorm/.env
port=8099

# Big letters, where the font is there (console-setup-linux), and no kernel
# messages written over the screen.
fonts=/usr/share/consolefonts
setfont $fonts/Lat15-TerminusBold32x16.psf.gz 2>/dev/null || true
# The welcome and its QR code are about 30 lines: a smaller monitor gets
# smaller letters rather than a QR code cut off at the foot.
rows=$(stty size 2>/dev/null | cut -d" " -f1)
if [ "${rows:-0}" -lt 32 ]; then
	setfont $fonts/Lat15-TerminusBold24x12.psf.gz 2>/dev/null || setfont $fonts/Lat15-Terminus24x12.psf.gz 2>/dev/null || true
fi
dmesg -n 1 2>/dev/null || true
setterm --cursor off 2>/dev/null || true

# A value from .env, or nothing.
setting() {
	sed -n "s/^$1=//p" "$env" 2>/dev/null | tail -n 1 | tr -d '\r'
}

# A string field from a JSON answer, or nothing. The answers are the
# server's own and flat; this is not a JSON reader and need not be.
field() {
	printf '%s' "$1" | tr -d '\n' | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

# The box's address on the home network: the first one that is not
# Docker's own.
address() {
	for a in $(hostname -I 2>/dev/null); do
		case "$a" in
		172.1[7-9].* | 172.2[0-9].* | 172.3[01].* | *:*) ;;
		*) echo "$a"; return ;;
		esac
	done
}

draw() {
	health=$(curl -fsS -m 3 "http://127.0.0.1:$port/healthz" 2>/dev/null || true)
	ip=$(address)
	local_name="$(hostname).local"
	printf '\033[2J\033[H\n'
	if [ -z "$health" ]; then
		printf '   EmberStorm is starting...\n\n'
		printf '   The first start takes a few minutes. This screen\n'
		printf '   changes by itself when it is ready.\n'
		[ -n "$ip" ] || printf '\n   No network yet: is the cable plugged into your router?\n'
		return
	fi
	case "$health" in
	*'"setUp": false'* | *'"setUp":false'*)
		code=$(setting SOUNDSTORM_SETUP_CODE)
		printf '   Welcome to your EmberStorm\n\n'
		printf '   On a computer or tablet at home, open:\n\n'
		printf '      http://%s\n' "$local_name"
		[ -n "$ip" ] && printf '   or http://%s\n' "$ip"
		printf '\n   Setup code:  %s\n\n' "$code"
		printf '   Or scan this with a phone, or get the EmberStorm app.\n'
		if [ -n "$code" ] && command -v qrencode >/dev/null; then
			qrencode -t UTF8 -m 2 "http://${ip:-$local_name}/?setup=$code" 2>/dev/null | sed 's/^/   /'
		fi
		;;
	*)
		name=$(field "$health" name)
		session=$(curl -fsS -m 3 "http://127.0.0.1:$port/api/session" 2>/dev/null || true)
		secure=$(field "$session" secureName)
		printf '   %s\n\n' "${name:-EmberStorm}"
		printf '   Open it on any phone, tablet, computer or TV at home:\n\n'
		if [ -n "$secure" ]; then
			printf '      https://%s:%s\n' "$secure" "$port"
			printf '   or http://%s\n' "$local_name"
		else
			printf '      http://%s\n' "$local_name"
			[ -n "$ip" ] && printf '   or http://%s\n' "$ip"
		fi
		printf '\n   Forgot the password? Press the power button on the box\n'
		printf '   five times quickly, then choose a new one on the sign-in screen.\n'
		;;
	esac
}

last=
while :; do
	# Drawn into a variable first, so the screen only flickers when what it
	# says has changed.
	now=$(draw)
	if [ "$now" != "$last" ]; then
		printf '%s\n' "$now"
		last=$now
	fi
	sleep 10
done
