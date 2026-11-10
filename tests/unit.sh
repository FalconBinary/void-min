#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# install.sh's decisions against made-up machines: nothing here touches a disk. The whole
# install, on a real disk in a VM, is tests/vm.py.
#
#   sh tests/unit.sh
#
# The shell text handed to `lib` and `on` is meant to be read there, not here.
# shellcheck disable=SC2016
set -u

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
script=$here/../install.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0
fail=0

is() { # name, got, want
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL  %s\n      got:  %s\n      want: %s\n' "$1" "$2" "$3"
	fi
}

has() { # name, text, piece
	case $2 in
	*"$3"*) pass=$((pass + 1)) ;;
	*)
		fail=$((fail + 1))
		printf 'FAIL  %s\n      no "%s" in:\n%s\n' "$1" "$3" "$(printf '%s\n' "$2" | tail -n 12)"
		;;
	esac
}

lacks() { # name, text, piece
	case $2 in
	*"$3"*)
		fail=$((fail + 1))
		printf 'FAIL  %s\n      "%s" should not be there\n' "$1" "$3"
		;;
	*) pass=$((pass + 1)) ;;
	esac
}

# Runs shell text with install.sh's functions loaded, in a shell of its own.
lib() {
	(
		# shellcheck disable=SC2034
		VOIDMIN_LIB=1
		# shellcheck source=/dev/null
		. "$script"
		eval "$1"
	)
}

status() { # the exit status of the same
	lib "$1" >/dev/null 2>&1
	echo $?
}

# ---------------------------------------------------------------- made-up machines

device() { # machine, slot, class, vendor, device
	mkdir -p "$work/$1/pci/$2"
	echo "$3" > "$work/$1/pci/$2/class"
	echo "$4" > "$work/$1/pci/$2/vendor"
	echo "$5" > "$work/$1/pci/$2/device"
}

iface() { # machine, name, wired|wifi, operstate
	mkdir -p "$work/$1/net/$2/device"
	[ "$3" != wifi ] || mkdir -p "$work/$1/net/$2/wireless"
	echo "$4" > "$work/$1/net/$2/operstate"
}

machine() { # name, cpu vendor
	mkdir -p "$work/$1/pci" "$work/$1/net/lo"
	echo "vendor_id : $2" > "$work/$1/cpuinfo"
}

usbdev() { # machine, name, vendor as idVendor spells it
	mkdir -p "$work/$1/usb/$2"
	echo "$3" > "$work/$1/usb/$2/idVendor"
}

on() { # machine, shell text: the functions, looking at that machine
	VOIDMIN_PCI=$work/$1/pci VOIDMIN_NET=$work/$1/net VOIDMIN_CPUINFO=$work/$1/cpuinfo VOIDMIN_WPA=$work/$1/wpa.conf \
		VOIDMIN_USB=$work/$1/usb VOIDMIN_SDIO=$work/$1/sdio lib "$2"
}

# An MSI GF63 Thin 10SC: Intel graphics and Wi-Fi, a GTX 1650, no cable.
machine gf63 GenuineIntel
device gf63 0000:00:02.0 0x030000 0x8086 0x9bc4
device gf63 0000:01:00.0 0x030200 0x10de 0x1f99
device gf63 0000:00:14.3 0x028000 0x8086 0x06f0
iface gf63 wlan0 wifi up
iface gf63 enp3s0 wired down
# A desktop: AMD all over, a cable, and an Intel Wi-Fi card nobody uses.
machine ryzen AuthenticAMD
device ryzen 0000:0a:00.0 0x030000 0x1002 0x73bf
device ryzen 0000:00:01.0 0x060400 0x1022 0x1483
device ryzen 0000:05:00.0 0x028000 0x8086 0x2723
iface ryzen enp6s0 wired up
iface ryzen wlan0 wifi down
# An older laptop with a GTX 1050 (Pascal), one with a GT 730 (Kepler), and a VM.
machine pascal GenuineIntel
device pascal 0000:00:02.0 0x030000 0x8086 0x591b
device pascal 0000:01:00.0 0x030200 0x10de 0x1c8d
machine kepler GenuineIntel
device kepler 0000:01:00.0 0x030000 0x10de 0x0fc6
machine vm GenuineIntel
device vm 0000:00:01.0 0x030000 0x1af4 0x1050
iface vm eth0 wired up
# A server: a Mellanox card and a Broadcom one. A PC with a Broadcom Bluetooth dongle, a tablet
# whose Wi-Fi sits on SDIO.
machine server GenuineIntel
device server 0000:03:00.0 0x020000 0x15b3 0x1017
device server 0000:04:00.0 0x020000 0x14e4 0x168e
machine dongle AuthenticAMD
usbdev dongle 1-2 0a5c
usbdev dongle usb1 1d6b
machine tablet GenuineIntel
mkdir -p "$work/tablet/sdio/mmc1:0001:1"

