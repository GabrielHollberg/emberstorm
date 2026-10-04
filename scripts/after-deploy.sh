#!/bin/sh
# Run after every deploy (CLAUDE.md, "How this is developed"). Fails loudly if
# the deploy broke something, before the owner finds it:
#
#   1. the live server: healthy, and its page loads without a script error
#      (an error while the page loads stops the whole app - it happened);
#   2. the throwaway test server (scripts/smoke-stack.sh) gets the build the
#      live server now runs, and a browser signs in and walks every main
#      screen at phone, TV and computer size: music plays, photos and a video
#      open, a film plays, a book opens, Settings opens.
#
# The first run installs its browser library (scripts/smoke/) and makes the
# test server, which takes a few minutes; after that about a minute.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIVE=${SOUNDSTORM_LIVE:-http://localhost:8099}
SMOKE=http://127.0.0.1:${SMOKE_PORT:-8296}

if [ ! -d "$ROOT/scripts/smoke/node_modules/playwright" ]; then
  echo "installing the check's browser library (once)..."
  (cd "$ROOT/scripts/smoke" && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --silent --no-audit --no-fund) >/dev/null
fi

status=0
echo "== the live server ($LIVE)"
node "$ROOT/scripts/smoke/smoke.js" live "$LIVE" || status=1

echo "== the test server, on the new build"
sh "$ROOT/scripts/smoke-stack.sh" update
node "$ROOT/scripts/smoke/smoke.js" app "$SMOKE" || status=1

if [ "$status" -eq 0 ]; then echo "AFTER-DEPLOY CHECK PASSED"; else echo "AFTER-DEPLOY CHECK FAILED - see above" >&2; fi
exit "$status"
