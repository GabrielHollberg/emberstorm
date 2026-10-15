# EmberStorm for developers

## The idea

Installing self-hosted media servers is a solved problem. What nobody finishes
is the *integration*: four containers, four admin accounts, four API keys, four
web UIs and four search boxes. EmberStorm is that last mile. It runs the
specialist servers, sets up their credentials itself, and puts one interface on
top. The person using it never learns Jellyfin exists.

Using the real servers instead of reimplementing them is the whole trick. When
a search for "dune" returns a film with a real poster and synopsis, that is
Jellyfin's work, not EmberStorm's. EmberStorm owns login, search, playback and
the bytes, and deliberately does **not** own transcoding, metadata scraping or
library scanning.

The documentation site (`site/`, under Architecture) is the design record:
the decisions, and the reasons for them, including the ones that were reversed.

## Building and running

```sh
git clone https://github.com/GabrielHollberg/emberstorm && cd emberstorm
docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build
```

`docker-compose.yml` names a published image and nothing else, so it works on
its own for somebody who never cloned anything. `docker-compose.dev.yml` adds
`build: .` on top.

```sh
go test ./...
pwsh scripts/make-sample-media.ps1     # a synthetic library, no downloads
pwsh scripts/fetch-test-library.ps1    # ~750MB of real public-domain media
```

On Windows, Smart App Control refuses to run freshly built test binaries, so
run the suite in a container instead, as CI does:

```sh
docker run --rm -v "//h/dev/soundstorm:/src" -w /src golang:1.27-alpine go test ./...
```

Every push to `main` runs `.github/workflows/publish.yml`, which tests and
builds multi-arch images (amd64 and arm64) to
`ghcr.io/gabrielhollberg/soundstorm` as `:latest`, and also tags each build
`sha-<commit>` with a provenance attestation GitHub signs - a box's build and
releases take EmberStorm's image only by that tag and digest, checked
(`box/app-image.sh`), never `:latest`. Pushing a tag `vX.Y.Z` also publishes
that version and makes the GitHub release. The commit hook
(`scripts/private-check.sh`) refuses Go files gofmt would change, as CI does.

