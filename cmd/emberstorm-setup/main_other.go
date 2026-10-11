//go:build !windows

// Command emberstorm-setup is the Windows setup's launcher
// (EmberStorm-Setup.exe); on any other system it only says so. Mac and Linux
// install with install.sh, or the Mac's setup app.
package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "EmberStorm-Setup.exe is for Windows. On a Mac or Linux, use install.sh.")
	os.Exit(1)
}