# ---------------------------------------------------------------- names and values

is "nvme partitions take a p" "$(lib 'part_suffix /dev/nvme0n1')" p
is "mmc partitions take a p" "$(lib 'part_suffix /dev/mmcblk0')" p
is "sata partitions take none" "$(lib 'part_suffix /dev/sda')" ""
is "virtio partitions take none" "$(lib 'part_suffix /dev/vda')" ""

is "Bivel is a user name" "$(status 'valid_user Bivel')" 0
is "bivel is a user name" "$(status 'valid_user bivel')" 0
is "root is not" "$(status 'valid_user root')" 1
is "a name with a space is not" "$(status 'valid_user "Bad Name"')" 1
is "a name starting with a digit is not" "$(status 'valid_user 1abc')" 1
is "33 letters are too many" "$(status 'valid_user abcdefghijklmnopqrstuvwxyzabcdefg')" 1
is "bivel needs no --badname" "$(status 'plain_user bivel')" 0
is "Bivel does" "$(status 'plain_user Bivel')" 1

is "void is a host name" "$(status 'valid_host void')" 0
is "a host name with a space is not" "$(status 'valid_host "a b"')" 1
is "a host name starting with a dash is not" "$(status 'valid_host -x')" 1

mkdir -p "$work/zoneinfo/Europe"
: > "$work/zoneinfo/Europe/Kyiv"
: > "$work/zoneinfo/UTC"
zone() { VOIDMIN_ZONEINFO=$work/zoneinfo status "valid_timezone '$1'"; }
is "Europe/Kyiv is a time zone" "$(zone Europe/Kyiv)" 0
is "UTC is a time zone" "$(zone UTC)" 0
is "Europe/Nowhere is not" "$(zone Europe/Nowhere)" 1
is "a path out of zoneinfo is not" "$(zone ../etc/passwd)" 1
is "an absolute path is not" "$(zone /etc/passwd)" 1

is "an https mirror is taken" "$(status 'valid_mirror https://mirror.yandex.ru/mirrors/voidlinux')" 0
is "an http mirror is not" "$(status 'valid_mirror http://repo-de.voidlinux.org')" 1
is "a mirror with shell in it is not" "$(status 'valid_mirror "https://x.org/;reboot"')" 1

# ---------------------------------------------------------------- drivers and firmware

is "GF63: the GTX 1650 gets nvidia" "$(on gf63 nvidia_package)" nvidia
is "GF63: Mesa for Intel beside it" "$(on gf63 gpu_packages)" "mesa-dri vulkan-loader mesa-vulkan-intel"
is "GF63: AMD's and Broadcom's firmware go, and nouveau's: NVIDIA's driver has its own" \
	"$(on gf63 'nvidia=$(nvidia_package); firmware_to_drop')" " linux-firmware-nvidia linux-firmware-amd linux-firmware-broadcom"
drivers=$(on gf63 'nvidia=$(nvidia_package); step_drivers')
has "GF63: Intel microcode" "$drivers" "xbps-install -y intel-ucode"
has "GF63: NVIDIA's driver" "$drivers" "xbps-install -y nvidia"
has "GF63: the GPU may sleep" "$drivers" "NVreg_DynamicPowerManagement=0x02"
has "GF63: without the settings window's GTK" "$drivers" "printf 'ignorepkg=%s\\n' nvidia-gtklibs > /etc/xbps.d/12-nvidia.conf"
has "GF63: the kernel is told about NVIDIA's modeset" "$(on gf63 'nvidia=$(nvidia_package); kernel_cmdline')" "nvidia_drm.modeset=1"

is "Pascal gets nvidia580" "$(on pascal nvidia_package)" nvidia580
drivers=$(on pascal 'nvidia=$(nvidia_package); step_drivers')
has "Pascal: its driver" "$drivers" "xbps-install -y nvidia580"
has "Pascal: without its GTK either" "$drivers" "nvidia580-gtklibs"
lacks "Pascal: no sleep option, that is Turing's" "$drivers" NVreg
is "Kepler gets no driver from NVIDIA" "$(on kepler nvidia_package)" ""
is "Kepler: Mesa drives it, so nouveau's firmware stays" "$(on kepler 'nvidia=$(nvidia_package); firmware_to_drop')" " linux-firmware-amd linux-firmware-broadcom"

