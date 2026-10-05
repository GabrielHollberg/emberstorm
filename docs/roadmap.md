# Roadmap

SoundStorm works end to end today: one sign-in and one search over music,
films and TV, audiobooks, ebooks, documents and photos, on the web and in apps
for Android (phones, Google TV, Android TV, Fire TV), iPhone and Apple TV. It
sets up its media servers itself, with nobody logging in, and keeps them out
of sight. What follows is ordered by what most changes whether SoundStorm is
usable by somebody other than the people building it - not by what is most
interesting to build.

## 1. Ready for anyone to install

Almost all testing so far has been on one household's server and devices. The
next step is making sure a stranger's first hour goes well.

- **Fresh installs on other machines.** Work through
  [the fresh-install checklist](fresh-install-check.md) on more Windows PCs,
  Macs and Linux boxes, and fix whatever trips it.
- **Signed apps and installer.** The Android app is signed with a test key;
  moving to a release key (one reinstall for everyone) is what the Play Store
  needs. The Windows setup file is unsigned, which is why it needs the Unblock
  step.
- **The App Store.** The iPhone and Apple TV apps are in testing (TestFlight);
  next is review and release.
- **Real-world checks still owed:** the Plex playlist import against a real
  Plex account; Live Photos through sending, sharing and saving; very large
  libraries (a 100,000-song library, Jellyfin's first scan of a big film
  collection, several people converting video at once).
- **An iPhone Share extension**, so Share > SoundStorm adds to the library as
  it already does on Android.

## 2. SoundStorm on a box

A small computer with SoundStorm already on it, for people leaving the cloud:
plug it into power and the router, scan the code on the sticker, make an
account. The system image and its signed, self-reverting updates work in a
virtual machine; a test unit is next. See [`box/README.md`](../box/README.md).

- **On real hardware:** the image written to the box, the power button's
  password reset (pressed five times), Start over and Erase everything, and
  bringing media in from a USB drive.
- **Setting up from the sticker:** a setup code made when the box is prepared
  and printed on it, and the Android app's "We found your new SoundStorm - Set
  it up" (the iPhone app has it).
- **Backups to a USB drive:** nightly once one is plugged in, with the app
  saying plainly when there is no backup or one has not run.
- **Updates in Settings**, and the box's helper updating itself.
- **Film conversion on the box's graphics chip**, and heavy background jobs
  (photo recognition, song analysis) taking turns at night.

## 3. Growing beyond a handful of installs

Every install shares the `soundstorm.dev` name service. It is cheap and holds
no state, and it has limits to plan for:

- **Let's Encrypt's rate limits.** Renewals now say what they replace (ACME
  Renewal Information), so only new installs count against the weekly limit;
  past roughly forty new installs a week, Let's Encrypt's rate limit
  adjustment.
- **DNS records.** The registrar allows 2,500 records per domain; the zone's
  DNS moves to a host with more at around 1,500 installs.
- **The Public Suffix List**, once installs number in the thousands, so that
  one install's name is never "same site" as another's to a browser.

The rule that keeps the service cheap, and must not bend: **it never carries
media.**

## 4. Later

- **Optional paid services that never lock anything a box can do:** encrypted
  cloud backup (the key stays with the customer), and a relay for homes that
  cannot be reached from outside (carrier-grade NAT).
- **Casting** to a Chromecast, which needs short-lived per-song addresses.
- **More ebook formats:** MOBI, AZW3, FB2 and CBZ (foliate-js has readers for
  them; the server would need their metadata).
- **Read Along's version picker**, for a book that has both a narrator and an
  AI voice, or an original ebook and one made from the audiobook.
- **Photos:** albums kept as albums when importing from Google or Apple,
  near-duplicate photos (an edited or re-compressed copy), and a cover chosen
  by hand for an album.
- **Skipping intros**, which needs a Jellyfin plugin to know where they are.
- **Last.fm scrobbling**, which needs an API key registered to the project
  (ListenBrainz works today).
- **Bitmap subtitles** (PGS, VOBSUB), which would mean burning them into the
  picture; only text subtitles are offered.
- **Signing out one device at a time.** Today changing a password signs every
  other device out; new devices can be made to need approval.
- **Per-title restrictions** ("only these films"): access is per whole shelf.

## Recently done

Photos sent from one person to another, albums, and shared albums (look, or
add photos too, with an invitation to accept and Save to my photos for
keeping); everyone's photos private to them, the owner included; a
Google-style photo timeline with videos in it; the phone as a TV's remote, for
music, films and photos; inviting family by QR code; profiles with PINs;
read-along as one moving line or a word at a time; making an audiobook from an
ebook and an ebook from an audiobook; a check after every deploy that walks
every main screen; and the license, now the GNU AGPL.

## Deliberately not planned

Transcoding *by SoundStorm*, metadata scraping, library scanning, and
rebuilding an app store - each has sunk projects like this one, and each is
done better by the servers SoundStorm runs. See CLAUDE.md for why.

TV apps were on this list, and were built anyway, knowingly: Android TV and
Google TV run the Android app with the page's TV mode, and Apple TV has a
native app because tvOS has no web view.
