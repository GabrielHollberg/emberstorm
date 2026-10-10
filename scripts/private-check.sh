#!/bin/sh
# Refuses a commit that would put something private into this public
# repository: any line it adds, or its message, matching a pattern in the
# owner's private list (the private repo's private-words.txt). The list itself
# is private, so it is read from the private repo cloned beside this one, or
# from $EMBERSTORM_PRIVATE_WORDS.
#
#   sh scripts/private-check.sh install     set it up as this clone's hooks
#   sh scripts/private-check.sh staged      check what is staged (pre-commit)
#   sh scripts/private-check.sh message F   check a commit message (commit-msg)
#
# Never get past it with --no-verify: take the private thing out instead.
set -eu

root=$(git rev-parse --show-toplevel)
words=${EMBERSTORM_PRIVATE_WORDS:-$root/../emberstorm-private/private-words.txt}

patterns() {
	if [ ! -f "$words" ]; then
		echo "private-check: the private word list is missing ($words)." >&2
		echo "Clone GabrielHollberg/emberstorm-private beside this repo, then commit again." >&2
		exit 1
	fi
	grep -v '^[[:space:]]*#' "$words" | grep -v '^[[:space:]]*$' | tr -d '\r'
}

check() { # $1: what is being checked, stdin: its text
	list=$(mktemp)
	patterns > "$list"
	found=$(grep -n -i -E -f "$list" || true)
	rm -f "$list"
	if [ -n "$found" ]; then
		echo "private-check: $1 holds something private (see CLAUDE.md, \"Nothing private\"):" >&2
		echo "$found" | head -20 >&2
		echo "Take it out, or use a made-up stand-in, and commit again." >&2
		exit 1
	fi
}

# gofmt_staged refuses Go files staged unformatted: the image build stops at
# gofmt and publishes nothing, and from 8 to 10 October every new install got
# an old EmberStorm because of four files nobody had formatted. Go's own gofmt
# where it is installed, else the same in Docker (this PC has no Go); neither,
# and it says so and lets the commit through - the build still checks.
gofmt_staged() {
	files=$(git diff --cached --name-only --diff-filter=ACMR -- '*.go')
	[ -n "$files" ] || return 0
	dir=$(mktemp -d)
	for f in $files; do
		mkdir -p "$dir/$(dirname "$f")"
		git show ":$f" | tr -d '\r' > "$dir/$f"
	done
	if command -v gofmt >/dev/null 2>&1; then
		bad=$(cd "$dir" && gofmt -l .)
	elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
		host=$dir
		command -v cygpath >/dev/null 2>&1 && host=$(cygpath -m "$dir")
		bad=$(MSYS_NO_PATHCONV=1 docker run --rm -v "$host:/c" -w /c golang:1.27-alpine gofmt -l .)
	else
		echo "private-check: no gofmt here and Docker is not running - Go formatting not checked." >&2
		rm -rf "$dir"
		return 0
	fi
	rm -rf "$dir"
	if [ -n "$bad" ]; then
		echo "private-check: these Go files need gofmt (the image build would refuse them, and installs would get an old EmberStorm):" >&2
		echo "$bad" | sed 's#^\./#  #' >&2
		echo "Format them (gofmt -w, or in Docker: golang:1.27-alpine gofmt -w) and commit again." >&2
		exit 1
	fi
}

case "${1:-}" in
install)
	hooks=$(git rev-parse --git-path hooks)
	mkdir -p "$hooks"
	printf '#!/bin/sh\nexec sh "$(git rev-parse --show-toplevel)/scripts/private-check.sh" staged\n' > "$hooks/pre-commit"
	printf '#!/bin/sh\nexec sh "$(git rev-parse --show-toplevel)/scripts/private-check.sh" message "$1"\n' > "$hooks/commit-msg"
	chmod +x "$hooks/pre-commit" "$hooks/commit-msg"
	patterns > /dev/null
	echo "private-check: installed in $hooks"
	;;
staged)
	git diff --cached -U0 --no-color --no-ext-diff | grep '^+' | grep -v '^+++ ' | sed 's/^+//' | check "a change being committed"
	gofmt_staged
	;;
message)
	grep -v '^#' "$2" | check "the commit message"
	;;
*)
	echo "usage: sh scripts/private-check.sh install|staged|message FILE" >&2
	exit 2
	;;
esac
