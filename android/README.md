# EmberStorm for Android

A native shell around the server's own web app - the Android counterpart of
`ios/`, and the app for Google TV, Android TV and Fire TV as well. The page
stays the one product, so every web change reaches the app at once; only what
a web view cannot do well (music with the screen off, the lock screen, photo
backup, keeping downloads) is native. Android 9 or newer (`minSdk` 28): below
it any app on the phone could control the music, as a controller could not be
told apart. More in the documentation site (`site/`).

What is native, and what is still the page:

- **Songs from the server are played natively**, by Media3's ExoPlayer in a
  media session service (`AudioService`, driven through `NativeAudio`). The
  page keeps deciding everything - the queue, the looks, the lyrics - and its
  `<audio>` element is a stand-in that passes play, pause, seek, volume and
  speed to the player and reports its state back. Android then treats the app
  as a music player: it keeps playing with the screen off, pauses for an alarm
  or a call and plays on after, and gives the lock screen, notification,
  headphones and a car their controls. The next ten songs are handed over
  ahead, so the music carries on even if Android ends the page, and the app
  saves an audiobook's place itself every ten seconds and when it stops, so
  an hour listened with the screen off is not lost. The sleep timer is kept
  by the player too. Crossfade is off in the app.
- **Downloads are kept by the app** (`KeptFiles.kt`), in its own folder,
  which the system never clears and backups leave out: the page hands each
  file over, and a downloaded song or book plays from the app's copy through
  the native player. When the server cannot be reached, the app opens its
  kept copy of the page on the downloads (from any of the install's
  addresses, preferring one holding downloads), with Change server, and
  loads the server again by itself once it answers.
- **Photo backup** (`PhotoBackup.kt`): WorkManager jobs that send the phone's
  camera roll to `PUT /api/photos/backup`, checking with
  `POST /api/photos/backup/check` first, so the server is the one record and
  a reinstall sends nothing twice; while the folder's marker
  (`GET /api/photos/backup/marker`) holds, only photos not yet confirmed are
  checked. A phone backs up to any number of servers, one person each: the
  first person to sign in to a server is asked "Is this your phone?", and only
  whoever says yes gets the switch there (`claim`, `release`), its sends
  waiting while somebody else is signed in. The page's Settings → Your photos
  holds the switch and its options (Wi-Fi only, videos, only while charging);
  never on a TV or for the public demo's account. One backup runs at a time,
  in the foreground with a quiet notification where Android allows, and
  Settings shows the file being sent.
- **Adding media in the background** (`Uploads.kt`): Add media's files, and
  anything shared to EmberStorm from another app's Share sheet (`Shared.kt`),
  get the page's usual review and are then sent by the app, carrying on with
  the app closed (Wi-Fi only and while charging, if asked).
- **Several saved servers** (`ServerAddress.kt`): the connect screen lists
  **Your servers**, the latest used first; tap to switch, long-press to rename
  or remove. Each keeps its own sign-in, carried between an install's home and
  away names. The app also looks for servers on the network
  (`ServerDiscovery.kt`) and offers a new box with no owner yet as **Set it
  up**, its setup code scanned off the label or typed. A typed address can be
  just the code at the start of an install's name.
- **Links**: `https://<name>/link/<code>` (a TV's sign-in QR code) and
  `names.emberstorm.app/open` open the app (verified App Links), as does
  `soundstorm://link`; only servers the app knows are opened. Settings has
  **Scan the TV's code** (Google's code scanner), and while the phone
  controls a TV its volume buttons turn the TV's volume.
- **TV**: the manifest adds `LEANBACK_LAUNCHER` and a banner, and marks leanback
  and a touchscreen as not required, so phones install it as before. On a TV the
  web view's user agent gains `SoundStormTV/1` and the page switches to its
  remote-control mode.

## Running it on your phone

The quickest way is the debug build, sideloaded:

1. On the phone: Settings → About phone → tap **Build number** seven times, then
   Settings → System → Developer options → turn on **USB debugging**.
