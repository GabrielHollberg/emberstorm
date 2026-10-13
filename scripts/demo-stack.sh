#!/bin/sh
# The public demo server (2026-10-13): an EmberStorm apart from the owner's in
# every way - its own containers, volumes, library, port and install id, so its
# own *.emberstorm.app names - that anybody, the app stores' reviewers first,
# may sign in to as "demo" and look at and play everything, changing nothing
# that outlasts the night (SOUNDSTORM_DEMO_USER, internal/httpapi/demo.go).
#
# Only media anyone may show: the starter library, the Blender Foundation's
# open films (CC BY), public-domain and CC0 music from the Internet Archive
# (Open Goldberg Variations, Musopen), public-domain books from Project
# Gutenberg (through its pglaf mirror, two seconds apart, as it asks), and
# photos from Lorem Picsum (the Unsplash License). Never the owner's library
# or backends.
#
#   scripts/demo-stack.sh up        make it (or start it again), then its accounts
#   scripts/demo-stack.sh snapshot  keep its data as it is now: what reset puts back
#   scripts/demo-stack.sh reset     put its data back to the snapshot (every night)
#   scripts/demo-stack.sh update    put the build the live server runs into it
#   scripts/demo-stack.sh down      remove it, volumes included (the library stays)
#
# Its folder (DEMO_DIR, outside the repository) holds the library and
# secrets.env - the owner's and the demo account's passwords, the setup code.
# Those and its address go in the private repo only, never here.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=${DEMO_DIR:-$(cd "$ROOT/.." && pwd)/emberstorm-demo}
PORT=${DEMO_PORT:-8199}
IMAGE=${DEMO_IMAGE:-soundstorm:dev}
NET=ss-demo
VOLUMES="ss-demo-state ss-demo-imdb ss-demo-imup ss-demo-jf ss-demo-nd ss-demo-absconf ss-demo-absmeta"
CONTAINERS="ss-demo-db ss-demo-redis ss-demo-immich ss-demo-jellyfin ss-demo-navidrome ss-demo-abs ss-demo-app"
pinned() { awk -v s="  $1:" '$0==s{f=1;next} f&&/^  [a-z]/{f=0} f&&/^    image: /{print $2; exit}' "$ROOT/docker-compose.yml"; }
export MSYS_NO_PATHCONV=1
# python3 on Windows is the Store's stand-in; the real one is python.
PY=$(command -v python 2>/dev/null || command -v python3)
pyc() { "$PY" "$@" | tr -d '\r'; }
hostpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
LIB=$(hostpath "$DIR/library")
up_ok() { curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; }
sources() { curl -fsS "http://127.0.0.1:$PORT/healthz" 2>/dev/null | sed -n 's/.*"sources": *\([0-9]*\).*/\1/p'; }

secrets() {
	mkdir -p "$DIR"
	f="$DIR/secrets.env"
	if [ ! -f "$f" ]; then
		rnd() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
		( umask 077
		  {
			echo "SETUP_CODE=$(rnd 10)"
			echo "OWNER_PASSWORD=$(rnd 12)"
			# Typed by a reviewer: letters and digits, long enough for the rules,
			# and not the account's name with a little round it, which they refuse.
			echo "DEMO_PASSWORD=$(rnd 8)"
			echo "DB_PASSWORD=$(rnd 12)"
		  } >"$f" )
	fi
	# shellcheck disable=SC1090
	. "$f"
}

get() { # get URL FILE: once, kept if already there
	[ -s "$2" ] && return 0
	mkdir -p "$(dirname "$2")"
	# curl.exe on Windows reads a Windows path, and path conversion is off.
	curl -fsSL --retry 3 -o "$(hostpath "$2.part")" "$1" || { echo "could not download $1" >&2; exit 1; }
	mv "$2.part" "$2"
}

