#!/bin/sh
# Builds EmberStorm.exe (run where Go and mingw's windres are - the
# Debian WSL distro on the PC: apt-get install binutils-mingw-w64-x86-64 cpp):
#
#   sh cmd/emberstorm-setup/res/make.sh [OUT]
#
# The icon, the manifest (as the person, never asking for administrator up
# front) and the version details go into rsrc_windows_amd64.syso, which Go
# links in. Sign the result afterwards (box/../signing: SimplySign).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
pkg=$(dirname "$here")
out=${1:-$pkg/EmberStorm.exe}
cd "$here"
x86_64-w64-mingw32-windres --preprocessor=cpp --preprocessor-arg=-P -O coff -o "$pkg/rsrc_windows_amd64.syso" setup.rc
cd "$pkg"
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 GOTOOLCHAIN=auto \
	go build -trimpath -ldflags="-s -w -H windowsgui" -o "$out" .
echo "  $out"
