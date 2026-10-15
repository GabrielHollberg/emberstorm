# The EmberStorm box

What turns a small computer into an EmberStorm box: a system disk made from
Debian 13 with Docker, and the services that prepare the data drive and start
EmberStorm on it. The box is EmberStorm sold preinstalled on a mini PC, for
people leaving the cloud: plug it into power and the router, scan the code on
its label, make an account. It is being tried on a test unit and is **not for
sale yet**.

    box/models.sh       copies the backends' models out of a working install
    box/models-list.sh  the models' file list (box/models.sha256); the build refuses models that differ
    box/app-image.sh    finds EmberStorm's own image for a commit, by digest, its provenance checked
    box/build.sh        builds out/soundstorm-box.qcow2
    box/run-vm.sh       boots it as a pretend box (UEFI; an eMMC or a small system SSD beside a library drive, or one drive)
    box/installer.sh    makes the USB stick that installs it onto a real box
    box/release.sh      makes a release (manifest) for boxes to update to
    box/yubikey.py      sets up the release key on a YubiKey and signs with it (Windows)
    box/sticker.sh      prints each box's label, the card in the box, and the drives' labels
    box/units-add.sh    adds the boxes a factory stick set up to the ledger (kept privately)
    box/compose.box.yml the box's additions to docker-compose.yml
    box/packages.txt, units.txt  the Debian packages and units a box has (build and releases share them)
    box/release.pub     the release keys boxes trust, the release key first, then its backup
    box/rootfs/         files copied into the system disk

