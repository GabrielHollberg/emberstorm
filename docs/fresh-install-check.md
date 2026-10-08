# Fresh-install check

The run to do before announcing EmberStorm, and again before any big release:
install it the way a stranger would, on a computer that has never had it, and
write down everything that confuses, stalls or breaks.

A fresh install gets the newest code on `main` even before a release is
published: the setup file downloads the installer from `main`'s newest
commit, and the image it pulls (`:latest`) is built on every push to `main`.

## Before you start

- **A clean computer.** It must never have had EmberStorm or Docker on it:
  a spare laptop, a friend's PC, or a Windows 11 virtual machine with
  virtualization switched on for the guest (Docker runs Linux inside it).
  Not the PC that runs the live server.
- **On the home Wi-Fi**, with an Android phone on the same network for the
  phone steps.
- **A handful of test files on a USB stick or in Downloads**, not your real
  library: three or four songs (one MP3, one FLAC or M4A), a short video
  named like a film (`Big Buck Bunny (2008).mp4`), an EPUB, an audiobook
  (an M4B or a folder of MP3s), and a few phone photos. Free ones: the
  starter library's sources, Blender's open films, LibriVox, Project
  Gutenberg.
- **A notes file and a clock.** Note the time each step starts and ends.

## Windows

1. Go to the README on GitHub as a stranger would, and click the
   **Download SoundStorm-Setup.cmd** link.
   - Did the browser warn about the download? What did it say, and what did
     you have to click?
2. Follow the README's steps exactly: **Properties → Unblock**, then
   double-click.
   - Was Unblock there? Did anything open if you skipped it?
3. The setup window. Note:
   - How long until the window appeared.
   - Each Windows permission prompt (Docker, WSL), and whether a **restart**
     was asked for. If it was, did setup carry on afterwards by itself, or did
     you have to start it again?
   - **Docker Desktop's first-run window**: was the "I understand" guide shown
     before it, and was it clear what to click?
   - The library folder question.
   - The Windows Security Alert and "Is this your home network?".
   - Any moment the window looked stuck for more than a minute, and what it
     said then.
   - Total time from double-click to "finished".
4. At the end:
   - Did the browser open EmberStorm by itself?
   - Was the **setup code** shown in the window, and did the sign-up page
     already have it filled in?
   - Is there an EmberStorm icon on the desktop?

## Mac or Linux

1. Install Docker as the README says, then paste the README's one command.
2. Note how long it took, every question it asked, and whether it printed an
   address you could open.
3. On Linux, check that adding files works afterwards (folder permissions
   were wrong there once).

## In the app (any computer)

5. **Create the owner account.** Try a weak password first (`password123`):
   was the refusal clear? Then a good one.
6. **The welcome card on Home**: does it make sense, and do its buttons go
   where they say?
7. **The starter library**: play the song, start the audiobook, open the
   ebook.
8. **Add media by dragging** the test files onto the window, all at once.
   - Was the review screen clear? Did it ask about the MP3?
   - Did each file land on the right shelf, and how long until it showed up?
   - Play the film. Open the photos.
9. **Settings**: open each group once. Anything confusing or broken?
10. **Restart the computer**, then open EmberStorm from the desktop icon.
    Does it come back by itself, and how long does it take?

## The phone (Android)

11. On the phone, open the address from **Settings → Use on your phone or TV**.
    Did it load, with no certificate warning, and did it move to the
    `.home.emberstorm.dev` name?
12. Install the Android app from the newest `android-` release on GitHub.
    - What did Android say about installing an app from outside the Play
      Store, and how many taps did it take?
    - Did the app **find the server** by itself?
    - Sign in. Play a song and lock the phone: does it keep playing, and do
      the lock screen controls work?
13. **Photo backup**: say yes when asked. Do the phone's photos show up in
    Photos within a few minutes, with the right dates?
14. **A second person**: in Settings → People, **Invite someone**, open the
    invitation on the phone (or another browser), and make that account.
    Do they see only their own photos?

## What to send back

- The notes, with times.
- A screenshot of anything that looked wrong, and the exact wording of any
  error.
- If setup failed: the log file the failure window offers (**Show log file**),
  `%TEMP%\EmberStorm-setup.log`. It has the setup code taken out, so it is
  safe to share.
- The three things that most need fixing before strangers try it.
