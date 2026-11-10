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

is "a disk by its own name is itself" "$(lib 'canonical_disk /dev/nvme0n1')" /dev/nvme0n1
ln -s /dev/null "$work/a-link"
is "a link is followed to what it names" "$(lib "canonical_disk $work/a-link")" /dev/null
is "a link that leads to no /dev/NAME is refused" "$(status 'canonical_disk /dev/disk/by-id/no-such-disk')" 1
is "nothing with shell in it is a disk" "$(status "canonical_disk '/dev/sda;reboot'")" 1
is "a path elsewhere is not a disk" "$(status 'canonical_disk /tmp/disk.img')" 1
is "what is not a block device cannot be installed on" "$(lib 'disk_problem /dev/null')" "/dev/null is not a disk"

is "an https mirror is taken" "$(status 'valid_mirror https://mirror.yandex.ru/mirrors/voidlinux')" 0
is "an http mirror is not" "$(status 'valid_mirror http://repo-de.voidlinux.org')" 1
is "a mirror with shell in it is not" "$(status 'valid_mirror "https://x.org/;reboot"')" 1

# ---------------------------------------------------------------- drivers and firmware

is "GF63: the GTX 1650 gets nvidia" "$(on gf63 nvidia_package)" nvidia
is "GF63: Mesa for Intel beside it" "$(on gf63 gpu_packages)" "mesa-dri vulkan-loader mesa-vulkan-intel"
is "GF63: AMD's and Broadcom's firmware go, and nouveau's: NVIDIA's driver has its own" \
	"$(on gf63 'nvidia=$(nvidia_package); firmware_to_drop')" " linux-firmware-nvidia linux-firmware-amd linux-firmware-broadcom"
drivers=$(on gf63 'nvidia=$(nvidia_package); step_drivers')
has "GF63: Intel microcode" "$drivers" "xbps-install -y intel-ucode </dev/null"
has "GF63: NVIDIA's driver, with nobody to answer a question about a key" "$drivers" "xbps-install -y nvidia </dev/null"
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
machine odd GenuineIntel
iface odd 'eth0;reboot' wired up
is "an interface whose name could not go into a command is not taken" "$(on odd wired_interface)" ""

wifi() { # machine, [ssid]
	on "$1" "wifi_from_wpa \"\$wpa_conf\" ${2:+\"$2\"}; echo \"\$wifi_ssid|\$wifi_key|\$wifi_value\""
}
hex=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
# as `wpa_passphrase 'Home Net' 'correct horse'` writes it, after the ISO's own lines
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

# iwd reads its files with escapes of its own. What it makes of each line below was asked of ell,
# the library it reads them with; tests/vm.py asks again at every install.
value() { V=$1 lib 'iwd_value "$V"'; }
is "what iwd reads as typed is written as typed" "$(value 'pa$$w0rd!now "q" `t` =#;[x]')" 'pa$$w0rd!now "q" `t` =#;[x]'
is "a backslash is doubled: iwd would read C:\\new with a line break in it, and \\d not at all" "$(value 'C:\new\dir')" 'C:\\new\\dir'
is "spaces in front are spelled out, or iwd drops them; one at the end stays" "$(value '  two in front, one at the end ')" '\s\stwo in front, one at the end '
# as wpa_passphrase writes a passphrase that only single quotes get past a shell
cat > "$work/pascal/wpa.conf" <<'EOF'
network={
	ssid="Net"
	#psk=" pa$$ "w" C:\new `tick` !"
	psk=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
}
EOF
is "the file for iwd holds such a passphrase the way iwd writes one itself" "$(on pascal 'wifi_from_wpa "$wpa_conf"; iwd_file')" '[Security]
Passphrase=\spa$$ "w" C:\\new `tick` !'
is "a key goes into it as it is" "$(on ryzen 'wifi_from_wpa "$wpa_conf" First; iwd_file')" "[Security]
PreSharedKey=$hex"

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
	"-R https://repo-de.voidlinux.org/current base-system zstd limine efibootmgr iwd openresolv dbus elogind chrony zramen snooze run-parts opendoas mangowc foot dejavu-fonts-ttf mesa-dri vulkan-loader mesa-vulkan-intel </dev/null
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
dry vm --disk '/dev/vda; reboot' --timezone UTC >/dev/null 2>&1
is "a disk that is not /dev/NAME is refused" $? 1
dry vm --disk /dev/disk/by-id/no-such-disk --timezone UTC >/dev/null 2>&1
is "so is a link that leads nowhere" $? 1
dry vm --disk /dev/vda --timezone UTC --mirror 'http://x' >/dev/null 2>&1
is "a mirror without https is refused" $? 1
dry vm --disk /dev/vda --timezone Mars/Olympus >/dev/null 2>&1
is "a time zone that is not there is refused" $? 1
dry vm --frobnicate >/dev/null 2>&1
is "an unknown option is refused" $? 1
has "--help says what it does" "$(sh "$script" --help)" "--disk DEV       the disk to erase and install on"

# ---------------------------------------------------------------- the mirror, before anything is erased

