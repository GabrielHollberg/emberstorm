#!/bin/sh
# Runs when the box starts from the EmberStorm USB stick: writes the system
# onto the box's system drive (its eMMC, or the small system SSD), checks every byte, gives the copy
# disk IDs of its own and switches the box off. Made by box/installer.sh.
#
# The storage drive (NVMe) is left as it is - a box being put right keeps
# its accounts and media - unless the stick was made for the factory
# (FACTORY=1 when building it), which wipes it so the box starts new.
#
# A box with one drive (decided with the owner, 2026-10-14) has both on it:
# the system in its first 64 GiB and the library (SSDATA) in a partition of
# its own after it. Putting such a box right rewrites the system's part only
# and puts the library's partition back as it was; its bytes are never
# written.
set -u

P=/opt/emberstorm-install
image="$P/box.raw.zst"
want_sum=$(cat "$P/box.sha256")
size=$(cat "$P/box.size")

clear_screen() { printf '\033[2J\033[H'; }
say() { printf '\n   %s\n' "$*"; }
mode=plain
fail() {
	printf '\n\n   \033[1;31mThe installation did not finish.\033[0m\n'
	say "$*"
	if [ "$mode" = one-repair ]; then
		say "Your library was not erased. Switch the box off, start it from"
	else
		say "Nothing was written to the storage drive. Switch the box off,"
		say "start it from"
	fi
	say "the stick again, and if this happens again, contact support."
	exit 1
}

# Kernel messages over the screen would hide what it says.
dmesg -n 1 2>/dev/null || true
setterm --blank 0 --powersave off 2>/dev/null || true
clear_screen
printf '\n   \033[1mEmberStorm installer\033[0m\n'
udevadm settle 2>/dev/null || true
sleep 3

# The stick itself: the disk this system is running from. Never written.
self=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -n 1)