is "Ryzen: Mesa for Radeon" "$(on ryzen gpu_packages)" "mesa-dri vulkan-loader mesa-vulkan-radeon"
is "Ryzen: no NVIDIA driver" "$(on ryzen nvidia_package)" ""
is "Ryzen: Intel's firmware stays for its Wi-Fi card, NVIDIA's and Broadcom's go" "$(on ryzen firmware_to_drop)" " linux-firmware-nvidia linux-firmware-broadcom"
is "Ryzen: nothing here is non-free" "$(on ryzen 'if needs_nonfree; then echo yes; else echo no; fi')" no
is "GF63: Intel's microcode and NVIDIA's driver are" "$(on gf63 'nvidia=$(nvidia_package); if needs_nonfree; then echo yes; else echo no; fi')" yes
lacks "Ryzen: no Intel microcode" "$(on ryzen step_drivers)" intel-ucode
lacks "Ryzen: no NVIDIA on the command line" "$(on ryzen kernel_cmdline)" nvidia

is "VM: plain Mesa" "$(on vm gpu_packages)" "mesa-dri vulkan-loader"
is "VM: an Intel CPU keeps Intel's firmware" "$(on vm firmware_to_drop)" " linux-firmware-nvidia linux-firmware-amd linux-firmware-broadcom"
is "a Broadcom card on PCI keeps Broadcom's" "$(on server firmware_to_drop)" " linux-firmware-nvidia linux-firmware-amd"
is "so does a Broadcom dongle on USB" "$(on dongle firmware_to_drop)" " linux-firmware-nvidia linux-firmware-intel"
is "and Wi-Fi on SDIO" "$(on tablet firmware_to_drop)" " linux-firmware-nvidia linux-firmware-amd"

families=$(on gf63 server_firmware | tr '\n' ' ')
is "a laptop unpacks no firmware for switches and server cards" "$families" \
	"mellanox/* mrvl/prestera/* qed/* qlogic/* ql2* phanfw* cxgb3/* cxgb4/* bnx2/* bnx2x/* liquidio/* myri10ge* vxge/* ctfw* ct2fw* cbfw* slicoss/* "
families=$(on server server_firmware | tr '\n' ' ')
lacks "a server keeps its Mellanox card's" "$families" mellanox
lacks "and its Broadcom card's" "$families" bnx2
has "and still leaves out the makers it has nothing of" "$families" "mrvl/prestera/* qed/*"

cmdline=$(on vm 'root_uuid=1234-abcd; kernel_cmdline')
has "the command line names the root by UUID" "$cmdline" "root=UUID=1234-abcd rootfstype=xfs rw"
has "full preemption" "$cmdline" "preempt=full"
lacks "no lockdown: NVIDIA and zcool need it off" "$cmdline" lockdown
lacks "debugfs stays: zcool reads an MSI EC through it" "$cmdline" debugfs
lacks "32-bit programs stay able to run" "$cmdline" ia32_emulation
lacks "no serial console unless asked" "$cmdline" ttyS0
has "a serial console when asked" "$(on vm 'serial=1; kernel_cmdline')" "console=tty0 console=ttyS0,115200"

# ---------------------------------------------------------------- the network

is "GF63: no cable in use" "$(on gf63 wired_interface)" ""
is "GF63: it has Wi-Fi" "$(on gf63 'if has_wifi; then echo yes; else echo no; fi')" yes
is "Ryzen: the cable that is up" "$(on ryzen wired_interface)" enp6s0
is "VM: eth0" "$(on vm wired_interface)" eth0
is "VM: no Wi-Fi" "$(on vm 'if has_wifi; then echo yes; else echo no; fi')" no