for kind in trusted foreign silent; do mkdir -p "$work/$kind"; done
cat > "$work/trusted/xbps-install" <<'EOF'
#!/bin/sh
echo "[*] Updating repository \`https://x.org/current/x86_64-repodata' ..."
EOF
cat > "$work/trusted/xbps-query" <<'EOF'
#!/bin/sh
echo base-system-0.114_2
EOF
# what xbps says of a list signed with a key it does not know, with nobody to answer
cat > "$work/foreign/xbps-install" <<'EOF'
#!/bin/sh
echo "\`https://x.org/current' repository has been RSA signed by \"Somebody\""
echo "Fingerprint: 00:11:22"
echo "Do you want to import this public key? [Y/n] ERROR: Failed to import pubkey from https://x.org/current"
EOF
cp "$work/trusted/xbps-query" "$work/foreign/xbps-query"
printf '#!/bin/sh\nexit 1\n' > "$work/silent/xbps-install"
printf '#!/bin/sh\nexit 2\n' > "$work/silent/xbps-query"
chmod +x "$work"/trusted/* "$work"/foreign/* "$work"/silent/*
mirror() { # which stand-in for xbps
	PATH=$work/$1:$PATH lib 'mirror=https://x.org; check_mirror' 2>&1
	echo "exit $?"
}
is "a mirror signed with a key the ISO trusts passes" "$(mirror trusted)" "exit 0"
out=$(mirror foreign)
has "a mirror signed with any other key stops it" "$out" "the packages at https://x.org are not signed with a key this ISO trusts. Nothing was touched."
has "and it stops there" "$out" "exit 1"
out=$(mirror silent)
has "an address with no Void packages stops it" "$out" "no Void packages at https://x.org"
has "and there" "$out" "exit 1"

# ---------------------------------------------------------------- no network: what a person is told to type

mkdir -p "$work/online" "$work/offline"
printf '#!/bin/sh\nexit 0\n' > "$work/online/getent"
printf '#!/bin/sh\nexit 2\n' > "$work/offline/getent"
chmod +x "$work/online/getent" "$work/offline/getent"
network() { # which stand-in for getent
	PATH=$work/$1:$PATH lib 'mirror=https://x.org; check_network' 2>&1
	echo "exit $?"
}
is "with a network it goes on" "$(network online)" "exit 0"
out=$(network offline)
has "without one it stops" "$out" "exit 1"
has "and says how to join Wi-Fi" "$out" "install.sh: no network. With a cable it comes up by itself; for Wi-Fi:"
shown=$(printf '%s\n' "$out" | grep wpa_passphrase | sed 's/^ *//')
is "the command it shows, in single quotes" "$shown" "wpa_passphrase 'NETWORK' 'PASSWORD' >> /etc/wpa_supplicant/wpa_supplicant.conf"
# The same command with a name and a password a shell would change in double quotes, typed where
# the two words stand. This stands in for the real wpa_passphrase and shows what it was given.
wpa_passphrase() { printf '%s|%s' "$1" "$2"; }
net='Caf$HOME "5G"'
pw='pa$$ `id` \n "q" !1'
typed=${shown%%NETWORK*}$net${shown#*NETWORK}
typed=${typed%%PASSWORD*}$pw${typed#*PASSWORD}
is "typed as shown, the name and the password reach wpa_passphrase as they are" "$(eval "${typed%% >>*}")" "$(wpa_passphrase "$net" "$pw")"
readme=$(cat "$here/../README.md")
has "the README shows the command the same way" "$readme" "wpa_passphrase '"
lacks "and nowhere a name or a password in double quotes" "$readme" 'wpa_passphrase "'

# ---------------------------------------------------------------- the firmware's boot entries

mkdir -p "$work/efi" "$work/partuuid"
: > "$work/partuuid/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
cat > "$work/efi/efibootmgr" <<'EOF'
#!/bin/sh
echo "$*" >> "$EFI_LOG"
[ "$1" = -v ] || exit 0
cat <<'OUT'
BootCurrent: 0002
Timeout: 0 seconds
BootOrder: 0002,0001,0003,0004,0000
Boot0000* UiApp	FvVol(7cb8bdc9-f8eb-4f34-aaea-3ee4af6516a1)/FvFile(462caa21-7614-4503-836e-8ab6f4662331)
Boot0001* Limine	HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x200000)/\EFI\BOOT\BOOTX64.EFI
Boot0002* Limine	HD(1,GPT,AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE,0x800,0x200000)/\EFI\BOOT\BOOTX64.EFI
Boot0003* Windows Boot Manager	HD(1,GPT,99999999-2222-3333-4444-555555555555,0x800,0x32000)/\EFI\Microsoft\Boot\bootmgfw.efi
Boot0004* Limine over the network	PciRoot(0x0)/Pci(0x2,0x0)/MAC(525400123456,1)
OUT
EOF
chmod +x "$work/efi/efibootmgr"
on vm 'disk=/dev/vda; step_boot' | sed -n '/^efibootmgr -v/,$p' > "$work/entries.sh"
EFI_LOG=$work/efi.log PATH=$work/efi:$PATH VOIDMIN_PARTUUID=$work/partuuid sh -eu "$work/entries.sh"
is "the boot entries step ends well" $? 0
is "of the entries named Limine only the one whose partition is gone is removed; another system's, Windows and the rest stay" \
	"$(tr '\n' '|' < "$work/efi.log")" "-v|-q -b 0001 -B|-q --create --disk /dev/vda --part 1 --label Limine --loader \EFI\BOOT\BOOTX64.EFI|"

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