**A computer release is a signed list, not the branch.**
`scripts/desktop-release.sh` writes `desktop.json` - `install.ps1`,
`install.sh`, the compose file with EmberStorm's image pinned by digest, and
`EmberStorm.exe`, each by its SHA-256 and with a serial that only goes up - and
the release key signs it on a YubiKey (`box/yubikey.py sign`, or from a phone
with `android/signer/`). `EmberStorm.exe` (`cmd/emberstorm-setup`, signed by
hand on the PC with a code-signing certificate), the Mac app and the Linux
updater (`emberstorm-update.sh`, left by `install.sh`) all check that list
against the keys built into them (`internal/desktoprelease`, the same keys as
`box/release.pub`) and every file against it before running anything, and
refuse a release older than the one installed. `EmberStorm.dmg` comes from the
Mac and is carried over from release to release. The README's download links
are `/releases/latest/download/EmberStorm.exe` and `.../EmberStorm.dmg`, so
they always follow the newest release. `EmberStorm.exe` runs an `install.ps1`
lying beside it only when `EMBERSTORM_LOCAL_INSTALLER=1` is set and a `.git`
folder is there too (a developer's checkout); otherwise only the checked
release. Android builds are GitHub pre-releases named `android-<version>`,
never Latest.

## How it works

```
                              browser
                                 │  one origin, one cookie
                         ┌───────▼────────┐
                         │   soundstorm   │  auth · search · player · byte proxy
                         └───────┬────────┘
   ┌───────────┬─────────────┬───┴──────────┬────────────┬─────────────┬──────────────┐
   ▼           ▼             ▼              ▼            ▼             ▼              ▼
Navidrome   Jellyfin   Audiobookshelf    Immich     Storyteller   AudioMuse-AI   library/ebooks
 music     films + TV    audiobooks      photos     read-along    moods, radio   library/documents
                                                                                 (folders)
                 — no backend publishes a port; EmberStorm is the only door —
```

Two more helpers sit behind it the same way: Kokoro (an AI voice, for making
an audiobook from an ebook) and Whisper (speech to text, for making an ebook
from an audiobook), both driven by `internal/voices`.

Three rules hold it together:

1. **A dead backend must never take the search down.** Every backend gets its
   own deadline and error slot. If Jellyfin is restarting you still get your
   music, and the response says which source failed.
2. **Normalization happens at the edge.** Each adapter is the only code that
   knows its backend's vocabulary. Everything past it speaks `media.Item`.
3. **A backend is two halves: search and provisioning.** A backend a human must
   configure by hand defeats the point.

And one consequence: **nothing upstream reaches the browser.** EmberStorm
fetches media server-side and pipes it through, which is what lets the backends
stay off any published port, and what makes "one login" true.

Ebooks and documents have no backend. An EPUB describes itself and needs no
transcoding, so EmberStorm reads the folder directly. That is the line:
EmberStorm owns a media type only when it is self-describing and needs no
transcoding. Video never will be.

## Layout

```
cmd/soundstorm/        main, env config, subcommands (backup, restore, reset-password, train-looks)
cmd/soundstorm-names/  the name service behind *.emberstorm.app
cmd/soundstorm-caretaker/  the box's root helper (internal/caretaker)
cmd/emberstorm-setup/  EmberStorm.exe, the signed Windows download
internal/media/        Item, Query, Kind - the shared vocabulary
internal/source/       the Source interface, optional interfaces, Registry
internal/source/*/     one package per backend (subsonic, jellyfin, audiobookshelf,
                       immich, storyteller, audiomuse, localbooks, opds)
internal/provision/    first-boot credential provisioning  <- the load-bearing part
internal/federate/     parallel fan-out, per-source deadlines, merge, rank
internal/stream/       media byte proxy with Range support
internal/httpapi/      HTTP handlers
internal/webui/        the embedded UI (vanilla JS, no build step)
internal/library/      the folders: intake, placement, duplicates, the bin
internal/collections/  per-person favorites, playlists, history, listens
internal/state/        credentials, accounts, sessions - what must survive a restart
internal/auth/         login, PBKDF2, sessions, throttling
internal/servetls/     local certificate authority, one port for http and https
internal/acme/         a minimal RFC 8555 client (dns-01)
internal/names/        the name service's logic
internal/portmap/      PCP, NAT-PMP and UPnP port mapping
internal/plex/         importing playlists from Plex
internal/scrobble/     ListenBrainz
internal/discover/     MusicBrainz, ListenBrainz, Wikipedia
internal/lyrics/       LRCLIB
internal/epub/, pdf/, tags/   read just enough metadata, no dependencies
internal/photoimport/  bringing photo downloads in (Takeout, iCloud, social), dates and sidecars
internal/beats/        hearing every song for its beats, on the server
internal/flac/         a FLAC decoder, for the beats
internal/training/     the developer's tool for training the visualizers
internal/httpx/        the hardened HTTP client every adapter uses
internal/qr/           QR codes for signing a TV in and inviting people, no dependency
internal/voices/       making audiobooks (Kokoro) and ebooks (Whisper)
internal/mp4hls/       long single-file audiobooks served in pieces (HLS)
internal/caretaker/    the box's helper: updates, Start over, the power button, USB drives
internal/desktoprelease/  checking a signed computer release (desktop.json)
internal/episodeguide/ TVmaze, for checking a show's episode numbering
internal/version/      the build's commit and date, shown in Settings, About
internal/starter/      the starter library bundled into the binary
android/               the Android app (phones and TVs); see android/README.md
ios/                   the iPhone and Apple TV apps; see ios/README.md
mac/                   the Mac setup app; see mac/README.md
box/                   the box's system image, USB stick and releases; see box/README.md
install.ps1, install.sh   the Windows and the Mac and Linux installers
site/                  the documentation website: how it all works, in depth
web/                   the website, emberstorm.app
```

## Adding a backend

Two halves:

1. **Search.** Implement `source.Source` in `internal/source/<name>/`, plus
   `source.Streamer` and `source.ArtProvider` if it serves bytes, and whichever
   optional interfaces fit (`ItemGetter`, `RecentLister`, `Rescanner`...).
2. **Provisioning.** Add a function in `internal/provision/` that walks the
   backend's first-run flow and returns credentials, and register it.

The second half is the one people skip, and the one that matters.

## Conventions

- **Zero third-party Go dependencies.** Standard library only, including
  password hashing (`crypto/pbkdf2`). There is no `go.sum`.
- **Two vendored browser libraries**, foliate-js (MIT) and hls.js (Apache-2.0),
  checked in under `internal/webui/assets/vendor/`, pinned and embedded, fetched
  at no point during a build.
- **No config file.** Environment variables set by compose, plus the state
  EmberStorm provisions itself.
- **Every new `SOUNDSTORM_` setting must also be added to `docker-compose.yml`**,
  which passes settings by name.
- **Fail loudly at startup, degrade gracefully at runtime.**
- `gofmt` clean, `go vet` clean, tests pass.
- Every backend image is pinned by digest in `docker-compose.yml` (most with their
  version in a comment); only EmberStorm's own is a tag. A new backend
  version reaches nobody until it is tried and its digest put there.
- Each backend has a network of its own with EmberStorm alone, on a fixed
  /24 in 10.231.0.0/16. **Any new compose network needs a fixed subnet**:
  Docker otherwise may hand out the home router's own range.

## API

The UI talks to EmberStorm's JSON API under `/api/`. The routes are listed in
`Routes()` in `internal/httpapi/httpapi.go`. Every route needs a session except
sign-up, sign-in and sign-out, `/api/session`, `/api/remote-reachable`,
`/healthz`, `/ca.crt` and the static files, plus the few a device uses before
anybody is signed in on it: waiting for a new device's approval
(`/api/login/pending/{id}`), "Who's listening?" (`GET /api/profiles`,
`POST /api/profiles/switch`), signing a TV in from a phone (`/api/link`),
accepting an invitation (`/api/invite/{token}`), a phone handing a TV to its
person (`/api/players/switch`, with a one-time code), and, on a box, the power
button's password reset (`/api/reset/...`).
Owner-only routes are mounted separately (a route registered for the owner
must also be mounted, or it answers 404), and cross-site requests are refused.
A TV switched to somebody from their phone gets a playback-only session: owner
routes and most writes answer 403 with `"limited": true` until that person
chooses themselves there with their PIN or password. The demo account
(`SOUNDSTORM_DEMO_USER`) may change only what an allowlist names; anything else
answers 403 with `"demo": true`.
An account held to choosing a new password gets a 403 with `"mustRenew": true`
from every guarded route but `/api/account/password`. A search always answers 200: check
`degraded` and `sources` for what was missing.

## Notes

- Plain http answers only at home addresses (a LAN address, a name with no
  dot, `.local` and the like): a request from the internet to the away name or
  the public address is sent on to https (`servetls.OnlyHomeOverHTTP`), except
  the names service's reachability check.
- The module path is still `github.com/GabrielHollberg/soundstorm`, though the
  repository is now `github.com/GabrielHollberg/emberstorm`: internal names
  keep "soundstorm".
- EmberStorm is licensed AGPL-3.0; versions before 2026-10-04 stay MIT.
- The starter library (one ebook, one audiobook, one song; public domain or CC)
  is embedded in the binary and unpacked once. `scripts/fetch-starter-media.sh`
  records where each file comes from.
