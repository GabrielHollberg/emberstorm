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
	;;
message)
	grep -v '^#' "$2" | check "the commit message"
	;;
*)
	echo "usage: sh scripts/private-check.sh install|staged|message FILE" >&2
	exit 2
	;;
esac
