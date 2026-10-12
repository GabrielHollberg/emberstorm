# EmberStorm Signer

The developer's own app for signing a release away from the PC: the release
key's YubiKey held to the back of an Android phone (NFC). Never published or
handed out.

1. On the PC, a release is made (`box/release.sh -k yubikey`, or
   `scripts/desktop-release.sh`) and put in the developer's server's signing
   folder, one folder per release:

       docker exec -u 0 soundstorm mkdir -p /var/lib/soundstorm/signing/box-SERIAL
       docker cp manifest.json soundstorm:/var/lib/soundstorm/signing/box-SERIAL/
       docker exec -u 0 soundstorm chown -R 10001:10001 /var/lib/soundstorm/signing

   The server must have `SOUNDSTORM_SIGNING=true` in its `.env`
   (`internal/httpapi/signing.go`).
2. On the phone: sign in to that server as its owner, read what waits (taken
   from the release's own bytes), Sign this, the signing PIN, the YubiKey to
   the back of the phone. The app checks the key is one of `box/release.pub`'s
   before signing; the server checks the signature before keeping it.
3. On the PC, the signature is taken back (`docker cp
   soundstorm:/var/lib/soundstorm/signing/box-SERIAL/manifest.json.sig .`),
   checked, and the release published.

Built with the EmberStorm app: `./gradlew :signer:assembleDebug`.
