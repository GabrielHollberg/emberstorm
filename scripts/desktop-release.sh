#!/bin/sh
# Makes a signed release of EmberStorm for computers (Windows, Mac, Linux):
# the files the installers run, and desktop.json listing each with its
# SHA-256, for the release key on its YubiKey to sign.
#
#   sh scripts/desktop-release.sh -v VERSION -s SERIAL [-e EmberStorm.exe] [-o DIR]
#
# then, on the PC the YubiKey is plugged into (its PIN and a touch):
#
#   py box\yubikey.py sign DIR\desktop.json
#
# and publish: sh scripts/desktop-release.sh -p -v VERSION -o DIR
#
# What goes in is the code of one commit on main (APP_COMMIT, default HEAD):
# install.ps1, install.sh, the icon, and docker-compose.yml with EmberStorm's
# own image pinned to the build GitHub's workflow made of that commit, its
# provenance checked (box/app-image.sh, strict: a release refuses without the
# check). -e adds the signed EmberStorm.exe, so updates on Windows replace it
# with one the YubiKey also vouched for. SERIAL only ever goes up: installs
# refuse a release older than the one they have.
#
# EmberStorm.exe checks desktop.json against the keys built into it
# (internal/desktoprelease, the box's release.pub) and every file against the
# list before anything runs. A change on GitHub the YubiKey did not sign
# reaches nobody.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
version='' serial='' exe='' dir='' publish=''
while getopts v:s:e:o:p opt; do
	case $opt in
	v) version=$OPTARG ;;
	s) serial=$OPTARG ;;
	e) exe=$OPTARG ;;
	o) dir=$OPTARG ;;
	p) publish=1 ;;
	*) exit 2 ;;
	esac
done
case $version in
[0-9]*.[0-9]*) ;;
*) echo "usage: desktop-release.sh -v VERSION -s SERIAL [-e EmberStorm.exe] [-o DIR] | -p -v VERSION -o DIR" >&2; exit 2 ;;
esac
[ -n "$dir" ] || dir="$HOME/emberstorm-desktop-$version"
tag="v$version"

if [ -n "$publish" ]; then
	for f in desktop.json desktop.json.sig install.ps1 install.sh docker-compose.yml; do
		[ -s "$dir/$f" ] || { echo "No $f in $dir: make and sign the release first." >&2; exit 1; }
	done
	# The Mac's setup app is built and notarized on the Mac only: carried
	# over from the release that is Latest now, so the website's Mac button
	# keeps working once this one is.
	if [ ! -s "$dir/EmberStorm.dmg" ]; then
		gh release download --pattern EmberStorm.dmg -D "$dir" 2>/dev/null || true
	fi
	if ! gh release view "$tag" >/dev/null 2>&1; then
		gh release create "$tag" --title "EmberStorm $version" --notes "EmberStorm $version." --latest
	fi
	[ -s "$dir/EmberStorm.dmg" ] && gh release upload "$tag" "$dir/EmberStorm.dmg" --clobber
	# Every file the list names, the list, and its signature.
	set -- "$dir/desktop.json" "$dir/desktop.json.sig"
	for f in $(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["files"]))' "$dir/desktop.json"); do
		set -- "$@" "$dir/$f"
	done
	gh release upload "$tag" "$@" --clobber
	echo "Published $tag. Check: the Windows download answers, and EmberStorm.exe takes it."
	exit 0
fi

case $serial in
'' | *[!0-9]*) echo "SERIAL must be a number (higher than the last release's)." >&2; exit 2 ;;
esac

# shellcheck source=box/app-image.sh
. "$repo/box/app-image.sh"
app_image strict

mkdir -p "$dir"
chmod 700 "$dir"
rm -f "$dir"/*
for f in install.ps1 install.sh emberstorm.ico; do
	app_git show "$APP_COMMIT:$f" >"$dir/$f"
done
default='${SOUNDSTORM_IMAGE:-ghcr.io/gabrielhollberg/soundstorm:latest}'
app_git show "$APP_COMMIT:docker-compose.yml" >"$dir/docker-compose.yml.src"
[ "$(grep -cF "$default" "$dir/docker-compose.yml.src")" = 1 ] || {
	echo "docker-compose.yml does not name EmberStorm's image as expected." >&2
	exit 1
}
python3 - "$dir/docker-compose.yml.src" "$dir/docker-compose.yml" "$default" "\${SOUNDSTORM_IMAGE:-$APP_IMAGE}" <<'EOF'
import sys
src, dst, old, new = sys.argv[1:]
data = open(src, 'rb').read()
open(dst, 'wb').write(data.replace(old.encode(), new.encode(), 1))
EOF
rm -f "$dir/docker-compose.yml.src"
if [ -n "$exe" ]; then
	cp "$exe" "$dir/EmberStorm.exe"
fi

python3 - "$dir" "$version" "$serial" "$APP_COMMIT" "$APP_IMAGE" <<'EOF'
import hashlib, json, os, sys, datetime
d, version, serial, commit, image = sys.argv[1:]
files = {}
for name in sorted(os.listdir(d)):
    if name.startswith('desktop.json'):
        continue
    data = open(os.path.join(d, name), 'rb').read()
    files[name] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
manifest = {
    "kind": "emberstorm-desktop",
    "version": version,
    "serial": int(serial),
    "commit": commit,
    "image": image,
    "created": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "files": files,
}
with open(os.path.join(d, 'desktop.json'), 'w', newline='\n') as f:
    json.dump(manifest, f, indent=2)
    f.write('\n')
EOF

echo
echo "Release $version (serial $serial) made in $dir:"
ls -l "$dir"
echo
echo "Sign it on the PC with the YubiKey (its PIN and a touch):"
echo "  py box\\yubikey.py sign $(wslpath -w "$dir/desktop.json" 2>/dev/null || echo "$dir/desktop.json")"
echo "then publish: sh scripts/desktop-release.sh -p -v $version -o $dir"
