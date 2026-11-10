#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# void-min: a small, fast Void Linux on one disk, installed from the Void live ISO (base, x86_64,
# glibc, booted in UEFI mode). One user, one runlevel, no encryption: a kernel, Wi-Fi, a terminal
# and mango, and nothing running that was not asked for. kombain's install.sh goes on top as is.
#
#   sh install.sh [--disk DEV] [--user NAME] [--host NAME] [--timezone AREA/CITY]
#                 [--mirror URL] [--serial] [--dry-run]
#
#   --disk DEV       the disk to erase and install on (asked when left out)
#   --user NAME      the user, in wheel, audio and video (default Bivel)
#   --host NAME      the machine's name (default void)
#   --timezone TZ    as under /usr/share/zoneinfo (asked when left out; Enter is UTC)
#   --mirror URL     a Void mirror, now and for updates (default https://repo-de.voidlinux.org)
#   --serial         also a console and a login on the first serial port
#   --dry-run        ask the same, print the commands, change nothing
#
# Nothing is changed until you type the disk's name. The questions are plain ASCII: the live
# ISO's console has no Cyrillic font. Passwords go straight to passwd: this script never sees them.
set -eu

DEFAULT_MIRROR=https://repo-de.voidlinux.org
BOOT_MIB=1024
MIN_DISK_MIB=12288

disk='' suffix='' user=Bivel host=void timezone='' mirror=$DEFAULT_MIRROR serial=0 dry_run=0
wired='' nvidia='' wifi_ssid='' wifi_key='' wifi_value=''
root_uuid=ROOT-UUID efi_uuid=EFI-UUID

# Where the hardware is read from: the tests point these at a made-up machine.
pci=${VOIDMIN_PCI:-/sys/bus/pci/devices}
net=${VOIDMIN_NET:-/sys/class/net}
cpuinfo=${VOIDMIN_CPUINFO:-/proc/cpuinfo}
wpa_conf=${VOIDMIN_WPA:-/etc/wpa_supplicant/wpa_supplicant.conf}

die() {
	echo "install.sh: $*" >&2
	exit 1
}

# Everything typed goes through here: without a terminal, asking again would never end.
ask() {
	printf '%s' "$1" >&2
	IFS= read -r answer || die "no more input"
	printf '%s\n' "$answer"
}

# ---------------------------------------------------------------- what the answers may be

# A disk's partitions are diskp1 if its name ends in a digit (nvme0n1p1, mmcblk0p1), else disk1 (sda1).
part_suffix() {
	case $1 in
	*[0-9]) echo p ;;
	*) echo "" ;;
	esac
}

valid_user() {
	case $1 in
	root | nobody | '') return 1 ;;
	esac
	printf '%s\n' "$1" | grep -Eq '^[A-Za-z_][A-Za-z0-9_-]{0,31}$'
}

# useradd takes lowercase names as they are. Any other, Bivel among them, needs --badname, and
# is typed at the login prompt exactly as written: names are case sensitive.
plain_user() {
	printf '%s\n' "$1" | grep -Eq '^[a-z_][a-z0-9_-]*$'
}

valid_host() {
	printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$'
}

valid_timezone() {
	printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$' || return 1
	[ ! -d "${VOIDMIN_ZONEINFO:-/usr/share/zoneinfo}" ] || [ -f "${VOIDMIN_ZONEINFO:-/usr/share/zoneinfo}/$1" ]
}

# It goes into commands as it is, so it may hold nothing a shell would read.
valid_mirror() {
	printf '%s\n' "$1" | grep -Eq '^https://[A-Za-z0-9._/-]+$'
}

# ---------------------------------------------------------------- what the machine has

