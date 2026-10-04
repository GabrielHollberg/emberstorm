#!/bin/sh
# A throwaway SoundStorm for the after-deploy check (scripts/after-deploy.sh):
# its own music, film, photos and book, all generated or from the starter
# library - never anybody's real media - with its own test account, on
# 127.0.0.1 only. Its state lives in Docker volumes, so it survives restarts.
#
#   scripts/smoke-stack.sh up       make it (or start it again)
#   scripts/smoke-stack.sh update   put the build the live server runs into it
#   scripts/smoke-stack.sh down     remove it, volumes and media included
#
# The test account: smoke / "smoke test password 4417" (a throwaway, local).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=${SMOKE_DIR:-$ROOT/.smoke}
PORT=${SMOKE_PORT:-8296}
IMAGE=${SMOKE_IMAGE:-soundstorm:dev}
NET=ss-smoke
TOOLS=ghcr.io/immich-app/immich-server:v3 # has ffmpeg, and is pulled anyway
export MSYS_NO_PATHCONV=1

# A host path Docker on Windows understands (H:/...), as it is on Linux.
hostpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
LIB=$(hostpath "$DIR/library")

up_ok() { curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; }

media() {
  [ -f "$DIR/.made" ] && return 0
  mkdir -p "$DIR/library/music" "$DIR/library/movies" "$DIR/library/tv" "$DIR/library/pictures" "$DIR/library/ebooks" "$DIR/library/documents" "$DIR/library/audiobooks"
  echo "making the test media..."
  docker run --rm --entrypoint sh -v "$LIB:/l" "$TOOLS" -c '
    set -e
    song() { d="/l/music/$1/$2"; mkdir -p "$d"
      [ -f "$d/cover.jpg" ] || ffmpeg -loglevel error -y -f lavfi -i "gradients=s=600x600:c0=$3:c1=$4:d=1" -frames:v 1 "$d/cover.jpg"
      ffmpeg -loglevel error -y -f lavfi -i "aevalsrc=0.9*sin(2*PI*50*t)*exp(-14*mod(t\,0.5))+0.2*sin(2*PI*$6*t):s=44100:d=45" -ac 2 -c:a libmp3lame -b:a 128k \
        -metadata artist="$1" -metadata album_artist="$1" -metadata album="$2" -metadata title="$5" "$d/$5.mp3"; }
    song "Smoke Band" "First Album" 0x1b2a6b 0xd14b8f "Opening" 110
    song "Smoke Band" "First Album" 0x1b2a6b 0xd14b8f "Second Song" 130
    song "Test Trio" "Other Album" 0x0f4c5c 0xf4a259 "Harbour" 98
    f="/l/movies/Smoke Film (2020)"; mkdir -p "$f"
    ffmpeg -loglevel error -y -f lavfi -i testsrc2=duration=40:size=640x360:rate=25 -f lavfi -i sine=frequency=440:duration=40 -f lavfi -i sine=frequency=660:duration=40 \
      -map 0 -map 1 -map 2 -c:v libx264 -pix_fmt yuv420p -c:a aac -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa "$f/Smoke Film (2020).mp4"
    printf "1\n00:00:01,000 --> 00:00:30,000\nHello from the subtitles\n" > "$f/Smoke Film (2020).en.srt"
    p=/l/pictures/2026/01; mkdir -p "$p"
    i=0; for c in 0x1b2a6b:0xd14b8f 0x0f4c5c:0xf4a259 0x3a0ca3:0x4cc9f0 0x606c38:0xfefae0 0x7f1d1d:0xfbbf24 0x134e4a:0x99f6e4; do
      i=$((i+1)); ffmpeg -loglevel error -y -f lavfi -i "gradients=s=800x600:c0=${c%%:*}:c1=${c##*:}:d=1" -frames:v 1 "$p/IMG_000$i.jpg"; done
    ffmpeg -loglevel error -y -f lavfi -i testsrc2=duration=5:size=640x360:rate=25 -c:v libx264 -pix_fmt yuv420p "$p/VID_0001.mp4"
  '
  cp "$ROOT/internal/starter/media/ebooks/George S. Clason/The Richest Man in Babylon/"*.epub "$DIR/library/ebooks/" 2>/dev/null || true
  touch "$DIR/.made"
}

