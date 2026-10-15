# EmberStorm for the Mac

One app that sets EmberStorm up on a Mac the first time it is opened, and
starts and opens it every time after - the Windows setup window and its
desktop icon in one, so nobody types a command into Terminal.

It drives the Mac and Linux installer (`install.sh` at the repository's root)
rather than doing the installing itself, run with no terminal - and **only the
signed release's**: it downloads the latest release's `desktop.json` and its
signature, checks them against the release keys built into it
(`EmberStorm/SignedRelease.swift`, Ed25519 by CryptoKit; a Go test keeps them
the same as `box/release.pub`), checks every file's size and SHA-256, keeps
them in Application Support/EmberStorm/release, and runs that `install.sh`
with `SOUNDSTORM_RELEASE_DIR`, so nothing comes from the branch. A release that
does not check out runs nothing, and one older than the installed serial is
refused. Its questions are asked first, in the window (where the media goes,
keeping the Mac awake), and passed on as settings (`--library`,
`EMBERSTORM_KEEP_AWAKE`); the Mac's password is asked in a macOS window
(`SUDO_ASKPASS`); what it ends with comes back through `EMBERSTORM_RESULT` for
the finished page. Running `install.sh` in Terminal is unchanged by any of
this.

A folder counts as installed only once the setup marked it so
(`SOUNDSTORM_INSTALLED=1` in `.env`), or, for an install from before the mark,
when Docker holds EmberStorm's accounts volume or container; a setup stopped
part way opens as the setup again and carries on.

Installed, opening the app starts Docker Desktop if it is not running, starts
EmberStorm, waits for it to answer and opens it in the browser with
`?here=server`; its window steps aside, and a cloud in the menu bar has Open
EmberStorm, Update, **Update by itself at night** (on unless turned off),
Uninstall and Quit. The night's update is a LaunchAgent of the person's own
(`dev.soundstorm.mac.update`, at a time chosen once between 2 and 5) running
the app with `--nightly-update`: no window, nothing unless a newer signed
release is out and Docker is running, the old version put back if the new one
does not start, and what it did written to `update.log`. Uninstall asks in
one window - keep a copy of the accounts, remove the downloaded programs, and,
only where the setup changed them, remove Docker Desktop and let the Mac sleep
on its own again - then offers to move the app to the Trash.

```sh
xcodebuild -project mac/EmberStorm.xcodeproj -scheme EmberStorm build
```

In a debug build, `-script /path/to/install.sh` runs a checkout's installer
instead of the release's, `-releaseBase <url> -releaseKey <key>` check a test
release signed with a throwaway key, `-page questions|finished` opens straight
on a page, and
`-snapshot out.png` draws the window to a picture (nothing else may capture
the screen without Screen Recording permission).

The icon is an Icon Composer document (`EmberStorm/AppIcon.icon`), drawn by
`scripts/make-icons.py`: macOS 26 put any older-style icon on a grey plate.

To hand it out it must be signed with a **Developer ID Application**
certificate and notarized, or macOS refuses to open it. The account holder
makes that certificate (developer.apple.com, Certificates); then:

```sh
xcodebuild archive -project mac/EmberStorm.xcodeproj -scheme EmberStorm \
  -archivePath /tmp/EmberStorm-mac.xcarchive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath /tmp/EmberStorm-mac.xcarchive \
  -exportOptionsPlist mac/export-developer-id.plist -exportPath /tmp/EmberStorm-mac
xcrun notarytool wait <id> ...   # the export uploads it; then
xcodebuild -exportNotarizedApp -archivePath /tmp/EmberStorm-mac.xcarchive -exportPath /tmp/EmberStorm-mac-out
NOTARY_KEY=... NOTARY_KEY_ID=... NOTARY_ISSUER=... \
  sh mac/make-dmg.sh /tmp/EmberStorm-mac-out/EmberStorm.app ~/Downloads/EmberStorm.dmg
```

It is handed out as a disk image with a link to Applications, dragged across
as any Mac app is, as `EmberStorm.dmg` on the latest release - each new
computer release carries it over from the last, and a new one is built only
when `mac/` changes. It does not move itself: moving or deleting its own copy in
Downloads made macOS ask "EmberStorm would like to access files in your
Downloads folder" (the second run, 2026-10-10).