wifi() { # machine, [ssid]
	on "$1" "wifi_from_wpa \"\$wpa_conf\" ${2:+\"$2\"}; echo \"\$wifi_ssid|\$wifi_key|\$wifi_value\""
}
hex=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
# as `wpa_passphrase "Home Net" "correct horse"` writes it, after the ISO's own lines
cat > "$work/gf63/wpa.conf" <<EOF
ctrl_interface=DIR=/run/wpa_supplicant GROUP=wheel
update_config=1
network={
	ssid="Home Net"
	#psk="correct horse"
	psk=$hex
}
EOF
is "the passphrase wpa_passphrase left in a comment is taken" "$(wifi gf63)" "Home Net|Passphrase|correct horse"
cat > "$work/ryzen/wpa.conf" <<EOF
network={
	ssid="First"
	psk=$hex
}
network={
	ssid="Second"
	psk="typed by hand"
}
network={
	ssid="Open Cafe"
	key_mgmt=NONE
}
EOF
is "without a name, the last network that has a key" "$(wifi ryzen)" "Second|Passphrase|typed by hand"
is "by name, with only the key: the key" "$(wifi ryzen First)" "First|PreSharedKey|$hex"
is "an open network is not carried over" "$(wifi ryzen 'Open Cafe')" "||"
is "a network that is not in the file" "$(wifi ryzen Elsewhere)" "||"
is "no file, no network" "$(wifi vm)" "||"

is "a plain SSID names its own file" "$(lib 'iwd_file_name "Home Net-5_G"')" "Home Net-5_G.psk"
is "any other SSID is spelled in hex" "$(lib 'iwd_file_name "a/b"')" "=612f62.psk"

# ---------------------------------------------------------------- the whole run, dry

dry() { # machine, arguments
	m=$1
	shift
	VOIDMIN_PCI=$work/$m/pci VOIDMIN_NET=$work/$m/net VOIDMIN_CPUINFO=$work/$m/cpuinfo VOIDMIN_WPA=$work/$m/wpa.conf \
		VOIDMIN_USB=$work/$m/usb VOIDMIN_SDIO=$work/$m/sdio VOIDMIN_ZONEINFO=$work/zoneinfo sh "$script" --dry-run "$@" 2>&1
}

out=$(dry gf63 --disk /dev/nvme0n1 --timezone Europe/Kyiv)
is "a dry run ends well" $? 0
has "GF63: the disk is partitioned in two" "$out" "printf 'label: gpt\\nsize=1024M, type=U\\ntype=L\\n' | sfdisk --wipe always --wipe-partitions always /dev/nvme0n1"
has "GF63: XFS on the second partition" "$out" "mkfs.xfs -f -L root /dev/nvme0n1p2"
has "GF63: the user is Bivel, as written" "$out" "useradd --badname -m -G wheel,audio,video Bivel"
has "GF63: the machine is void" "$out" "echo void > /etc/hostname"
has "GF63: the time zone" "$out" "ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime"
has "GF63: what starts it, joins Wi-Fi and shows a terminal in mango, and no more" "$out" \
	"-R https://repo-de.voidlinux.org/current base-system zstd limine efibootmgr iwd openresolv dbus elogind chrony zramen snooze run-parts opendoas mangowc foot dejavu-fonts-ttf mesa-dri vulkan-loader mesa-vulkan-intel
"
lacks "GF63: git is left to kombain" "$out" "opendoas git"
has "GF63: without a cable dhcpcd goes" "$out" "ignorepkg=%s\\n' wpa_supplicant sudo btrfs-progs f2fs-tools dhcpcd linux-firmware-nvidia linux-firmware-amd linux-firmware-broadcom >"
has "GF63: server firmware is never unpacked" "$out" "printf 'noextract=/usr/lib/firmware/%s\\n' 'mellanox/*' 'mrvl/prestera/*'"
has "GF63: the repository that is not free software, for microcode and NVIDIA" "$out" \
	"printf 'repository=%s/nonfree\\n' https://repo-de.voidlinux.org/current > /mnt/etc/xbps.d/10-repository-nonfree.conf"
has "GF63: the way to kombain starts with git" "$out" "That was a dry run"
has "GF63: the services, and no more" "$out" "for s in udevd dbus elogind iwd chronyd zramen snooze-weekly agetty-tty1 agetty-tty2; do"
has "GF63: the Wi-Fi network is named" "$out" "Wi-Fi: Home Net is saved for iwd"
lacks "GF63: its passphrase is not shown" "$out" "correct horse"
lacks "GF63: nor its key" "$out" "$hex"
has "GF63: the root is named by UUID in the boot menu" "$out" 'CMD="root=UUID=ROOT-UUID rootfstype=xfs rw quiet loglevel=3 zswap.enabled=0'
has "GF63: the hint for kombain names the user" "$out" "That was a dry run"
lacks "nothing asks for a password in a dry run's own words" "$out" "New password"