media() {
	[ -f "$DIR/.made" ] && return 0
	L="$DIR/library"
	mkdir -p "$L/music" "$L/movies" "$L/tv" "$L/pictures" "$L/ebooks" "$L/documents" "$L/audiobooks"
	echo "downloading the demo's media (about 1 GB)..."
	ia=https://archive.org/download
	# Films: the Blender Foundation's open films, CC BY.
	get "$ia/BigBuckBunny_124/Content/big_buck_bunny_720p_surround.mp4" "$L/movies/Big Buck Bunny (2008)/Big Buck Bunny (2008).mp4"
	get "$ia/Sintel/sintel-2048-stereo_512kb.mp4" "$L/movies/Sintel (2010)/Sintel (2010).mp4"
	get "$ia/ElephantsDream/ed_1024_512kb.mp4" "$L/movies/Elephants Dream (2006)/Elephants Dream (2006).mp4"
	get "$ia/Tears-of-Steel/tears_of_steel_720p.mp4" "$L/movies/Tears of Steel (2012)/Tears of Steel (2012).mp4"
	# Music: Open Goldberg Variations (CC0) whole, and some of Musopen's Chopin (CC0).
	curl -fsS "https://archive.org/metadata/OpenGoldbergVariations" | pyc -c '
import json, sys
for f in json.load(sys.stdin)["files"]:
    if f["name"].endswith(".mp3"): print(f["name"])' | while IFS= read -r n; do
		title=${n##* - }
		get "$ia/OpenGoldbergVariations/$(printf '%s' "$n" | pyc -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))')" \
			"$L/music/Kimiko Ishizaka/Open Goldberg Variations/$title"
	done
	curl -fsS "https://archive.org/metadata/musopen-chopin" | pyc -c '
import json, sys
names = sorted(f["name"] for f in json.load(sys.stdin)["files"] if f["name"].endswith(".mp3"))
print("\n".join(names[:14]))' | while IFS= read -r n; do
		get "$ia/musopen-chopin/$(printf '%s' "$n" | pyc -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))')" \
			"$L/music/Frédéric Chopin/Musopen Chopin/$n"
	done
	# Books: public domain, from Project Gutenberg's mirror, two seconds apart.
	for b in "1342:Jane Austen:Pride and Prejudice" "11:Lewis Carroll:Alice's Adventures in Wonderland" \
		"84:Mary Shelley:Frankenstein" "1661:Arthur Conan Doyle:The Adventures of Sherlock Holmes" "2701:Herman Melville:Moby Dick"; do
		id=${b%%:*}; rest=${b#*:}; author=${rest%%:*}; title=${rest#*:}
		get "https://gutenberg.pglaf.org/cache/epub/$id/pg$id-images-3.epub" "$L/ebooks/$author/$title/$title.epub"
		sleep 2
	done
	# Photos: Lorem Picsum (the Unsplash License), the demo account's own, by
	# month - kept aside until its account is made (accounts), as an account is
	# refused when a photo folder of its name is already there.
	m=0
	for id in 10 11 15 16 17 18 19 20 22 24 27 28 29 37 39 41 42 43 46 47 49 50 53 54 55 57 58 59 64 65; do
		m=$((m + 1)); month=$(printf '%02d' $(( (m % 12) + 1 )))
		get "https://picsum.photos/id/$id/1600/1067.jpg" "$DIR/demo-photos/2025/$month/photo-$id.jpg"
	done
	touch "$DIR/.made"
}

run_containers() {
	docker network create "$NET" >/dev/null 2>&1 || true
	start() { docker start "$1" >/dev/null 2>&1; }
	lan=$(sed -n 's/^SOUNDSTORM_TLS_HOSTS=//p' "$ROOT/.env" 2>/dev/null | head -n 1 | cut -d, -f1)
	start ss-demo-db || docker run -d --restart unless-stopped --name ss-demo-db --network "$NET" --memory 768m \
		-e POSTGRES_USER=postgres -e POSTGRES_DB=immich -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_INITDB_ARGS=--data-checksums \
		--shm-size 128m -v ss-demo-imdb:/var/lib/postgresql/data "$(pinned immich-database)" >/dev/null
	start ss-demo-redis || docker run -d --restart unless-stopped --name ss-demo-redis --network "$NET" --memory 128m "$(pinned immich-redis)" >/dev/null
	sleep 5
	start ss-demo-immich || docker run -d --restart unless-stopped --name ss-demo-immich --network "$NET" --memory 1536m \
		-e DB_HOSTNAME=ss-demo-db -e DB_USERNAME=postgres -e DB_DATABASE_NAME=immich -e DB_PASSWORD="$DB_PASSWORD" \
		-e REDIS_HOSTNAME=ss-demo-redis -e IMMICH_MACHINE_LEARNING_ENABLED=false \
		-v "$LIB/pictures:/pictures:ro" -v ss-demo-imup:/data "$(pinned immich-server)" >/dev/null
	start ss-demo-jellyfin || docker run -d --restart unless-stopped --name ss-demo-jellyfin --network "$NET" --memory 1536m \
		-v "$LIB/movies:/media/movies:ro" -v "$LIB/tv:/media/tv:ro" -v ss-demo-jf:/config "$(pinned jellyfin)" >/dev/null
	start ss-demo-navidrome || docker run -d --restart unless-stopped --name ss-demo-navidrome --network "$NET" --memory 384m \
		-e ND_MUSICFOLDER=/music -e ND_DATAFOLDER=/data -e ND_SUBSONIC_DEFAULTREPORTREALPATH=true -e ND_SCANINTERVAL=1m \
		-e ND_ENABLEEXTERNALSERVICES=false -e ND_ENABLETRANSCODINGCONFIG=true \
		-v "$LIB/music:/music:ro" -v ss-demo-nd:/data "$(pinned navidrome)" >/dev/null
	start ss-demo-abs || docker run -d --restart unless-stopped --name ss-demo-abs --network "$NET" --memory 512m \
		-v "$LIB/audiobooks:/audiobooks" -v ss-demo-absconf:/config -v ss-demo-absmeta:/metadata "$(pinned audiobookshelf)" >/dev/null
	start ss-demo-app || docker run -d --restart unless-stopped --name ss-demo-app --network "$NET" --memory 768m \
		-p "0.0.0.0:$PORT:8080" \
		-e SOUNDSTORM_PORT="$PORT" -e SOUNDSTORM_SETUP_CODE="$SETUP_CODE" -e SOUNDSTORM_DEMO_USER=demo \
		-e SOUNDSTORM_TLS=auto -e SOUNDSTORM_TLS_HOSTS="$lan" -e SOUNDSTORM_REMOTE_ACCESS=on \
		-e SOUNDSTORM_UPDATE_CHECK=off -e SOUNDSTORM_STARTER_LIBRARY=true -e SOUNDSTORM_LIBRARY_DIR=/library \
		-e SOUNDSTORM_NAVIDROME_URL=http://ss-demo-navidrome:4533 \
		-e SOUNDSTORM_JELLYFIN_URL=http://ss-demo-jellyfin:8096 -e SOUNDSTORM_JELLYFIN_MEDIA_PATH=/media/movies -e SOUNDSTORM_JELLYFIN_TV_PATH=/media/tv \
		-e SOUNDSTORM_IMMICH_URL=http://ss-demo-immich:2283 -e SOUNDSTORM_IMMICH_MEDIA_PATH=/pictures \
		-e SOUNDSTORM_AUDIOBOOKSHELF_URL=http://ss-demo-abs:80 -e SOUNDSTORM_AUDIOBOOKSHELF_MEDIA_PATH=/audiobooks \
		-v "$LIB:/library" -v ss-demo-state:/var/lib/soundstorm "$IMAGE" >/dev/null
	for _ in $(seq 1 90); do up_ok && break; sleep 2; done
	up_ok || { echo "the demo server did not start" >&2; exit 1; }
}

wait_sources() {
	for _ in $(seq 1 120); do [ "$(sources || echo 0)" -ge "$1" ] 2>/dev/null && break; sleep 5; done
}

accounts() {
	jar=$(mktemp)
	api() { curl -fsS -b "$jar" -c "$jar" -H 'Content-Type: application/json' -X "$1" "http://127.0.0.1:$PORT$2" ${3:+-d "$3"}; }
	api POST /api/signup "{\"username\":\"owner\",\"password\":\"$OWNER_PASSWORD\",\"setupCode\":\"$SETUP_CODE\"}" >/dev/null 2>&1 ||
		api POST /api/login "{\"username\":\"owner\",\"password\":\"$OWNER_PASSWORD\"}" >/dev/null
	api PUT /api/settings/server-name '{"name":"EmberStorm Demo"}' >/dev/null || true
	# Said when it fails, other than for an account already there.
	out=$(curl -sS -b "$jar" -c "$jar" -H 'Content-Type: application/json' -X POST "http://127.0.0.1:$PORT/api/users" 		-d "{\"username\":\"demo\",\"password\":\"$DEMO_PASSWORD\"}")
	case "$out" in *'"user"'* | *exists* | *taken*) ;; *) echo "the demo account could not be made: $out" >&2 ;; esac
	# Its photos into its own folder, now that it is there.
	if [ -d "$DIR/demo-photos" ] && [ ! -d "$DIR/library/pictures/Personal/demo/2025" ]; then
		mkdir -p "$DIR/library/pictures/Personal/demo"
		cp -r "$DIR/demo-photos/." "$DIR/library/pictures/Personal/demo/"
		api POST /api/library/rescan '{}' >/dev/null 2>&1 || true
	fi
	rm -f "$jar"
}