2. Plug the phone in and allow the computer when it asks.
3. From this folder:

   ```sh
   ./gradlew installDebug        # gradlew.bat on Windows
   ```

4. Open EmberStorm and enter your server's address - the one you open in a
   browser.

Or build `app/build/outputs/apk/debug/app-debug.apk` with `./gradlew
assembleDebug` and open it on the phone (it will ask to allow installs from
wherever you opened it). A TV takes the same APK over the network:
`adb connect <tv-address>`, then `adb install -r app-debug.apk`.

Android Studio opens this folder as it is. Building needs a JDK 17 or newer and
the Android SDK (platform 36); `local.properties` says where the SDK is and is
not committed.

## Releasing a build

Builds are published from `main`, from the PC:

1. Raise `versionCode` (and `versionName`) in `app/build.gradle.kts`, so a
   phone installs over the last one.
2. `./gradlew assembleDebug`.
3. Publish it as `EmberStorm-<version>.apk` on a GitHub **pre-release**
   named `android-<version>`. Never mark it Latest: Latest is the computers'
   release, which the README's download links follow. The website's Android
   tab links one release's APK by name, so change it there too.

The published build is the debug build type, signed with the debug key so each
installs over the last, but with `isDebuggable = false` - a published APK that
is debuggable hands its cookies to anybody with adb.

**Google Play is coming.** `./gradlew bundleRelease` makes an app bundle
signed with an **upload key**, whose file and password are kept outside this
repository (`EMBERSTORM_UPLOAD_PROPERTIES`, else
`~/.emberstorm/android-upload.properties`); without it a release build is
unsigned. Google keeps the key phones see (Play App Signing), and the names
service lists both that key and the debug key, so app links open either
version. A phone moving from the GitHub version to Play's uninstalls once, as
their signatures differ.

## The things to check on a real phone

- Play a song, lock the phone, wait a few minutes: does it keep playing and move
  on to the next song?
- Do the lock screen, the notification, headphone buttons and a car's controls
  pause, skip and seek?
- Set an alarm (or take a call) while music plays: does it pause, then play on
  after?
- Leave the app for another for a while: is the music still playing, and does
  the app take it over again when reopened?
- Does a film go full screen?
- Turn on photo backup in Settings → Your photos: do the photos arrive in your
  folder on the server, and does a second run send nothing again?
- Add a second server under Change server: does switching back keep you signed
  in?
- Download a song, then turn the network off and open the app: does it open
  on the downloads, and come back to the server by itself once online?

## Testing on the emulator

```sh
# an emulator phone with enough memory - the default 2GB is killed as the page loads
avdmanager create avd -n soundstorm-test -k "system-images;android-37.0;google_apis_playstore_ps16k;x86_64" -d pixel_7
emulator -avd soundstorm-test -memory 4096 -no-audio

./gradlew installDebug
```

Then open the app and enter `http://10.0.2.2:8099` - 10.0.2.2 is the computer
the emulator runs on. (A launch extra that set the address was removed: any app
on the phone could have used it to point EmberStorm at its own server.)

The web view can be inspected at `chrome://inspect`, or driven by Playwright
with `adb forward tcp:9333 localabstract:webview_devtools_remote_<pid>` and
`chromium.connectOverCDP('http://localhost:9333')` - but only from a build with
`isDebuggable = true`, which is how WebView debugging is switched on. Flip it
locally for that and never commit or publish it.

On the developer's own install (the one with training switched on), Settings →
Playback on this device in the app has **Sound cut out? Send a report**, which
sends what the native player saw to the server; no other install shows it.

`adb shell cmd media_session dispatch pause` (or `play`, `next`, `previous`)
presses a media button, as headphones or the lock screen would.

## Icons

The launcher icon, the TV banner and the connect screen's logo are drawn by
`scripts/make-icons.py`; the notification icon is `res/drawable/ic_stat_soundstorm.xml`,
from the same shapes. Change the script, not the PNGs.