up() {
  if up_ok; then echo "the test server is already up at http://127.0.0.1:$PORT"; return 0; fi
  media
  docker network create "$NET" >/dev/null 2>&1 || true
  start() { docker start "$1" >/dev/null 2>&1 || return 1; }
  start ss-smoke-db || docker run -d --name ss-smoke-db --network "$NET" -e POSTGRES_USER=postgres -e POSTGRES_DB=immich -e POSTGRES_PASSWORD=smoke \
    -e POSTGRES_INITDB_ARGS=--data-checksums --shm-size 128m -v ss-smoke-imdb:/var/lib/postgresql/data \
    ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0 >/dev/null
  start ss-smoke-redis || docker run -d --name ss-smoke-redis --network "$NET" docker.io/valkey/valkey:9 >/dev/null
  sleep 5
  start ss-smoke-immich || docker run -d --name ss-smoke-immich --network "$NET" -e DB_HOSTNAME=ss-smoke-db -e DB_USERNAME=postgres -e DB_DATABASE_NAME=immich \
    -e DB_PASSWORD=smoke -e REDIS_HOSTNAME=ss-smoke-redis -e IMMICH_MACHINE_LEARNING_ENABLED=false \
    -v "$LIB/pictures:/pictures:ro" -v ss-smoke-imup:/data "$TOOLS" >/dev/null
  start ss-smoke-jellyfin || docker run -d --name ss-smoke-jellyfin --network "$NET" -v "$LIB/movies:/media/movies:ro" -v "$LIB/tv:/media/tv:ro" \
    -v ss-smoke-jf:/config jellyfin/jellyfin:latest >/dev/null
  start ss-smoke-navidrome || docker run -d --name ss-smoke-navidrome --network "$NET" -e ND_MUSICFOLDER=/music -e ND_DATAFOLDER=/data \
    -e ND_SUBSONIC_DEFAULTREPORTREALPATH=true -e ND_SCANINTERVAL=1m -e ND_ENABLEEXTERNALSERVICES=false -e ND_ENABLETRANSCODINGCONFIG=true \
    -v "$LIB/music:/music:ro" -v ss-smoke-nd:/data deluan/navidrome:latest >/dev/null
  start ss-smoke-app || docker run -d --name ss-smoke-app --network "$NET" -p "127.0.0.1:$PORT:8080" \
    -e SOUNDSTORM_SETUP_CODE=SMOKESETUP42 -e SOUNDSTORM_TLS=off -e SOUNDSTORM_STARTER_LIBRARY=false -e SOUNDSTORM_PORT=8080 \
    -e SOUNDSTORM_LIBRARY_DIR=/library -e SOUNDSTORM_NAVIDROME_URL=http://ss-smoke-navidrome:4533 \
    -e SOUNDSTORM_JELLYFIN_URL=http://ss-smoke-jellyfin:8096 -e SOUNDSTORM_JELLYFIN_MEDIA_PATH=/media/movies -e SOUNDSTORM_JELLYFIN_TV_PATH=/media/tv \
    -e SOUNDSTORM_IMMICH_URL=http://ss-smoke-immich:2283 -e SOUNDSTORM_IMMICH_MEDIA_PATH=/pictures \
    -v "$LIB:/library" -v ss-smoke-state:/var/lib/soundstorm "$IMAGE" >/dev/null
  for _ in $(seq 1 60); do up_ok && break; sleep 2; done
  up_ok || { echo "the test server did not start" >&2; exit 1; }
  # The test account (a no-op once it exists).
  curl -fsS -X POST "http://127.0.0.1:$PORT/api/signup" -H 'Content-Type: application/json' \
    -d '{"username":"smoke","password":"smoke test password 4417","setupCode":"SMOKESETUP42"}' >/dev/null 2>&1 || true
  echo "waiting for the test server's media servers to set up (a few minutes the first time)..."
  for _ in $(seq 1 90); do
    n=$(curl -fsS "http://127.0.0.1:$PORT/healthz" 2>/dev/null | sed -n 's/.*"sources": *\([0-9]*\).*/\1/p')
    [ "${n:-0}" -ge 6 ] && break
    sleep 5
  done
  echo "the test server is up at http://127.0.0.1:$PORT (${n:-0} sources)"
}

update() {
  if ! docker inspect ss-smoke-app >/dev/null 2>&1; then up; fi
  tmp=$(mktemp -d)
  docker cp soundstorm:/usr/local/bin/soundstorm "$(hostpath "$tmp")/soundstorm"
  docker cp "$(hostpath "$tmp")/soundstorm" ss-smoke-app:/usr/local/bin/soundstorm
  rm -rf "$tmp"
  docker restart ss-smoke-app >/dev/null
  for _ in $(seq 1 60); do up_ok && break; sleep 2; done
  up_ok || { echo "the test server did not come back with the new build" >&2; exit 1; }
  # Its media servers reconnect in a moment.
  for _ in $(seq 1 30); do
    n=$(curl -fsS "http://127.0.0.1:$PORT/healthz" 2>/dev/null | sed -n 's/.*"sources": *\([0-9]*\).*/\1/p')
    [ "${n:-0}" -ge 6 ] && break
    sleep 2
  done
  echo "the test server runs the new build (${n:-0} sources)"
}

down() {
  docker rm -f ss-smoke-app ss-smoke-navidrome ss-smoke-jellyfin ss-smoke-immich ss-smoke-redis ss-smoke-db >/dev/null 2>&1 || true
  docker volume rm ss-smoke-state ss-smoke-imdb ss-smoke-imup ss-smoke-jf ss-smoke-nd >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$DIR"
  echo "the test server is gone"
}

case "${1:-}" in
  up) up ;;
  update) update ;;
  down) down ;;
  *) echo "usage: $0 up|update|down" >&2; exit 2 ;;
esac
