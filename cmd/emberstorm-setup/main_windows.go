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
// Arguments are passed straight through to the installer, as the .cmd's were
// (EmberStorm.exe -Console, -Uninstall ...).
package main

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	defaultRepo   = "GabrielHollberg/emberstorm"
	defaultBranch = "main"
	// createNoWindow starts PowerShell with no console at all. Not
	// HideWindow: that is applied to the first window the process shows,
	// which would be the setup's own.
	createNoWindow = 0x08000000
)

func main() {
	script, err := installer()
	if err != nil {
		message("EmberStorm could not download its installer. Check the internet connection and try again.\n\n(" + err.Error() + ")")
		os.Exit(1)
	}
	ps := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	args := []string{"-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", script}
	args = append(args, os.Args[1:]...)
	cmd := exec.Command(ps, args...)
	cmd.Env = append(os.Environ(), "SOUNDSTORM_WINDOW=1")
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow}
	if err := cmd.Start(); err != nil {
		message("EmberStorm could not start its installer.\n\n(" + err.Error() + ")")
		os.Exit(1)
	}
}

// installer answers the installer to run: the one beside this program in a
// checkout of the project (where .git is - Downloads, where this is usually
// run from, is somewhere a web page can drop an install.ps1), else the newest
// one, downloaded to a file. Never run from memory: Defender blocks that.
func installer() (string, error) {
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		local := filepath.Join(dir, "install.ps1")
		if isFile(local) && exists(filepath.Join(dir, ".git")) {
			return local, nil
		}
	}
	repo := envOr("SOUNDSTORM_REPO", defaultRepo)
	branch := envOr("SOUNDSTORM_BRANCH", defaultBranch)
	url := "https://raw.githubusercontent.com/" + repo + "/" + branch + "/install.ps1"
	out := filepath.Join(os.TempDir(), "soundstorm-install.ps1")
	return out, download(url, out)
}

func download(url, out string) error {
	client := &http.Client{Timeout: 2 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("the download answered %s", resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return err
	}
	// Plainly the installer, not an error page somebody's network put in
	// its place.
	if !strings.Contains(string(data), "SOUNDSTORM_WINDOW") {
		return errors.New("what downloaded was not the installer")
	}
	tmp := out + ".new"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, out)
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