out=$(dry ryzen --disk /dev/sda --timezone UTC --user anna --host box --serial --mirror https://mirror.yandex.ru/mirrors/voidlinux/)
has "Ryzen: SATA partition names" "$out" "mkfs.vfat -F32 -n EFI /dev/sda1"
has "Ryzen: a lowercase name needs no flag" "$out" "useradd -m -G wheel,audio,video anna"
has "Ryzen: the cable's own dhcpcd service" "$out" "cp -R /etc/sv/dhcpcd-eth0 /etc/sv/dhcpcd-enp6s0"
has "Ryzen: and its link, with a serial login" "$out" "agetty-tty1 agetty-tty2 dhcpcd-enp6s0 agetty-ttyS0; do"
has "Ryzen: dhcpcd stays" "$out" "ignorepkg=%s\\n' wpa_supplicant sudo btrfs-progs f2fs-tools linux-firmware-nvidia linux-firmware-broadcom >"
lacks "Ryzen: no repository that is not free software" "$out" nonfree
has "Ryzen: the mirror, without its trailing slash" "$out" "repository=%s\\n' https://mirror.yandex.ru/mirrors/voidlinux/current >"
has "Ryzen: the serial console" "$out" "console=tty0 console=ttyS0,115200"

out=$(dry vm --disk /dev/vda --timezone UTC)
has "VM: eth0 uses the service that comes with the system" "$out" "agetty-tty1 agetty-tty2 dhcpcd-eth0; do"
lacks "VM: and copies nothing" "$out" "cp -R /etc/sv/dhcpcd-eth0"

out=$(printf 'Europe/Nowhere\nEurope/Kyiv\n' | dry vm --disk /dev/vda)
has "a time zone that does not exist is asked again" "$out" "No such zone"
has "and the next answer is taken" "$out" "time zone Europe/Kyiv"

dry vm --disk /dev/vda --timezone UTC --user root >/dev/null 2>&1
is "root as the user is refused" $? 1
dry vm --disk /dev/vda --timezone UTC --mirror 'http://x' >/dev/null 2>&1
is "a mirror without https is refused" $? 1
dry vm --disk /dev/vda --timezone Mars/Olympus >/dev/null 2>&1
is "a time zone that is not there is refused" $? 1
dry vm --frobnicate >/dev/null 2>&1
is "an unknown option is refused" $? 1
has "--help says what it does" "$(sh "$script" --help)" "--disk DEV       the disk to erase and install on"

# ---------------------------------------------------------------- the boot menu hook

boot=$work/boot
mkdir -p "$boot"
: > "$work/BOOTX64.EFI"
for v in 6.18.60_1 6.18.62_1 6.18.62-kombain_1 6.19.1_1; do : > "$boot/vmlinuz-$v"; done
# 6.19.1_1 has no initramfs yet: it must not be offered
for v in 6.18.60_1 6.18.62_1 6.18.62-kombain_1; do : > "$boot/initramfs-$v.img"; done
on vm 'step_boot' | sed -n "/<<'HOOK'/,/^HOOK\$/p" | sed '1d;$d' > "$work/60-limine"
sed -i.bak 's|^CMD="VOIDMIN-CMDLINE"$|CMD="root=UUID=abcd rw"|' "$work/60-limine"
VOIDMIN_BOOT=$boot VOIDMIN_LIMINE=$work/BOOTX64.EFI sh "$work/60-limine"
is "the hook ends well" $? 0
is "Void's own newest kernel first, kombain's after them, none without an initramfs" \
	"$(grep '^/Void ' "$boot/limine.conf" | tr '\n' ' ')" "/Void 6.18.62_1 /Void 6.18.60_1 /Void 6.18.62-kombain_1 "
has "each entry has the command line" "$(cat "$boot/limine.conf")" "    cmdline: root=UUID=abcd rw"
has "and its own initramfs" "$(cat "$boot/limine.conf")" "    module_path: boot():/initramfs-6.18.62-kombain_1.img"
is "Limine itself is put in place" "$([ -e "$boot/EFI/BOOT/BOOTX64.EFI" ] && echo yes)" yes
rm -f "$boot"/initramfs-*
VOIDMIN_BOOT=$boot VOIDMIN_LIMINE=$work/BOOTX64.EFI sh "$work/60-limine"
is "with no kernel to offer the old menu stays" "$(grep -c '^/Void ' "$boot/limine.conf")" 3

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