# The system drive. A box with an eMMC has it as mmcblkN (its boot0, boot1
# and rpmb parts are not disks to write). A box without one (the eMMC model
# was discontinued, 2026-10-12) has the system on a small SSD beside the
# large library drive: the one internal NVMe or SATA disk of 512 GB or less
# that is not the stick and holds no EmberStorm library (SSDATA). Chosen by
# size, not by slot, so it works whichever slot each drive sits in, and a
# library drive is never big-enough-to-mistake: anything over 512 GB is
# never written. INSTALL_TARGET names it outright when the stick is made.
MAX_SYSTEM=512000000000
internal_disk() {
	tran=$(lsblk -dno TRAN "/dev/$1" 2>/dev/null | tr -d ' ')
	rm=$(lsblk -dno RM "/dev/$1" 2>/dev/null | tr -d ' ')
	case "$tran" in nvme | sata | ata) ;; *) return 1 ;; esac
	[ "$rm" = 0 ] || return 1
	case "$(readlink -f "/sys/block/$1" 2>/dev/null)" in */usb* | */thunderbolt* | "") return 1 ;; esac
	return 0
}
holds_library() { lsblk -lno LABEL "/dev/$1" 2>/dev/null | grep -qx SSDATA; }
part() { case "$1" in *[0-9]) echo "/dev/${1}p$2" ;; *) echo "/dev/$1$2" ;; esac; }
blank_disk() {
	[ "$(lsblk -no NAME "/dev/$1" | wc -l)" -eq 1 ] || return 1
	[ -z "$(blkid -p -o value -s TYPE "/dev/$1" 2>/dev/null)" ] || return 1
	[ -z "$(blkid -p -o value -s PTTYPE "/dev/$1" 2>/dev/null)" ] || return 1
}
holds_emberstorm() {
	root=$(part "$1" 1)
	[ -b "$root" ] || return 1
	mkdir -p /run/emberstorm-old
	mount -o ro "$root" /run/emberstorm-old 2>/dev/null || return 1
	ok=1
	[ -d /run/emberstorm-old/usr/local/lib/soundstorm ] && ok=0
	umount /run/emberstorm-old
	return $ok
}
# One drive: the system's part of it, and the smallest drive split so (a
# lone drive smaller holds the system alone, as a system drive does).
SYSTEM_PART=$((64 * 1024 * 1024 * 1024))
MIN_ONE_DRIVE=$((128 * 1024 * 1024 * 1024))
# The library's partition on a one-drive box - lib_num, lib_first and
# lib_last in sectors, lib_type, lib_guid, and lib_uuid of its filesystem -
# from the drive's table, else (its entry lost, say by a repair cut short
# after the write) found by its filesystem where a one-drive box always puts
# it: from the end of the system's part to the drive's end.
lib_num="" lib_first="" lib_last="" lib_type=8300 lib_guid="" lib_uuid=""
find_library() {
	lp=$(lsblk -lnpo NAME,LABEL "/dev/$1" | awk '$2 == "SSDATA" { print $1; exit }')
	if [ -n "$lp" ] && [ "$lp" != "/dev/$1" ]; then
		lib_num=$(cat "/sys/class/block/${lp##*/}/partition")
		info=$(sgdisk -i "$lib_num" "/dev/$1")
		lib_first=$(printf '%s\n' "$info" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
		lib_last=$(printf '%s\n' "$info" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')
		lib_type=$(printf '%s\n' "$info" | sed -n 's/^Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p')
		lib_guid=$(printf '%s\n' "$info" | sed -n 's/^Partition unique GUID: \([0-9A-Fa-f-]*\).*/\1/p')
		lib_uuid=$(blkid -p -o value -s UUID "$lp")
	elif [ "$(blkid -p -O "$SYSTEM_PART" -o value -s LABEL "/dev/$1" 2>/dev/null)" = SSDATA ]; then
		lib_num=2 lib_first=$((SYSTEM_PART / 512)) lib_last=0
		lib_uuid=$(blkid -p -O "$SYSTEM_PART" -o value -s UUID "/dev/$1")
	fi
	[ -n "$lib_first" ] && [ -n "$lib_last" ] && [ -n "$lib_uuid" ]
}
target=""
if [ -s "$P/target" ]; then
	target=$(cat "$P/target")
else
	found=$(lsblk -dno NAME | grep -E '^mmcblk[0-9]+$' | grep -vx "${self:-none}")
	disks=""
	for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk" {print $1}'); do
		[ "$d" = "${self:-}" ] && continue
		internal_disk "$d" && disks="$disks $d"
	done
	set -- $disks
	if [ "$(printf '%s
' "$found" | grep -c .)" = 1 ]; then
		target=$found
	elif [ "$#" = 1 ]; then
		# The box's only drive. A library alone on it (a two-drive box's
		# library drive, its system drive gone) is never written; EmberStorm
		# with its library beside it is put right as a one-drive box; a
		# system drive alone (a two-drive box's, its library drive out) as
		# before; a blank drive, or any on a factory stick, is split in two.
		target=$1
		[ -e "$P/factory" ] || [ "$(blkid -p -o value -s LABEL "/dev/$1" 2>/dev/null)" != SSDATA ] ||
			fail "Only the library drive was found ($1). Put the box's system drive back in (or a new one, 512 GB or less), then start it from the stick again. The library drive was left alone."
		if [ -e "$P/factory" ] || blank_disk "$1"; then
			[ "$(blockdev --getsize64 "/dev/$1")" -lt "$MIN_ONE_DRIVE" ] || mode=one-new
		elif find_library "$1"; then
			holds_emberstorm "$1" ||
				fail "The drive found ($1) holds an EmberStorm library but no EmberStorm system, so it was left alone. Contact support."
			mode=one-repair
		fi
	else
		small=""
		for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk" {print $1}'); do
			[ "$d" = "${self:-}" ] && continue
			internal_disk "$d" || continue
			holds_library "$d" && continue
			[ "$(blockdev --getsize64 "/dev/$d")" -le "$MAX_SYSTEM" ] || continue
			small="$small $d"
		done
		set -- $small
		[ "$#" -le 1 ] || fail "More than one small drive was found ($*). Leave only the system drive (512 GB or less) and the library drive in the box, then start it from the stick again."
		target=${1:-}
		[ -n "$target" ] || fail "No system drive was found. EmberStorm goes on a small SSD (512 GB or less) in the box's system slot; the large drive is kept for the library."
	fi
fi
[ "$mode" != one-new ] || { lib_num=2 lib_first=$((SYSTEM_PART / 512)) lib_last=0; }
[ -n "$target" ] && [ -b "/dev/$target" ] ||
	fail "This box's system drive was not found."
[ "$target" != "$self" ] || fail "The system drive is the stick itself."
have=$(blockdev --getsize64 "/dev/$target")
[ "$have" -ge "$size" ] ||
	fail "The system drive is too small: $((have / 1000000000)) GB, $((size / 1000000000 + 1)) GB needed."
# A stick for putting a box right writes only over EmberStorm or a blank
# drive (a new system SSD after the old one failed): plugged into some other
# computer, it must not take that computer's own drive for a system drive.
# A factory stick sets up new hardware, whatever its drives came with.
if [ "$mode" = plain ] && [ ! -e "$P/factory" ] && [ ! -s "$P/target" ]; then
	blank_disk "$target" || holds_emberstorm "$target" ||
		fail "The drive found ($target, $((have / 1000000000)) GB) holds something other than EmberStorm, so it was left alone. This stick only puts an EmberStorm box right."
fi
# On one drive the system ends before the library starts: the write below
# never reaches the library's bytes.
if [ "$mode" != plain ]; then
	[ "$size" -le "$((lib_first * 512))" ] ||
		fail "EmberStorm's system no longer fits before the library on this drive. Contact support."
fi
repairing=no
if [ ! -e "$P/factory" ] && holds_emberstorm "$target"; then repairing=yes; fi

# A factory stick's record of each box it sets up, for its sticker and for
# support later: the serial and setup code, and what identifies the hardware
# (the maker's serial number, the network port's address, the drives). Kept
# on the stick's EMBERSTORM partition, which Windows opens as a drive, to be
# added to the ledger (box/units-add.sh).
UNITS_HEADER="unit,setup_code,made,stick,product,product_serial,mac,builtin_gb,storage"
field() { printf '%s' "$1" | tr -d ',\r\n' | tr -s ' ' | sed 's/^ //; s/ $//'; }
dmi() { cat "/sys/class/dmi/id/$1" 2>/dev/null || true; }
unit_record() {
	mac=""
	for i in /sys/class/net/*; do
		[ -e "$i/device" ] || continue
		case "${i##*/}" in en* | eth*) mac=$(cat "$i/address"); break ;; esac
	done
	storage=""
	[ "$mode" = plain ] || storage="one drive: system and library"
	for d in $(lsblk -dno NAME,TYPE,TRAN | awk '$2=="disk" && ($3=="nvme" || $3=="sata" || $3=="ata") {print $1}'); do
		[ "$d" = "$self" ] || [ "$d" = "$target" ] && continue
		storage="$storage${storage:+; }$(lsblk -dno MODEL "/dev/$d" | tr -s ' ') $(($(blockdev --getsize64 "/dev/$d") / 1000000000))GB"
	done
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$(field "$(findmnt -no UUID / | cut -c1-8)")" \
		"$(field "$(dmi sys_vendor) $(dmi product_name)")" "$(field "$(dmi product_serial)")" \
		"$(field "$mac")" "$((have / 1000000000))" "$(field "$storage")"
}
# keep_record LINE: added to units.csv on the stick's EMBERSTORM partition.
keep_record() {
	dev=$(lsblk -lnpo NAME,LABEL "/dev/$self" 2>/dev/null | awk '$2 == "EMBERSTORM" { print $1; exit }')
	[ -n "$dev" ] || { say "The stick has no EMBERSTORM partition to keep the record on."; return 1; }
	mkdir -p /run/emberstorm-records
	mount -t vfat "$dev" /run/emberstorm-records || return 1
	[ -f /run/emberstorm-records/units.csv ] || printf '%s\r\n' "$UNITS_HEADER" >/run/emberstorm-records/units.csv
	printf '%s\r\n' "$1" >>/run/emberstorm-records/units.csv
	sync
	umount /run/emberstorm-records
}

case "$mode" in
one-new)
	say "This erases the box's drive ($((have / 1000000000)) GB) and installs EmberStorm"
	say "on it: the system in its first 64 GB, the library in the rest."
	;;
one-repair)
	say "This writes EmberStorm's system again, in the first 64 GB of the"
	say "box's drive. Media, accounts and settings, in the rest of the drive,"
	say "are kept."
	;;
