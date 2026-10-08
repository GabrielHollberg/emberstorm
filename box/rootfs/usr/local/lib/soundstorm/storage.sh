#!/bin/sh
# Mounts the box's data drive at /srv/soundstorm, preparing it the first time.
#
# The data drive is the internal disk that is not the system disk (on the ME
# Mini, the NVMe drive beside the eMMC). It is known by its label, SSDATA.
# A disk is only ever formatted when it is blank - no partition table, no
# filesystem, nothing a probe recognises. A disk holding anything at all is
# left alone, whatever it is: losing somebody's files to a wrong guess here is
# the one mistake this script must never make. USB disks are never taken:
# those are backup drives.
#
# Without a data drive the box still starts, on the system disk, and says so
# in /run/soundstorm/no-data-drive for the app to report.
set -eu

MNT=/srv/soundstorm
LABEL=SSDATA
log() { echo "soundstorm-storage: $*"; }

mkdir -p "$MNT" /run/soundstorm
rm -f /run/soundstorm/no-data-drive

mounted() { mountpoint -q "$MNT"; }

root_disk() {
	src=$(findmnt -no SOURCE /)
	lsblk -no PKNAME "$src" | head -1
}

# A disk is blank when nothing on it is recognised: no partitions, and no
# signature (filesystem, RAID member, partition table) by a full probe.
blank() {
	dev=/dev/$1
	[ "$(lsblk -no NAME "$dev" | wc -l)" -eq 1 ] || return 1
	[ -z "$(blkid -p -o value -s TYPE "$dev" 2>/dev/null)" ] || return 1
	[ -z "$(blkid -p -o value -s PTTYPE "$dev" 2>/dev/null)" ] || return 1
	return 0
}

# Whether a device (a disk or one of its partitions) is on an internal disk:
# not USB, not removable. The data drive is found by its label, and a USB
# stick anybody labelled the same must never take its place: the box would
# run on whatever accounts and library were put on it (a security review).
internal() {
	disk=$(lsblk -no PKNAME "$1" 2>/dev/null | head -1)
	[ -n "$disk" ] || disk=${1#/dev/}
	tran=$(lsblk -dno TRAN "/dev/$disk" 2>/dev/null | tr -d ' ')
	rm=$(lsblk -dno RM "/dev/$disk" 2>/dev/null | tr -d ' ')
	[ "$tran" != usb ] && [ "$rm" = 0 ]
}

# Mounted from a drive that is not internal (an old fstab line by label, or
# a stick labelled to look like the data drive): let it go before anything
# reads it.
if mounted && ! internal "$(findmnt -no SOURCE "$MNT")"; then
	log "$(findmnt -no SOURCE "$MNT") is not an internal disk; not using it as the data drive"
	umount "$MNT" || exit 1
fi

if ! mounted; then
	dev=""
	for d in $(blkid -t LABEL="$LABEL" -o device 2>/dev/null); do
		if internal "$d"; then
			dev=$d
			break
		fi
		log "$d is labelled $LABEL but is not an internal disk; leaving it alone"
	done
	if [ -z "$dev" ]; then
		rootd=$(root_disk)
		# Whole internal disks: not the system disk, not USB, not removable,
		# not loop/zram/optical.
		for name in $(lsblk -dno NAME,TYPE,TRAN,RM | awk '$2=="disk" && $3!="usb" && $NF=="0" {print $1}'); do
			[ "$name" = "$rootd" ] && continue
			case "$name" in zram* | loop* | sr* | mmcblk*boot*) continue ;; esac
			if blank "$name"; then
				log "preparing /dev/$name as the data drive"
				mkfs.btrfs -q -L "$LABEL" "/dev/$name"
				udevadm settle
				dev=/dev/$name
				break
			fi
			log "/dev/$name is not blank; leaving it alone"
		done
	fi
	if [ -n "$dev" ]; then
		# Mounted by its own UUID, never by a label another drive can carry.
		uuid=$(blkid -o value -s UUID "$dev")
		sed -i "\|^LABEL=$LABEL |d" /etc/fstab
		grep -q "^UUID=$uuid " /etc/fstab ||
			echo "UUID=$uuid $MNT btrfs defaults,noatime,nofail,x-systemd.device-timeout=10s 0 0" >> /etc/fstab
		mount "$MNT"
		log "data drive $dev mounted at $MNT"
	else
		log "no data drive; keeping everything on the system disk"
		touch /run/soundstorm/no-data-drive
	fi
fi

# The three parts, as subvolumes on the data drive so each can be snapshotted
# on its own: the library, the volumes that hold data, and caches.
for part in library volumes cache; do
	if [ ! -e "$MNT/$part" ]; then
		if mounted && [ "$(findmnt -no FSTYPE "$MNT")" = btrfs ]; then
			btrfs -q subvolume create "$MNT/$part"
		else
			mkdir -p "$MNT/$part"
		fi
	fi
done

# Anyone's files go in the library, whoever the backends run as (see the
# note on 0777 library folders in CLAUDE.md). The shelves are made here, not
# left to SoundStorm: Docker starts the backends first and makes any missing
# folder they mount as root's, 0755, which SoundStorm (uid 10001) then cannot
# write into - the first VM boot lost its starter song and audiobook so.
# A shelf that is a link is put back as a folder: this runs as root, and
# chmod would open whatever a link from inside the library pointed at.
[ -L "$MNT/library" ] && rm -f "$MNT/library" && mkdir -p "$MNT/library"
# Sticky, so no shelf can be swapped for a link (the twelfth security pass).
chmod 1777 "$MNT/library"
for shelf in music movies tv audiobooks ebooks documents pictures; do
	[ -L "$MNT/library/$shelf" ] && rm -f "$MNT/library/$shelf"
	mkdir -p "$MNT/library/$shelf"
	chmod 0777 "$MNT/library/$shelf"
done

# Every folder compose.box.yml binds a volume to.
sed -n 's|.*device: \(/srv/soundstorm/[a-z]*/[a-z0-9-]*\).*|\1|p' /opt/soundstorm/compose.box.yml |
	while read -r dir; do mkdir -p "$dir"; done

# The models built into the box (box/models.sh), each laid into its cache
# folder when that is empty: on first boot, and after Start over empties the
# caches - so photo search, Make an ebook and read-along syncing work with no
# internet. The archives stay, for next time.
for tar in /var/lib/soundstorm-models/*.tar; do
	[ -f "$tar" ] || continue
	dest="$MNT/cache/$(basename "$tar" .tar)"
	mkdir -p "$dest"
	if [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then
		if tar --numeric-owner -xf "$tar" -C "$dest"; then
			log "models: $(basename "$tar" .tar) laid in"
		else
			log "models: could not lay in $(basename "$tar" .tar)"
		fi
	fi
done

# SoundStorm runs as uid 10001 and must own its state; the backends' own
# images fix their folders' ownership themselves when they start.
state="$MNT/volumes/soundstorm-state"
[ "$(stat -c %u "$state")" = 10001 ] || chown 10001:10001 "$state"
