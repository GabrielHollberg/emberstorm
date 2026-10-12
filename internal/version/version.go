// Package version says which build of EmberStorm this is: the commit it was
// built from and when that commit was made, stamped in by the image build
// (-ldflags -X, from the Dockerfile's BUILD_COMMIT and BUILD_DATE). A build
// without them - go run, a test - says so with empty values.
//
// A release's name (0.13.1) is not known here: releases are made after the
// image is built, from it. The commit and date are right on every install.
package version

import "time"

var (
	// Commit is the full commit hash, or "" for a build not stamped.
	Commit = ""
	// Date is the commit's time, RFC 3339, or "".
	Date = ""
)

// Build is what signed-in people are told (never anybody else: a version
// says which known bugs a server may have).
type Build struct {
	Commit string `json:"commit,omitempty"`
	Date   string `json:"date,omitempty"`
}

// Current is this build, the commit cut to its usual short form and the
// date checked; values that are not what the build should have stamped are
// left out rather than shown.
func Current() Build {
	var b Build
	if len(Commit) >= 7 && isHex(Commit) {
		b.Commit = Commit[:7]
	}
	if t, err := time.Parse(time.RFC3339, Date); err == nil {
		b.Date = t.UTC().Format(time.RFC3339)
	}
	return b
}

func isHex(s string) bool {
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