up() {
	secrets
	media
	run_containers
	accounts
	echo "waiting for the demo's media servers to set up (a few minutes the first time)..."
	wait_sources 5
	echo "the demo server is up on port $PORT ($(sources) sources). Accounts: $DIR/secrets.env"
}

stop_all() { for c in $CONTAINERS; do docker stop "$c" >/dev/null 2>&1 || true; done; }
start_all() { for c in $CONTAINERS; do docker start "$c" >/dev/null 2>&1 || true; done; }
TAR_IMAGE=alpine:3

snapshot() {
	stop_all
	mkdir -p "$DIR/snapshot"
	snap=$(hostpath "$DIR/snapshot")
	for v in $VOLUMES; do
		docker run --rm -v "$v:/v:ro" -v "$snap:/s" "$TAR_IMAGE" tar -C /v -cf "/s/$v.tar" . || { start_all; exit 1; }
	done
	start_all
	for _ in $(seq 1 60); do up_ok && break; sleep 2; done
	echo "kept: $(ls "$DIR/snapshot" | wc -l) volumes"
}

reset() {
	[ -d "$DIR/snapshot" ] || { echo "no snapshot to put back: run snapshot first" >&2; exit 1; }
	stop_all
	snap=$(hostpath "$DIR/snapshot")
	for v in $VOLUMES; do
		[ -f "$DIR/snapshot/$v.tar" ] || continue
		docker run --rm -v "$v:/v" -v "$snap:/s:ro" "$TAR_IMAGE" sh -c 'find /v -mindepth 1 -delete && tar -C /v -xf "/s/'"$v"'.tar"'
	done
	start_all
	for _ in $(seq 1 90); do up_ok && break; sleep 2; done
	wait_sources 5
	echo "$(date '+%F %T') put back to the snapshot ($(sources) sources)" | tee -a "$DIR/reset.log"
}

update() {
	tmp=$(mktemp -d)
	docker cp soundstorm:/usr/local/bin/soundstorm "$(hostpath "$tmp")/soundstorm"
	docker cp "$(hostpath "$tmp")/soundstorm" ss-demo-app:/usr/local/bin/soundstorm
	rm -rf "$tmp"
	docker restart ss-demo-app >/dev/null
	for _ in $(seq 1 60); do up_ok && break; sleep 2; done
	echo "the demo runs the live server's build ($(sources) sources)"
}

down() {
	for c in $CONTAINERS; do docker rm -f "$c" >/dev/null 2>&1 || true; done
	for v in $VOLUMES; do docker volume rm "$v" >/dev/null 2>&1 || true; done
	docker network rm "$NET" >/dev/null 2>&1 || true
	echo "removed (the library and secrets stay in $DIR)"
}

case "${1:-}" in
up | snapshot | reset | update | down) secrets; "$1" ;;
*) echo "usage: demo-stack.sh up|snapshot|reset|update|down" >&2; exit 2 ;;
esac
