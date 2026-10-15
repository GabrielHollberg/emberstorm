#!/bin/sh
# Boots box/out/soundstorm-box.qcow2 as a pretend box: UEFI, the image as the
# system disk, and a blank second disk as the data drive - the ME Mini's
# eMMC and NVMe drive. Run as root where box/build.sh ran:
#
#   wsl -d Debian -u root -- sh box/run-vm.sh          start it
#   wsl -d Debian -u root -- sh box/run-vm.sh stop     stop it
#   wsl -d Debian -u root -- sh box/run-vm.sh fresh    start over, both disks blank
#   wsl -d Debian -u root -- sh box/run-vm.sh installer
#        start from the USB stick (box/installer.sh, made with
#        INSTALL_TARGET=vda) onto a blank built-in drive, as a real box gets
#        its system; it switches itself off when done, and a plain start
#        then boots what it wrote
#   wsl -d Debian -u root -- sh box/run-vm.sh repair
#        the same, onto the drives as they are: putting a box right
#
# SoundStorm answers at http://localhost:8399, SSH (a DEV_SSH build) at
# localhost port 2222, and the console is written to box/out/vm/console.log.
#
# The box has a USB controller, as the ME Mini does, and QEMU's monitor
# listens on box/out/vm/monitor.sock - which is how a USB drive is plugged in
# and pulled out, and the power button pressed:
#
#   echo 'drive_add 0 if=none,id=usb1,file=/root/usb.img,format=raw' | socat - UNIX:monitor.sock
#   echo 'device_add usb-storage,bus=xhci.0,drive=usb1,id=stick1' | socat - UNIX:monitor.sock
#   echo 'device_del stick1' | socat - UNIX:monitor.sock
#   echo 'system_powerdown' | socat - UNIX:monitor.sock     (the power button)
#
# A VM made before the controller was added may stop at the UEFI shell, its
# boot entry pointing at the old layout: delete box/out/vm/vars.fd.
#
# OFFLINE=1 cuts the VM off from the internet (the forwarded ports still
# work): a box built with its images must start with no downloads at all.
#
# NVME_SYSTEM=1 makes the system disk a 256 GB NVMe drive, as on the boxes
# without an eMMC (a small system SSD beside the library drive), for a stick
# made without INSTALL_TARGET, which chooses the drive itself.
#
# ONE_DRIVE=1 gives the box one drive only, a 1 TB NVMe holding both the
# system and the library, as a one-drive box has (a stick made without
# INSTALL_TARGET splits it).
#
# MEM is the VM's memory in MB. The VM shares this PC's memory with the live
# server's containers, so it is kept small by default.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/out}"
vm="$out/vm"
mkdir -p "$vm"
MEM=${MEM:-4608}
sysize=64G
sysdev="virtio-blk-pci,drive=system,bootindex=1"
if [ "${NVME_SYSTEM:-}" = 1 ]; then
	sysize=256G
	sysdev="nvme,drive=system,serial=SYSTEM0001,bootindex=1"
fi
datadev="-drive file=$vm/data.qcow2,if=none,id=data,format=qcow2 -device nvme,drive=data,serial=SSDATA0001"
if [ "${ONE_DRIVE:-}" = 1 ]; then
	sysize=1T
	sysdev="nvme,drive=system,serial=ONEDRIVE0001,bootindex=1"
	datadev=""
fi
restrict=""
[ "${OFFLINE:-}" = 1 ] && restrict=",restrict=on"

stop() {
	if [ -f "$vm/qemu.pid" ] && kill -0 "$(cat "$vm/qemu.pid")" 2>/dev/null; then
		kill "$(cat "$vm/qemu.pid")"
		echo "Stopped."
	fi
	rm -f "$vm/qemu.pid"
}

stick=""
case "${1:-}" in
stop) stop; exit 0 ;;
fresh) stop; rm -f "$vm/system.qcow2" "$vm/data.qcow2" "$vm/vars.fd" ;;
installer | repair)
	stop
	[ -f "$out/emberstorm-installer.img" ] || { echo "Make the stick first: box/installer.sh" >&2; exit 1; }
	if [ "$1" = installer ]; then
		rm -f "$vm/system.qcow2" "$vm/vars.fd"
		qemu-img create -q -f qcow2 "$vm/system.qcow2" "$sysize"
	fi
	# The stick is not changed by a run (snapshot): it can be used again.
	# KEEP_STICK=1 keeps what the run writes to it, as a real stick would -
	# a factory stick's list of the boxes it made (its EMBERSTORM partition).
	snap=on
	[ "${KEEP_STICK:-}" = 1 ] && snap=off
	stick="-drive file=$out/emberstorm-installer.img,if=none,id=stick,format=raw,snapshot=$snap -device usb-storage,bus=xhci.0,drive=stick,bootindex=0"
	;;
esac

[ -f "$out/soundstorm-box.qcow2" ] || { echo "Build it first: box/build.sh" >&2; exit 1; }
if [ -f "$vm/qemu.pid" ] && kill -0 "$(cat "$vm/qemu.pid")" 2>/dev/null; then
	echo "Already running."; exit 0
fi

# The system disk is a layer over the built image, so the image stays as
# built; 64G like the ME Mini's eMMC (it only takes what is written).
[ -f "$vm/system.qcow2" ] ||
	qemu-img create -q -f qcow2 -b "$out/soundstorm-box.qcow2" -F qcow2 "$vm/system.qcow2" "$sysize"
[ -z "$datadev" ] || [ -f "$vm/data.qcow2" ] || qemu-img create -q -f qcow2 "$vm/data.qcow2" 1T
[ -f "$vm/vars.fd" ] || cp /usr/share/OVMF/OVMF_VARS_4M.fd "$vm/vars.fd"

qemu-system-x86_64 \
	-name soundstorm-box \
	-machine q35,accel=kvm -cpu host -smp 4 -m "$MEM" \
	-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
	-drive if=pflash,format=raw,file="$vm/vars.fd" \
	-drive file="$vm/system.qcow2",if=none,id=system,format=qcow2 \
	-device "$sysdev" \
	$datadev \
	-nic user,model=virtio-net-pci$restrict,hostfwd=tcp::8399-:8099,hostfwd=tcp::2222-:22 \
	-display none -serial file:"$vm/console.log" \
	-monitor unix:"$vm/monitor.sock",server,nowait \
	-device qemu-xhci,id=xhci \
	$stick \
	-daemonize -pidfile "$vm/qemu.pid"
echo "Started. Console: box/out/vm/console.log  SoundStorm: http://localhost:8399"