*)
	say "This erases the box's system drive ($((have / 1000000000)) GB) and installs"
	say "EmberStorm on it."
	if [ -e "$P/factory" ]; then
		say "This stick is for the factory: the storage drive is wiped too."
	else
		say "Media, accounts and settings on the storage drive are kept."
	fi
	;;
esac
# Putting a box right keeps its library, but a copy elsewhere means nothing
# can be lost whatever happens (the owner's asking, 2026-10-14).
if [ "$repairing" = yes ]; then
	printf '\n   \033[1;33mBefore you go on:\033[0m copy your library to another drive and\n'
	say "unplug that drive. This is made to keep your library, but with a"
	say "copy nothing can be lost."
fi
# A stick for putting a box right waits for somebody to say yes: plugged
# into the wrong computer it would wipe that computer's system drive (the
# box's blind security review). A factory stick, or one made for testing
# (INSTALL_AUTO), carries on by itself after 20 seconds.
if [ -e "$P/factory" ] || [ -e "$P/auto" ]; then
	say "To stop, switch the box off now. Starting in 20 seconds."
	sleep 20
else
	say "To install, press Enter. To stop, switch the box off."
	while :; do
		IFS= read -r answer || { sleep 5; continue; }
		[ -z "$answer" ] && break
	done
fi