has_vendor() { # PCI vendor of a display adapter
	for dev in "$pci"/*; do
		[ -e "$dev/class" ] || continue
		case $(cat "$dev/class") in 0x03*) ;; *) continue ;; esac
		if [ "$(cat "$dev/vendor")" = "$1" ]; then
			return 0
		fi
	done
	return 1
}

cpu_is() {
	grep -q "$1" "$cpuinfo" 2>/dev/null
}

# NVIDIA's own driver for the newest NVIDIA display adapter here: `nvidia` from Turing on (device
# 0x1e00 and up: GTX 16xx, RTX 20xx and everything after), `nvidia580` for Maxwell, Pascal and
# Volta (0x1340 to 0x1dff). Anything older gets none: Mesa drives it.
nvidia_package() {
	best=
	for dev in "$pci"/*; do
		[ -e "$dev/class" ] || continue
		case $(cat "$dev/class") in 0x03*) ;; *) continue ;; esac
		[ "$(cat "$dev/vendor")" = 0x10de ] || continue
		id=$(($(cat "$dev/device")))
		if [ "$id" -ge $((0x1e00)) ]; then
			best=nvidia
		elif [ "$id" -ge $((0x1340)) ] && [ "$best" != nvidia ]; then
			best=nvidia580
		fi
	done
	echo "$best"
}

gpu_packages() {
	list="mesa-dri vulkan-loader"
	if has_vendor 0x8086; then list="$list mesa-vulkan-intel"; fi
	if has_vendor 0x1002; then list="$list mesa-vulkan-radeon"; fi
	echo "$list"
}

any_device() { # a PCI device of any kind from one of these vendors
	for dev in "$pci"/*; do
		[ -e "$dev/vendor" ] || continue
		v=$(cat "$dev/vendor")
		for want in "$@"; do
			if [ "$v" = "$want" ]; then
				return 0
			fi
		done
	done
	return 1
}

# Firmware for makers this machine has nothing of: no CPU, and no device of any kind on the PCI
# bus. An AMD laptop with an Intel Wi-Fi card keeps Intel's, which its Bluetooth needs too.
firmware_to_drop() {
	drop=
	any_device 0x10de || drop="$drop linux-firmware-nvidia"
	any_device 0x1002 0x1022 || cpu_is AuthenticAMD || drop="$drop linux-firmware-amd"
	any_device 0x8086 || cpu_is GenuineIntel || drop="$drop linux-firmware-intel"
	echo "$drop"
}

# The wired interface that is up right now, if any.
wired_interface() {
	for dev in "$net"/*; do
		[ -e "$dev/device" ] || continue
		[ ! -e "$dev/wireless" ] || continue
		if [ "$(cat "$dev/operstate" 2>/dev/null)" = up ]; then
			basename "$dev"
			return
		fi
	done
}

has_wifi() {
	for dev in "$net"/*; do
		if [ -e "$dev/wireless" ]; then
			return 0
		fi
	done
	return 1
}

# The network the live system joined through wpa_supplicant, for iwd in the installed one: its
# name, and the passphrase where wpa_passphrase left it in a comment, else the key itself.
# With a name, that network; without, the last one in the file.
wifi_from_wpa() { # file [ssid]
	wifi_ssid='' wifi_key='' wifi_value=''
	[ -r "$1" ] || return 0
	found=$(awk -v want="${2:-}" '
		/^[ \t]*network=\{/ { inb = 1; s = ""; k = ""; pl = ""; next }
		inb && /^[ \t]*ssid="/ { s = $0; sub(/^[ \t]*ssid="/, "", s); sub(/"[ \t]*$/, "", s) }
		inb && /^[ \t]*#psk="/ { pl = $0; sub(/^[ \t]*#psk="/, "", pl); sub(/"[ \t]*$/, "", pl) }
		inb && /^[ \t]*psk=/ { k = $0; sub(/^[ \t]*psk=/, "", k); sub(/[ \t]*$/, "", k) }
		/^[ \t]*\}/ {
			if (inb && s != "" && (k != "" || pl != "") && (want == "" || s == want)) { fs = s; fk = k; fp = pl }
			inb = 0
		}
		END { if (fs != "") { print fs; print fp; print fk } }' "$1")
	[ -n "$found" ] || return 0
	plain=$(printf '%s\n' "$found" | sed -n 2p)
	key=$(printf '%s\n' "$found" | sed -n 3p)
	if [ -n "$plain" ]; then
		wifi_key=Passphrase wifi_value=$plain
	elif printf '%s\n' "$key" | grep -Eq '^[0-9a-fA-F]{64}$'; then
		wifi_key=PreSharedKey wifi_value=$key
	else
		case $key in
		'"'?*'"')
			wifi_value=${key#\"}
			wifi_key=Passphrase wifi_value=${wifi_value%\"}
			;;
		*) return 0 ;;
		esac
	fi
	wifi_ssid=$(printf '%s\n' "$found" | sed -n 1p)
}

detect_wifi() {
	now=$(wpa_cli status 2>/dev/null | sed -n 's/^ssid=//p' | head -n 1) || now=
	wifi_from_wpa "$wpa_conf" "$now"
	[ -n "$wifi_ssid" ] || wifi_from_wpa "$wpa_conf"
}

# iwd names a network's file after its SSID, or =hex if the SSID has anything else in it.
iwd_file_name() {
	if printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_ -]+$'; then
		printf '%s.psk' "$1"
	else
		printf '=%s.psk' "$(printf '%s' "$1" | od -An -tx1 | tr -d ' \n')"
	fi
}

# ---------------------------------------------------------------- the disk

# Disks that can be installed on: "name size-in-bytes model". Anything in use is left out, and
# that covers the stick this system runs from.
list_disks() {
	lsblk -dnbp -o NAME,SIZE,TYPE,MODEL | while read -r name bytes type model; do
		[ "$type" = disk ] || continue
		case $name in /dev/zram* | /dev/ram*) continue ;; esac
		[ -z "$(lsblk -nlo MOUNTPOINT "$name" 2>/dev/null | tr -d '[:space:]')" ] || continue
		echo "$name $bytes $model"
	done
}

fmt_gib() {
	awk -v b="$1" 'BEGIN { printf "%.0f GiB", b / 1073741824 }'
}

ask_disk() {
	disks=$(list_disks)
	[ -n "$disks" ] || die "no disk to install on: every disk here is in use"
	count=$(printf '%s\n' "$disks" | wc -l | tr -d ' ')
	echo
	echo "Disks:"
	i=0
	printf '%s\n' "$disks" | while read -r name bytes model; do
		i=$((i + 1))
		echo "  $i) $name  $(fmt_gib "$bytes")  $model"
	done
	default=
	[ "$count" -gt 1 ] || default=1
	while :; do
		n=$(ask "Install on disk number${default:+ [$default]}: ")
		n=${n:-$default}
		case $n in
		'' | *[!0-9]*) n=0 ;;
		esac
		if [ "$n" -ge 1 ] && [ "$n" -le "$count" ]; then
			break
		fi
		echo "That is not on the list." >&2
	done
	line=$(printf '%s\n' "$disks" | sed -n "${n}p")
	disk=${line%% *}
}

check_disk() {
	[ -b "$disk" ] || die "$disk is not a disk"
	[ "$(lsblk -dno TYPE "$disk" 2>/dev/null)" = disk ] || die "$disk is not a whole disk"
	[ -z "$(lsblk -nlo MOUNTPOINT "$disk" 2>/dev/null | tr -d '[:space:]')" ] || die "$disk is in use: something on it is mounted"
	bytes=$(lsblk -dnbo SIZE "$disk")
	[ "$((bytes / 1048576))" -ge "$MIN_DISK_MIB" ] || die "$disk is too small: at least $((MIN_DISK_MIB / 1024)) GiB is needed"
}

confirm_erase() {
	name=${disk##*/}
	echo
	lsblk -o NAME,SIZE,FSTYPE,LABEL "$disk" 2>/dev/null || true
	echo
	echo "EVERYTHING on $disk will be erased. Nothing has been touched so far."
	while :; do
		a=$(ask "Type $name to erase it, or stop to quit: ")
		case $a in
		"$name") return ;;
		stop) die "stopped. Nothing was erased." ;;
		esac
		echo "That is not the disk's name. Nothing was erased." >&2
	done
}