On the Windows PC, first the models (with Docker, from the live install -
models only, nothing of anybody's media), into the folder the build reads:

    OUT=//wsl.localhost/Debian/root/box-out sh box/models.sh

then the build and the VM in the Debian WSL distro, which has KVM (Docker
Desktop's own does not, and Hyper-V is off):

    wsl -d Debian -u root -- sh -c 'cd /mnt/h/dev/soundstorm && OUT=/root/box-out DEV_SSH=1 sh box/build.sh'
    wsl -d Debian -u root -- sh -c 'cd /mnt/h/dev/soundstorm && OUT=/root/box-out sh box/run-vm.sh'

`NO_IMAGES=1` makes a quick build without the images (about 12GB of them);
`SERIAL=N` sets the oldest release the box will take, and `PRODUCTION=1`
builds a box to sell: it refuses `DEV_SSH`, another release channel or key,
and a missing `SERIAL`, and takes only a checked app image and the committed
model list;
`OFFLINE=1` on `run-vm.sh` cuts the VM off the internet. `OUT` keeps the disks on WSL's own filesystem: the Windows drive is slow
through `/mnt`.

## Installing it on a real box

A box's system is written by starting the box from a USB stick. The stick
chooses the system drive: an eMMC where the box has one, otherwise the one
internal SSD of 512 GB or less that holds no library - a small system SSD
beside the large library drive, in whichever M.2 slot. It stops, writing
nothing, when it finds no such drive or more than one, and a repair stick
writes only over EmberStorm or a blank drive. **A box with one drive** (128 GB
or more) gets both on it: the system in its first 64 GiB, the library
(`SSDATA`, btrfs) in a partition from there to the end. Putting such a box
right rewrites the system's part only and puts the library's partition back
exactly as it was (found by its table entry, or by its filesystem at 64 GiB
if a cut-short repair lost the entry); its bytes are never written. A lone
library drive, or a library with no EmberStorm system beside it, is refused.
Every repair asks for a copy of the library on another drive first.
`box/sticker.sh drives` prints a SYSTEM DRIVE and a LIBRARY DRIVE label to
stick along each drive (`ONE_DRIVE=1`: one SYSTEM AND LIBRARY label a box).

    wsl -d Debian -u root -- sh -c 'cd /mnt/h/dev/soundstorm && OUT=/root/box-out sh box/installer.sh'

makes `out/emberstorm-installer.img`; write it to a stick of 16GB or more with
balenaEtcher or Rufus (DD mode), plug it into the box with the network cable
and a monitor, and start it from the stick (the boot menu key at power-on,
often F7 or F11 - not yet checked on the test unit). It shows what it is
doing, takes about ten minutes, and
switches off; take the stick out and switch on. The storage drive is kept
(putting a box right) unless the stick was made with `FACTORY=1`, which
wipes it so the box starts new, gives the box its identity (a serial
`EM-XXXX-XXXX` and a setup code, shown at the end with a QR code) and records
it in `units.csv` on the stick's own `EMBERSTORM` partition, which Windows
opens as a drive - `box/units-add.sh` adds those rows to the ledger, kept in
the private repository, never here, and `box/sticker.sh labels` prints each
box's label from it. A box from a factory stick is also started once at the
factory: it waits for EmberStorm to answer with every source, then starts it
over as new and switches off, so the buyer's first start takes a minute or
two. The factory stick's last screen says to set the firmware to switch on
when power returns. To try it in the VM, make the stick with
`INSTALL_TARGET=vda INSTALL_AUTO=1` (a repair stick otherwise waits for Enter), then `run-vm.sh installer`, then `run-vm.sh`. For a box with a system SSD, make it with `INSTALL_AUTO=1` alone and run both with `NVME_SYSTEM=1`. For a one-drive box, the same with `ONE_DRIVE=1`; `run-vm.sh repair` starts from the stick onto the drives as they are.

## How a box starts

1. `soundstorm-grow` grows the system partition to fill the system drive (on
   a one-drive box, up to the library's partition).
2. `soundstorm-storage` mounts the data drive (label `SSDATA`) at
   `/srv/soundstorm`, formatting it as btrfs the first time - **only a blank
   disk is ever formatted**, and only an internal SATA or NVMe disk is ever
   taken, never a USB one. It holds three subvolumes:
   `library`, `volumes` (every container volume that holds data) and `cache`.
   A box that never had a data drive runs on the system disk and leaves
   `/run/soundstorm/no-data-drive`; once it has had one it never starts
   without it - a missing drive stops it, with the reason on the box's screen,
   rather than letting it look new. Each model built in
   (`/var/lib/soundstorm-models/*.tar`, from `box/models.sh`) is laid into its
   cache folder when that is empty - photo search, Make an ebook and read-along
   syncing then work with no internet, and again after Start over.
3. `soundstorm-images` loads the container images built into the disk
   (`/var/lib/soundstorm-images`, deleted once loaded), so a box starts with
   no downloads; `compose.images.yml` points each service at its built-in
   image, `soundstorm-box/<service>:built`. While it unpacks, the caretaker
   answers on ports 8099 and 80 with a progress page (and `/healthz` says
   `starting`), so the apps and a browser see a box getting ready.
4. `soundstorm` writes `/opt/soundstorm/.env` from the box's identity, kept on
   the data drive (`identity/box.env`: the setup code, the serial, the
   backends' database passwords made for this box), so a repair keeps the
   label's code; then the box's address and router, and runs
   `docker compose up -d`.

The box is `emberstorm.local` on the home network (a second box becomes
`emberstorm-2.local`), and also its serial in small letters,
`em-xxxx-xxxx.local`, which its label's code opens. It answers on port 80 as
well as 8099. A monitor plugged into it shows how to reach it (before it has
an owner, the address and setup code; after, its name and address), and why it
cannot start when it cannot. `soundstorm-address` notices a new address from
the router and starts EmberStorm again on it. A USB drive plugged in is only
noticed; it is opened, read-only, when the owner chooses to bring in what is
on it. Debian's security updates install at night, and the start-up menu is
locked against editing.

## Updates (the caretaker)

`soundstorm-caretaker` (`cmd/`, `internal/caretaker`) runs on the box as
root, beside EmberStorm, never in it. A release is `manifest.json`: every
service's image pinned by digest, a serial, a version and notes, signed with
the release key (`.sig` beside it). The release key and its backup live on two
YubiKeys and never leave them: `box/release.sh -k yubikey` leaves the manifest
unsigned, and `py box/yubikey.py sign` (the PIN and a touch) or EmberStorm
Signer on a phone (`android/signer/`) signs it. A release also carries the
box's own files (`system-SERIAL.tar.gz`: `box/rootfs`, the compose files and
the caretaker, with the packages and units to have), so fixes to the box itself
arrive by update; only the box's own places are ever written, everything
replaced is kept, and a new caretaker that will not start is put back by
itself. The box takes only a manifest signed by
the key built into it (`box/release.pub`, or `RELEASE_KEY` when building)
and only one with a higher serial than it runs, so neither a forged nor an
old replayed one moves it. Releases are looked for at the GitHub release
`box-channel` (`RELEASES` when building points a development box elsewhere).
A release also says when it expires (90 days after it is made, `-days` on
`soundstorm-caretaker manifest`) and boxes refuse it after that, so it must
be made and signed again before then; it must name every service the box
runs; and a box built with `SERIAL` never takes a release not newer than
that. Auto off asks the owner first, for a month - a release still waiting
then is installed anyway. A box to sell is built with `PRODUCTION=1`, which
refuses `DEV_SSH`, `RELEASES`, `RELEASE_KEY` and a missing `SERIAL`.

An update downloads every image first (nothing changes if that fails), stops
the stack, snapshots the `volumes` subvolume, writes `compose.images.yml`
and starts it; if SoundStorm does not answer healthy with as many sources as
before within ten minutes, the snapshot is put back in place of the volumes
and the old images file, and the box is told "went back to the version you
had". A release with files of the box's own is also undone if the box can no
longer reach the release channel. Every update and reset is written down
before anything stops, so one cut short by a power cut is finished or undone
at the next start. The newest snapshot is kept for going back by hand. Once an update is in and healthy, old versions' images
are removed (`internal/caretaker/images.go`): kept are the release running,
the one before it (one step back, like the snapshot) and anything a container
still uses, and only images of repositories the box's releases have used are
ever touched - the 64GB system disk holds Docker's images, and every update
left the old ones behind. It checks three
minutes after start and every six hours, and installs at night (2-5am in the
box's time zone, which the owner's first visit to Settings sets) unless the
owner turned Auto off. EmberStorm reaches it through
`/run/soundstorm-caretaker/caretaker.sock`, mounted into its container for
group 10001: Settings, Devices, **Updates** (`GET /status`, `POST /check`,
`POST /update`, `GET`/`PUT /settings`), Switch off, the time zone, USB drives,
and Start over and Erase (`POST /reset`), which wait for ten presses of the
box's power button. Five quick presses open, for fifteen minutes, setting the
owner's password from home again, with the code on the box's screen or its
label; one press switches it off properly.

Making a release (the key stays on its YubiKey):

    sh box/release.sh -k yubikey -s SERIAL -v VERSION -n "what's new"

The serial must be higher than the last; publish `manifest.json`, its `.sig`
and `system-SERIAL.tar.gz` on the GitHub release `box-channel` (a
pre-release, never Latest). A release expires after 90 days unless signed again.

## Not built yet

Backups to a USB drive (offered at setup; "not protected" said until there
is one); adding storage as a pool; drive health (SMART) in the app; a staged
rollout and reports back; a support bundle; a real wipe for resale; licence
notices for what the image ships.