clear_screen
printf '\n   \033[1mInstalling EmberStorm\033[0m - about ten minutes. Leave the box on.\n\n'
# Written straight to the drive, every block, then flushed. A failure on
# either side of the pipe is noted, as its status would be lost.
rm -f /tmp/write-failed /tmp/dd.log
(zstd -dc "$image" || echo zstd >> /tmp/write-failed) |
	(dd of="/dev/$target" bs=4M iflag=fullblock oflag=direct status=progress 2>/tmp/dd.log ||
		echo dd >> /tmp/write-failed) &
writer=$!
while kill -0 "$writer" 2>/dev/null; do
	written=$(tr '\r' '\n' < /tmp/dd.log 2>/dev/null | grep copied | tail -n 1 | cut -d' ' -f1)
	[ -n "$written" ] && printf '\r   %s%% written   ' "$((written * 100 / size))"
	sleep 2
done
wait "$writer"
[ ! -s /tmp/write-failed ] || fail "Writing to the system drive failed."
sync
printf '\r   100%% written   \n'

say "Checking what was written..."
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
got_sum=$(head -c "$size" "/dev/$target" | sha256sum | cut -d' ' -f1)
[ "$got_sum" = "$want_sum" ] ||
	fail "What was written to the system drive does not match. The drive may be failing."