ask_timezone() {
	while :; do
		a=$(ask "Time zone, as Europe/Kyiv [UTC]: ")
		a=${a:-UTC}
		if valid_timezone "$a"; then
			timezone=$a
			return
		fi
		echo "No such zone under /usr/share/zoneinfo." >&2
	done
}

# ---------------------------------------------------------------- the commands

base_packages() {
	echo "base-system zstd limine efibootmgr iwd openresolv dbus elogind chrony zramen snooze run-parts opendoas git void-repo-nonfree mangowc foot dejavu-fonts-ttf $(gpu_packages)"
}

# Quiet and with nothing that wakes the CPU for no reason: no watchdog, no kfence sampling, zram
# instead of zswap. Full preemption, for a desktop and games that answer at once. No lockdown and
# no debugfs=off: NVIDIA's unsigned modules and zcool's view of an MSI EC need both left alone.
# 32-bit programs stay able to run: Steam is one.
kernel_cmdline() {
	c="root=UUID=$root_uuid rootfstype=xfs rw quiet loglevel=3"
	[ "$serial" -eq 0 ] || c="$c console=tty0 console=ttyS0,115200"
	c="$c zswap.enabled=0 nowatchdog kfence.sample_interval=0 preempt=full split_lock_detect=off"
	[ -z "$nvidia" ] || c="$c nvidia_drm.modeset=1"
	echo "$c"
}

