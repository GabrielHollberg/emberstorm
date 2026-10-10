#!/bin/sh
# Run after every deploy (CLAUDE.md, "How this is developed"). Fails loudly if
# the deploy broke something, before the owner finds it:
#
#   1. the live server: healthy, and its page loads without a script error
#      (an error while the page loads stops the whole app - it happened);
#   2. the throwaway test server (scripts/smoke-stack.sh) gets the build the
#      live server now runs, and a browser signs in and walks every main
#      screen at phone, TV and computer size: music plays, photos and a video
#      open, a film plays, a book opens, Settings opens;
#   3. GitHub's last build of the image every install downloads passed.
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

# 3. The image every install downloads: GitHub builds and publishes it after
#    each push, and refuses on any failed check - from 8 to 10 October it
#    failed on every push (four unformatted files) and nobody saw, so new
#    installs got a two-day-old EmberStorm. The newest finished build is
#    the last push's (this runs before pushing), so a failure shows on the
#    next deploy at the latest.
echo "== the image installs download (GitHub's build)"
if command -v gh >/dev/null 2>&1; then
  last=$(gh run list --workflow publish.yml --limit 10 --json status,conclusion,displayTitle,databaseId \
    --jq '[.[] | select(.status == "completed")][0] | "\(.conclusion)\t\(.databaseId)\t\(.displayTitle)"' 2>/dev/null || true)
  if [ -z "$last" ]; then
    echo "  ??    could not ask GitHub about the image build (gh not signed in?)"
  else
    result=$(printf '%s' "$last" | cut -f1)
    run=$(printf '%s' "$last" | cut -f2)
    title=$(printf '%s' "$last" | cut -f3)
    if [ "$result" = "success" ]; then
      echo "  ok    the last image build passed: $title"
    else
      echo "  FAIL  the last image build failed ($result): $title" >&2
      echo "        New installs get an older EmberStorm until it passes. Why: gh run view $run --log-failed" >&2
      status=1
    fi
  fi
else
  echo "  ??    gh is not installed here, so GitHub's image build was not checked"
fi

if [ "$status" -eq 0 ]; then echo "AFTER-DEPLOY CHECK PASSED"; else echo "AFTER-DEPLOY CHECK FAILED - see above" >&2; fi
exit "$status"