say "Finishing..."
# The partition table as written, read again before its parts are opened.
blockdev --rereadpt "/dev/$target" 2>/dev/null || partprobe "/dev/$target" 2>/dev/null || true
udevadm settle 2>/dev/null || true
# The old disk IDs, then new ones: every box made from this stick - and the
# stick itself - would otherwise share them, and a box started with the
# stick still in could start the stick's system instead of its own.
old_root=$(blkid -c /dev/null -s PARTUUID -o value "$(part "$target" 1)")
old_efi=$(blkid -c /dev/null -s PARTUUID -o value "$(part "$target" 15)")
old_fs=$(blkid -c /dev/null -s UUID -o value "$(part "$target" 1)")
# -e moves the second copy of the partition table to the drive's end (the
# image is smaller than the drive); -G gives the disk and partitions new IDs.
sgdisk -e -G "/dev/$target" >/dev/null || fail "The system drive's partitions could not be set up."
# One drive: the library's partition, back where it was (the table just
# written holds only the system's) or made new. Nothing is written inside
# it, but for a new filesystem on a new one.
if [ "$mode" != plain ]; then
	sgdisk -n "$lib_num:$lib_first:$lib_last" -t "$lib_num:$lib_type" -c "$lib_num:SSDATA" \
		${lib_guid:+-u "$lib_num:$lib_guid"} "/dev/$target" >/dev/null ||
		fail "The library's partition could not be put back. It was not erased: do not use the box, and contact support."
fi
blockdev --rereadpt "/dev/$target" 2>/dev/null || partprobe "/dev/$target" 2>/dev/null || true
udevadm settle 2>/dev/null || true
if [ "$mode" = one-new ]; then
	mkfs.btrfs -q -f -K -L SSDATA "$(part "$target" "$lib_num")" ||
		fail "The library's part of the drive could not be prepared."
elif [ "$mode" = one-repair ]; then
	[ "$(blkid -c /dev/null -p -o value -s UUID "$(part "$target" "$lib_num")")" = "$lib_uuid" ] ||
		fail "The library's partition was put back, but what is in it could not be found. Nothing in it was erased: do not use the box, and contact support."
fi
e2fsck -fy "$(part "$target" 1)" >/dev/null 2>&1
tune2fs -U random "$(part "$target" 1)" >/dev/null || fail "The system drive's system could not be given its own ID."
new_root=$(blkid -c /dev/null -s PARTUUID -o value "$(part "$target" 1)")
new_efi=$(blkid -c /dev/null -s PARTUUID -o value "$(part "$target" 15)")
new_fs=$(blkid -c /dev/null -s UUID -o value "$(part "$target" 1)")
[ -n "$old_root" ] && [ -n "$new_root" ] && [ -n "$old_fs" ] && [ -n "$new_fs" ] ||
	fail "The system drive's IDs could not be read."

mkdir -p /mnt/box
mount "$(part "$target" 1)" /mnt/box || fail "The installed system could not be opened."
mount "$(part "$target" 15)" /mnt/box/boot/efi || { umount /mnt/box; fail "The installed system's start-up files could not be opened."; }
for f in /mnt/box/etc/fstab /mnt/box/boot/grub/grub.cfg /mnt/box/boot/efi/EFI/debian/grub.cfg; do
	[ -f "$f" ] || continue
	sed -i -e "s/$old_root/$new_root/g" -e "s/$old_fs/$new_fs/g" ${old_efi:+-e "s/$old_efi/$new_efi/g"} "$f"
done
grep -q "$new_root" /mnt/box/etc/fstab && grep -q "$new_fs" /mnt/box/boot/efi/EFI/debian/grub.cfg
ok=$?