step_partition() {
	p=$disk$suffix
	cat <<EOF
printf 'label: gpt\nsize=${BOOT_MIB}M, type=U\ntype=L\n' | sfdisk --wipe always --wipe-partitions always $disk
udevadm settle
mkfs.vfat -F32 -n EFI ${p}1
mkfs.xfs -f -L root ${p}2
mount -o noatime ${p}2 /mnt
mkdir -p /mnt/boot
mount ${p}1 /mnt/boot
EOF
}

step_base() {
	repo=$mirror/current
	cat <<EOF
mkdir -p /mnt/var/db/xbps/keys /mnt/etc/xbps.d
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
printf 'noextract=%s\n' '/usr/share/locale/*' '!/usr/share/locale/ru/*' '!/usr/share/locale/en*' > /mnt/etc/xbps.d/20-noextract.conf
# the ISO's own xbps may be too old for today's packages
xbps-install -Syi -R $repo xbps || true
XBPS_ARCH=x86_64 xbps-install -Sy -r /mnt -R $repo $(base_packages)
printf 'repository=%s\n' $repo > /mnt/etc/xbps.d/00-repository-main.conf
printf 'repository=%s/nonfree\n' $repo > /mnt/etc/xbps.d/10-repository-nonfree.conf
EOF
}

step_system() {
	drop="wpa_supplicant sudo btrfs-progs f2fs-tools"
	# without a cable dhcpcd goes: iwd gets the address for Wi-Fi itself
	[ -n "$wired" ] || drop="$drop dhcpcd"
	drop="$drop$(firmware_to_drop)"
	cat <<EOF
echo $host > /etc/hostname
ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
sed -i -e 's/^#en_US.UTF-8/en_US.UTF-8/' -e 's/^#ru_RU.UTF-8/ru_RU.UTF-8/' /etc/default/libc-locales
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
printf 'ignorepkg=%s\n' $drop > /etc/xbps.d/10-ignore.conf
for p in $drop; do
	if xbps-query "\$p" >/dev/null 2>&1; then xbps-remove -Ry "\$p"; fi
done
echo 'permit :wheel' > /etc/doas.conf
chmod 400 /etc/doas.conf
EOF
}

step_drivers() {
	echo 'xbps-install -Sy'
	if cpu_is GenuineIntel; then echo 'xbps-install -y intel-ucode'; fi
	if [ -n "$nvidia" ]; then echo "xbps-install -y $nvidia"; fi
	# Turing and newer sleep only when the driver is told they may
	if [ "$nvidia" = nvidia ]; then
		echo "echo 'options nvidia NVreg_DynamicPowerManagement=0x02' > /etc/modprobe.d/nvidia-sleep.conf"
	fi
}

step_files() {
	cat <<EOF
cat > /etc/fstab <<'FSTAB'
UUID=$root_uuid  /      xfs    defaults,noatime 0 0
UUID=$efi_uuid  /boot  vfat   defaults,noatime,fmask=0077,dmask=0077 0 2
tmpfs  /tmp  tmpfs  defaults,nosuid,nodev,mode=1777 0 0
FSTAB
EOF
	cat <<'EOF'
# Only this machine's drivers in the initramfs, and none of NVIDIA's: megabytes instead of hundreds.
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/10-local.conf <<'DRACUT'
hostonly="yes"
hostonly_mode="strict"
hostonly_cmdline="no"
omit_drivers+=" nouveau nova_core nova_drm nvidia nvidia_drm nvidia_modeset nvidia_uvm "
compress="zstd"
DRACUT
mkdir -p /etc/iwd
cat > /etc/iwd/main.conf <<'IWD'
[General]
EnableNetworkConfiguration=true

[Network]
NameResolvingService=resolvconf
IWD
grep -q 'ZRAM_COMP_ALGORITHM=zstd' /etc/sv/zramen/conf 2>/dev/null || cat >> /etc/sv/zramen/conf <<'ZRAM'
export ZRAM_COMP_ALGORITHM=zstd
export ZRAM_SIZE=50
export ZRAM_MAX_SIZE=16384
ZRAM
mkdir -p /etc/cron.weekly
printf '#!/bin/sh\nfstrim -a\n' > /etc/cron.weekly/fstrim
# downloaded packages are never needed again, and they add up to gigabytes
printf '#!/bin/sh\nrm -f /var/cache/xbps/*\n' > /etc/cron.weekly/xbps-cache
chmod +x /etc/cron.weekly/fstrim /etc/cron.weekly/xbps-cache
EOF
}

