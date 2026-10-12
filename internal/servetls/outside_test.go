package servetls

import "testing"

// The port the internet reaches the install on: its own, unless the owner
// forwarded another by hand because a second server in the house holds it.
func TestTheOutsidePortIsTheOwnersHandForward(t *testing.T) {
	hand := 0
	a := &autoCert{port: 8099, outside: func() int { return hand }}
	if a.outsidePort() != 8099 || a.awayPort() != 0 {
		t.Fatalf("no hand forward: outside %d, away %d; want 8099 and 0", a.outsidePort(), a.awayPort())
	}
	hand = 8100
	if a.outsidePort() != 8100 || a.awayPort() != 8100 {
		t.Fatalf("hand forward to 8100: outside %d, away %d", a.outsidePort(), a.awayPort())
	}
	hand = 70000
	if a.outsidePort() != 8099 {
		t.Fatalf("a port out of range was taken: %d", a.outsidePort())
	}
}
