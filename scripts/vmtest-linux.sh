#!/bin/sh
# Fresh-machine test of the Linux install, one distro at a time, in WSL with KVM:
# a throwaway VM from a cloud image, a normal user with sudo, the website's
# one command, then the checks and the uninstall. Usage: vmtest-linux.sh ubuntu|fedora|mint
set -u
d=$1
base=/root/linuxtest
img=$base/img/ubuntu.img
case $d in fedora) img=$base/img/fedora.qcow2 ;; arch) img=$base/img/arch.qcow2 ;; esac
run=$base/run-$d
rm -rf "$run"; mkdir -p "$run/seed"
log=$base/$d.log
: >"$log"
say() { echo "== $(date +%H:%M:%S) $*" | tee -a "$log"; }

[ -f $base/key ] || ssh-keygen -q -t ed25519 -N '' -f $base/key
fmt=$(qemu-img info "$img" | awk -F': ' '/^file format/{print $2}')
qemu-img create -q -f qcow2 -b "$img" -F "$fmt" "$run/disk.qcow2" 80G

mint=''
[ "$d" = mint ] && mint='
  - sed -i "s/^ID=.*/ID=linuxmint/; s/^NAME=.*/NAME=\"Linux Mint\"/; s/^PRETTY_NAME=.*/PRETTY_NAME=\"Linux Mint 22.1\"/; s/^ID_LIKE=.*/ID_LIKE=\"ubuntu debian\"/" /usr/lib/os-release'
cat >"$run/seed/user-data" <<EOF
#cloud-config
users:
  - name: tester
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys: ["$(cat $base/key.pub)"]
runcmd:
  - touch /tmp/ready$mint
EOF
echo "instance-id: $d-$(date +%s)" >"$run/seed/meta-data"
( cd "$run/seed" && exec python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 ) &
web=$!

qemu-system-x86_64 -enable-kvm -cpu host -m 7168 -smp 4 \
	-drive file="$run/disk.qcow2",if=virtio \
	-nic user,hostfwd=tcp:127.0.0.1:2222-:22 \
	-smbios "type=1,serial=ds=nocloud;s=http://10.0.2.2:8765/" \
	-display none -daemonize -pidfile "$run/qemu.pid"
s="ssh -q -i $base/key -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 tester@127.0.0.1"

say "booting $d"
i=0
until $s test -e /tmp/ready 2>/dev/null; do i=$((i+1)); [ $i -gt 120 ] && { say "FAIL: never came up"; kill $(cat $run/qemu.pid) $web; exit 1; }; sleep 5; done
kill $web
say "up: $($s 'grep PRETTY /etc/os-release')"

# LOCAL=1: this checkout's install.sh rather than main's. STOP_AFTER=N: a first
# run cut off after N seconds (the download), then the real one.
if [ -n "${LOCAL:-}" ]; then
	$s 'cat >install.sh' </mnt/h/dev/soundstorm/install.sh
	cmd='sh install.sh'
else
	cmd='curl -fsSL https://raw.githubusercontent.com/GabrielHollberg/emberstorm/main/install.sh | sh'
fi
if [ -n "${STOP_AFTER:-}" ]; then
	say "a first run, stopped after ${STOP_AFTER}s"
	$s "timeout -s INT $STOP_AFTER $cmd" >>"$log" 2>&1
	$s 'ls ~/soundstorm; cat ~/soundstorm/.env' >>"$log" 2>&1
fi
say "installing (no terminal)"
start=$(date +%s)
$s "$cmd" >>"$log" 2>&1
rc=$?
say "installer exit $rc after $(( ($(date +%s)-start)/60 )) min"

say "checks"
$s 'sleep 60; curl -s localhost:8099/healthz; echo; curl -s localhost:8099/ | grep -o "<title>[^<]*" | head -1;
	echo containers running: $(sudo docker ps -q | wc -l);
	ls ~/soundstorm; grep -E "^SOUNDSTORM_(INSTALLED|SETUP_CODE|WAS_[A-Z_]+|DOCKER_INSTALLED|HOST|AUTO_UPDATE|RELEASE_SERIAL)=" ~/soundstorm/.env;
	crontab -l 2>/dev/null | grep -c emberstorm-update; ls -ld ~/soundstorm/library' >>"$log" 2>&1
tail -20 "$log" | sed 's/^/   /'

say "uninstalling (defaults)"
$s 'touch ~/soundstorm/library/music/marker.txt; sh ~/soundstorm/emberstorm-uninstall.sh' >>"$log" 2>&1
$s 'echo soundstorm containers left: $(sudo docker ps -aq --filter label=com.docker.compose.project=soundstorm | wc -l);
	echo images left: $(sudo docker images -q | wc -l); ls ~/soundstorm; ls ~/soundstorm/library/music/marker.txt;
	crontab -l 2>/dev/null | grep -c emberstorm' >>"$log" 2>&1
tail -8 "$log" | sed 's/^/   /'

kill "$(cat $run/qemu.pid)"; sleep 3; rm -rf "$run"
say "done $d"