step_boot() {
	cat <<'EOF'
mkdir -p /etc/kernel.d/post-install /etc/kernel.d/post-remove
cat > /etc/kernel.d/post-install/60-limine <<'HOOK'
#!/bin/sh
# Rebuilds limine.conf after every kernel change: one entry a kernel, Void's own newest first.
# A kernel with a dash in its version (kombain's 6.18.62-kombain_1) comes after them, so it is
# never the default. After an update of the limine package, run this by hand.
CMD="VOIDMIN-CMDLINE"
B=${VOIDMIN_BOOT:-/boot}
LIMINE=${VOIDMIN_LIMINE:-/usr/share/limine/BOOTX64.EFI}
all=$(ls -1 $B/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -rV)
kernels="$(echo "$all" | grep -v -- - || true) $(echo "$all" | grep -- - || true)"
{
	printf 'timeout: 1\n\n'
	for v in $kernels; do
		[ -e "$B/initramfs-$v.img" ] || continue
		printf '/Void %s\n    protocol: linux\n    path: boot():/vmlinuz-%s\n    cmdline: %s\n    module_path: boot():/initramfs-%s.img\n\n' "$v" "$v" "$CMD" "$v"
	done
} > $B/limine.conf.tmp || exit 1
# no kernel with an initramfs: what was there stays
grep -q '^/Void ' $B/limine.conf.tmp || { rm -f $B/limine.conf.tmp; exit 0; }
mv $B/limine.conf.tmp $B/limine.conf
mkdir -p $B/EFI/BOOT
cp "$LIMINE" $B/EFI/BOOT/BOOTX64.EFI.new || exit 1
mv $B/EFI/BOOT/BOOTX64.EFI.new $B/EFI/BOOT/BOOTX64.EFI
exit 0
HOOK
chmod +x /etc/kernel.d/post-install/60-limine
ln -sf ../post-install/60-limine /etc/kernel.d/post-remove/60-limine
EOF
	cat <<EOF
sed -i 's|^CMD="VOIDMIN-CMDLINE"\$|CMD="$(kernel_cmdline)"|' /etc/kernel.d/post-install/60-limine
mkdir -p /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/
# the firmware finds \\EFI\\BOOT\\BOOTX64.EFI by itself; an entry of its own puts it first
mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs none /sys/firmware/efi/efivars || true
for n in \$(efibootmgr 2>/dev/null | sed -n 's/^Boot\\([0-9A-Fa-f]\\{4\\}\\)\\*\\{0,1\\} Limine.*/\\1/p'); do
	efibootmgr -q -b "\$n" -B || true
done
efibootmgr -q --create --disk $disk --part 1 --label Limine --loader '\\EFI\\BOOT\\BOOTX64.EFI' || echo 'no boot entry was written: the firmware still starts EFI/BOOT/BOOTX64.EFI'
EOF
}

step_services() {
	services="udevd dbus elogind iwd chronyd zramen snooze-weekly agetty-tty1 agetty-tty2"
	if [ -n "$wired" ]; then
		services="$services dhcpcd-$wired"
		# (dhcpcd-eth0 comes with the system; any other interface gets a copy of it)
		if [ "$wired" != eth0 ]; then
			cat <<EOF
cp -R /etc/sv/dhcpcd-eth0 /etc/sv/dhcpcd-$wired
rm -f /etc/sv/dhcpcd-$wired/supervise /etc/sv/dhcpcd-$wired/log/supervise
sed -i 's/eth0/$wired/g' /etc/sv/dhcpcd-$wired/run
EOF
		fi
	fi
	[ "$serial" -eq 0 ] || services="$services agetty-ttyS0"
	cat <<EOF
for s in $services; do
	ln -sfn "/etc/sv/\$s" /etc/runit/runsvdir/default/
done
EOF
}

