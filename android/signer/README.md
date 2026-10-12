# EmberStorm Signer

The developer's own app for signing a release away from the PC: the release
key's YubiKey held to the back of an Android phone (NFC). Never published or
handed out.

The phone and the PC talk over Tailscale only (the developer's own private
network, already on both): the release never sits on the internet-facing
EmberStorm server, and being on the developer's Tailscale is the pass.

1. On the PC, a release is made (`box/release.sh -k yubikey`, or
   `scripts/desktop-release.sh`) and copied into a folder of its own under
   `Desktop\emberstorm-signing\` (e.g. `box-2026101102\manifest.json`).
2. On the PC: `py scripts\signing-helper.py`. It listens on the PC's
   Tailscale address alone (port 8098), refuses anything not from a
   Tailscale address, and stops by itself once everything waiting is signed.
   Windows lets it in through one rule, made once as administrator:

       New-NetFirewallRule -DisplayName "EmberStorm signing (Tailscale only)" -Direction Inbound -Protocol TCP -LocalPort 8098 -InterfaceAlias Tailscale -RemoteAddress 100.64.0.0/10 -Action Allow

3. Claude gives the release's **fingerprint** (the first 16 characters of its
   SHA-256) in the chat.
4. On the phone, Tailscale on: the PC's Tailscale name (or 100.x address), the
   card read from the release's own bytes - its fingerprint must match the
   one given - Sign this, the signing PIN, the YubiKey to the back of the
   phone. The app checks the key is one of `box/release.pub`'s before
   signing; the helper checks the signature before keeping `<file>.sig`.
5. On the PC, the signature is checked again and the release published.

Built with the EmberStorm app: `./gradlew :signer:assembleDebug`. Installed
from a release of the private repository, never this one.
