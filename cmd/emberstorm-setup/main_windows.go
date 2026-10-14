// Command emberstorm-setup is EmberStorm.exe: what the Windows
// download is double-clicked as. It does what EmberStorm-Setup.cmd did - fetch
// the installer (install.ps1) to a file and start it with its window - as a
// program that can be signed. Smart App Control blocks a .cmd from the web by
// its extension, with no "run anyway", and an unsigned .exe outright; a
// signed one runs.
//
// It has no console (built with -H windowsgui) and opens none: PowerShell is
// started with no window of its own, and the installer, told so by
// SOUNDSTORM_WINDOW, opens its setup window straight away. A failed download
// says so in a message box, there being nothing else to say it in.
//
// What it runs is only ever a signed release (internal/desktoprelease): the
// list of files, desktop.json, signed with the release key on its YubiKey,
// and each file checked against it before anything runs. A change on GitHub
// that the YubiKey did not sign reaches nobody. The installer is told where
// the checked files are (SOUNDSTORM_RELEASE_DIR) and takes nothing from
// anywhere else; updates come back through this program.
//
// Arguments are passed straight through to the installer
// (EmberStorm.exe -Console, -Uninstall ...).
package main

import (
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"github.com/GabrielHollberg/soundstorm/internal/desktoprelease"
)

const (
	defaultRepo = "GabrielHollberg/emberstorm"
	// createNoWindow starts PowerShell with no console at all. Not
	// HideWindow: that is applied to the first window the process shows,
	// which would be the setup's own.
	createNoWindow = 0x08000000
)

func main() {
	script, env, err := installer()
	if err != nil {
		message("EmberStorm could not get its setup. Check the internet connection and try again.\n\n(" + err.Error() + ")")
		os.Exit(1)
	}
	ps := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	args := []string{"-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", script}
	args = append(args, os.Args[1:]...)
	cmd := exec.Command(ps, args...)
	cmd.Env = append(append(os.Environ(), "SOUNDSTORM_WINDOW=1"), env...)
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow}
	if err := cmd.Start(); err != nil {
		message("EmberStorm could not start its setup.\n\n(" + err.Error() + ")")
		os.Exit(1)
	}
}

// installer answers the installer to run and what to tell it: the one beside
// this program in a checkout of the project, only when a developer asks for
// it (EMBERSTORM_LOCAL_INSTALLER=1 as well as .git there - Downloads, where
// this is usually run from, is somewhere a web page or an unpacked zip can
// drop an install.ps1 and a .git, and this program is signed), else the
// newest signed release, checked and written to a folder of the person's
// own. Never run from memory: Defender blocks that.
func installer() (string, []string, error) {
	if exe, err := os.Executable(); err == nil && os.Getenv("EMBERSTORM_LOCAL_INSTALLER") == "1" {
		dir := filepath.Dir(exe)
		local := filepath.Join(dir, "install.ps1")
		if isFile(local) && exists(filepath.Join(dir, ".git")) {
			return local, nil, nil
		}
	}
	dir, m, err := fetchRelease(releaseBase())
	if err != nil {
		return "", nil, err
	}
	env := []string{
		"SOUNDSTORM_RELEASE_DIR=" + dir,
		"SOUNDSTORM_RELEASE_VERSION=" + m.Version,
		fmt.Sprintf("SOUNDSTORM_RELEASE_SERIAL=%d", m.Serial),
		"SOUNDSTORM_FRESH=1",
	}
	if exe, err := os.Executable(); err == nil {
		env = append(env, "SOUNDSTORM_LAUNCHER="+exe)
	}
	return filepath.Join(dir, "install.ps1"), env, nil
}

// releaseBase is where the newest release's files are: GitHub's latest
// release, or EMBERSTORM_RELEASE_BASE to try one - https only, or plain http
// to this computer itself (a test).
func releaseBase() string {
	if b := strings.TrimSpace(os.Getenv("EMBERSTORM_RELEASE_BASE")); b != "" {
		if u, err := url.Parse(b); err == nil && (u.Scheme == "https" ||
			(u.Scheme == "http" && (u.Hostname() == "127.0.0.1" || u.Hostname() == "localhost"))) {
			return strings.TrimRight(b, "/") + "/"
		}
	}
	return "https://github.com/" + envOr("SOUNDSTORM_REPO", defaultRepo) + "/releases/latest/download/"
}

// fetchRelease downloads the signed release and checks every file
// (desktoprelease.Fetch), writing them to %LOCALAPPDATA%\EmberStorm\release,
// a folder of this account's own, only once all are checked.
func fetchRelease(base string) (string, *desktoprelease.Manifest, error) {
	keys, err := desktoprelease.Keys()
	if err != nil {
		return "", nil, err
	}
	root := os.Getenv("LOCALAPPDATA")
	if root == "" {
		root = os.TempDir()
	}
	dir := filepath.Join(root, "EmberStorm", "release")
	m, err := desktoprelease.Fetch(base, dir, keys, desktoprelease.Get)
	if err != nil {
		return "", nil, err
	}
	return dir, m, nil
}

func envOr(name, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(name)); v != "" {
		return v
	}
	return fallback
}

func isFile(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.Mode().IsRegular()
}

func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// message shows text in a Windows message box.
func message(text string) {
	user32 := syscall.NewLazyDLL("user32.dll")
	box := user32.NewProc("MessageBoxW")
	t, _ := syscall.UTF16PtrFromString(text)
	c, _ := syscall.UTF16PtrFromString("EmberStorm Setup")
	const iconWarning = 0x30
	_, _, _ = box.Call(0, uintptr(unsafe.Pointer(t)), uintptr(unsafe.Pointer(c)), iconWarning)
}