step_users() {
	flag=
	plain_user "$user" || flag=' --badname'
	cat <<EOF
useradd$flag -m -G wheel,audio,video $user
chmod 700 /home/$user
echo
echo 'A password for root:'
until passwd; do echo Again:; done
echo
echo 'A password for $user:'
until passwd $user; do echo Again:; done
EOF
}

step_finish() {
	cat <<EOF
xbps-reconfigure -fa
# Spare consoles. Reconfiguring brings their links back, and so can an update: \`down\` keeps them off then.
for n in 3 4 5 6; do
	rm -f "/etc/runit/runsvdir/default/agetty-tty\$n"
	touch "/etc/sv/agetty-tty\$n/down"
done
rm -f /etc/runit/runsvdir/default/sshd
# what must be true before leaving: a wrong file here is a machine that does not boot
ls /boot/vmlinuz-* /boot/initramfs-* /boot/limine.conf /boot/EFI/BOOT/BOOTX64.EFI
grep -q 'root=UUID=$root_uuid ' /boot/limine.conf
grep -q '^/Void ' /boot/limine.conf
id $user
rm -f /var/cache/xbps/*
EOF
}

# ---------------------------------------------------------------- running them

live() { # title, commands
	echo
	echo "==> $1"
	if [ "$dry_run" -eq 1 ]; then
		printf '%s\n' "$2"
		return
	fi
	printf '%s\n' "$2" > /tmp/void-min-step
	sh -eu /tmp/void-min-step
	rm -f /tmp/void-min-step
}

chrooted() { # title, commands
	echo
	echo "==> $1"
	if [ "$dry_run" -eq 1 ]; then
		printf '%s\n' "$2"
		return
	fi
	(umask 077 && printf '%s\n' "$2" > /mnt/tmp/void-min-step)
	chroot /mnt /bin/sh -eu /tmp/void-min-step
	rm -f /mnt/tmp/void-min-step
}

# The new system gets the kernel's file systems, and the live system's name servers for now.
enter_root() {
	mkdir -p /mnt/tmp
	for fs in dev proc sys; do
		mount --rbind "/$fs" "/mnt/$fs"
		mount --make-rslave "/mnt/$fs"
	done
	cp -L /etc/resolv.conf /mnt/etc/resolv.conf
}

# The file iwd would write itself after `iwctl station ... connect`. Only root can read it.
save_wifi() {
	[ -n "$wifi_ssid" ] || return 0
	echo
	echo "==> Wi-Fi: $wifi_ssid is saved for iwd and joined at the first boot"
	[ "$dry_run" -eq 0 ] || return 0
	file=$(iwd_file_name "$wifi_ssid")
	install -d -m 700 /mnt/var/lib/iwd
	(umask 077 && printf '[Security]\n%s=%s\n' "$wifi_key" "$wifi_value" > "/mnt/var/lib/iwd/$file")
}

# ---------------------------------------------------------------- before anything is erased

check_system() {
	[ "$(id -u)" -eq 0 ] || die "run as root"
	[ -d /run/initramfs/live ] || die "run this from the Void live ISO: it erases a whole disk"
	[ -d /sys/firmware/efi ] || die "the machine booted in BIOS mode: enable UEFI and boot the ISO again"
	[ "$(uname -m)" = x86_64 ] || die "this is for x86_64"
	command -v xbps-install >/dev/null || die "no xbps-install here: this is for Void Linux"
	# Known to everyone, so it goes first: the ISO's SSH accepts root with the password voidlinux.
	sv down sshd >/dev/null 2>&1 || true
}

# What an interrupted run leaves behind.
clean_previous() {
	grep -q ' /mnt[ /]' /proc/mounts || return 0
	echo
	echo "An earlier attempt left /mnt mounted."
	a=$(ask "Unmount it and start over? [Y/n]: ")
	case ${a:-y} in
	[yY]*) umount -R /mnt ;;
	*) die "stopped: unmount /mnt yourself" ;;
	esac
}

check_network() {
	name=${mirror#https://}
	name=${name%%/*}
	getent hosts "$name" >/dev/null 2>&1 && return 0
	cat >&2 <<'EOF'
install.sh: no network. With a cable it comes up by itself; for Wi-Fi:

  wpa_passphrase "NETWORK" "PASSWORD" >> /etc/wpa_supplicant/wpa_supplicant.conf
  sv restart wpa_supplicant
  sv restart dhcpcd

and run this again.
EOF
	exit 1
}

show_plan() {
	echo
	echo "Void Linux on $disk: 1 GiB for /boot (EFI), the rest for / (XFS). No encryption, no swap partition."
	echo "User $user, host $host, time zone $timezone. Packages from $mirror."
	echo "Graphics: $(gpu_packages)${nvidia:+, and the driver from NVIDIA itself: $nvidia}."
	if [ -n "$wired" ]; then
		echo "Wired network on $wired stays."
	else
		echo "No cable in use: dhcpcd is left out, iwd gets the address for Wi-Fi."
	fi
	if [ -n "$wifi_ssid" ]; then
		echo "Wi-Fi: $wifi_ssid, as joined here, is saved for the first boot."
	else
		echo "Wi-Fi: nothing to carry over; after the first boot: iwctl station wlan0 connect NAME"
	fi
	if ! plain_user "$user"; then
		echo "The name $user is typed at the login prompt exactly so: names are case sensitive."
	fi
}

finish() {
	if [ "$dry_run" -eq 1 ]; then
		echo
		echo "That was a dry run: nothing was changed."
		return
	fi
	# the installed system writes its own at the first connection
	rm -f /mnt/etc/resolv.conf
	umount -R /mnt
	cat <<EOF

Done. After the reboot, log in as $user on the first console and start the desktop:

  dbus-run-session mango        (Alt+Return opens a terminal, Super+m leaves)

kombain goes on top of this as it is:

  git clone https://github.com/FalconBinary/kombain
  cd kombain && doas ./install.sh --user $user
EOF
	ask "Remove the installation stick and press Enter to reboot: " >/dev/null
	reboot
}

main() {
	while [ $# -gt 0 ]; do
		case $1 in
		--dry-run) dry_run=1 ;;
		--serial) serial=1 ;;
		--disk | --user | --host | --timezone | --mirror)
			[ $# -ge 2 ] || die "$1 needs a value"
			case $1 in
			--disk) disk=$2 ;;
			--user) user=$2 ;;
			--host) host=$2 ;;
			--timezone) timezone=$2 ;;
			--mirror) mirror=${2%/} ;;
			esac
			shift
			;;
		-h | --help)
			sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*) die "unknown option: $1 (see --help)" ;;
		esac
		shift
	done
	valid_user "$user" || die "not a user name: $user (letters, digits, _ and -, up to 32, not root)"
	valid_host "$host" || die "not a host name: $host"
	valid_mirror "$mirror" || die "not a mirror address: $mirror (https://... without spaces)"
	[ -z "$timezone" ] || valid_timezone "$timezone" || die "no such time zone: $timezone"

	if [ "$dry_run" -eq 0 ]; then
		check_system
		clean_previous
		check_network
	fi
	if [ -z "$disk" ]; then
		ask_disk
	elif [ "$dry_run" -eq 0 ]; then
		check_disk
	fi
	suffix=$(part_suffix "$disk")
	[ -n "$timezone" ] || ask_timezone
	nvidia=$(nvidia_package)
	wired=$(wired_interface)
	detect_wifi
	show_plan
	[ "$dry_run" -eq 1 ] || confirm_erase

	live "The disk: two partitions and their file systems" "$(step_partition)"
	live "The base system and mango (this downloads about 600 MiB)" "$(step_base)"
	if [ "$dry_run" -eq 0 ]; then
		root_uuid=$(blkid -s UUID -o value "$disk${suffix}2")
		efi_uuid=$(blkid -s UUID -o value "$disk${suffix}1")
		if [ -z "$root_uuid" ] || [ -z "$efi_uuid" ]; then
			die "the new partitions have no UUIDs"
		fi
		enter_root
	fi
	chrooted "Name, time, language, and what this machine does not need" "$(step_system)"
	chrooted "Microcode and graphics drivers" "$(step_drivers)"
	chrooted "fstab, initramfs, iwd, zram, weekly trim" "$(step_files)"
	chrooted "Limine" "$(step_boot)"
	chrooted "Services" "$(step_services)"
	chrooted "The user; now two passwords" "$(step_users)"
	save_wifi
	chrooted "Kernel, initramfs and boot menu, then a check that it will boot" "$(step_finish)"
	finish
}

# tests/unit.sh loads the functions without running anything
[ "${VOIDMIN_LIB:-0}" = 1 ] || main "$@"