# A factory stick gives the box its identity - its setup code and serial,
# for its sticker - which the box keeps on its storage drive from its first
# start (prepare.sh), so a repair later keeps them. Shown at the end, and
# kept on the stick (units.csv) for the stickers to be printed from.
unit="" code="" kept=yes
if [ "$ok" = 0 ] && [ -e "$P/factory" ]; then
	code=$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')
	unit=$(od -An -N8 -tu1 /dev/urandom | awk '{ for (i = 1; i <= NF; i++) s = s substr("0123456789ABCDEFGHJKMNPQRSTVWXYZ", $i % 32 + 1, 1) }
		END { printf "EM-%s-%s", substr(s, 1, 4), substr(s, 5, 4) }')
	mkdir -p /mnt/box/etc/soundstorm
	(umask 077 && printf 'SOUNDSTORM_SETUP_CODE=%s\nSOUNDSTORM_UNIT=%s\n' "$code" "$unit" >/mnt/box/etc/soundstorm/identity.env) || ok=1
	# Its first start is its test, at the factory: once every part of
	# EmberStorm runs, the caretaker makes it new and switches it off
	# (caretaker factory.go), so the buyer's first start is a minute or two.
	: >/mnt/box/etc/soundstorm/factory-test || ok=1
	record=$(unit_record "$unit" "$code")
	[ -f "$P/units.csv" ] || echo "$UNITS_HEADER" >"$P/units.csv"
	echo "$record" >>"$P/units.csv"
	keep_record "$record" || kept=no
	sync
fi
umount /mnt/box/boot/efi /mnt/box
[ "$ok" = 0 ] || fail "The installed system could not be told its new IDs."
# Without the record nobody could print this box's label again or help its
# buyer find the code: stop, and the box is simply set up again.
[ "$kept" = yes ] || fail "This box's record could not be kept on the stick (its EMBERSTORM drive)."

# The box starts from its system drive first. The firmware also finds it
# by itself (EFI/BOOT), so a failure here is not fatal.
# One entry: those left by earlier installs go first, as some firmware has
# little room for them.
for n in $(efibootmgr 2>/dev/null | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\} EmberStorm.*/\1/p'); do
	efibootmgr -q -b "$n" -B 2>/dev/null || true
done
efibootmgr -q -c -d "/dev/$target" -p 15 -L EmberStorm -l '\EFI\debian\shimx64.efi' 2>/dev/null || true

if [ -e "$P/factory" ]; then
	# Every internal storage drive, NVMe or SATA; never the system drive
	# just written or the stick; disks only (a CD drive is on SATA too).
	for d in $(lsblk -dno NAME,TYPE,TRAN | awk '$2=="disk" && ($3=="nvme" || $3=="sata" || $3=="ata") {print $1}'); do
		[ "$d" = "$self" ] || [ "$d" = "$target" ] && continue
		say "Wiping the storage drive ($d)..."
		wipefs -a -f "/dev/$d" >/dev/null || fail "The storage drive could not be wiped."
	done
fi

clear_screen
printf '\n   \033[1;32mEmberStorm is installed.\033[0m\n'
if [ -n "$unit" ]; then
	# What goes on the sticker (box/sticker.sh makes it from units.csv).
	say "Serial:      $unit"
	say "Setup code:  $(printf '%s' "$code" | sed 's/..../& /g')"
	qrencode -t UTF8 -m 1 "http://$(printf '%s' "$unit" | tr 'A-Z' 'a-z').local/?setup=$code" 2>/dev/null | sed 's/^/   /'
	say "Kept on the stick's EMBERSTORM drive (units.csv)."
	# The BIOS path is the maker's own (their answer, 2026-10-12): State After
	# G3 is the setting that makes a box start when it is plugged in.
	say "Next: take the stick out, switch the box on and press Delete as it"
	say "starts. Go to Chipset > PCH-IO Configuration > State After G3 and"
	say "set it to S0 State (it then starts when power comes back). Press F4"
	say "to save and start."
	say "It tests itself - about half an hour - and switches off when it"
	say "passes. Then it is ready to pack. Switching off in 2 minutes."
	sync
	sleep 120
else
	say "Take the USB stick out. The box switches itself off in 30 seconds;"
	say "switch it on again and it starts EmberStorm."
	sync
	sleep 30
fi
systemctl poweroff
