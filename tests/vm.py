#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Installs Void Linux in a VM with install.sh, typed at the live ISO's serial console as a person
would, wrong answers included; then boots what it installed and checks it.

  python3 tests/vm.py --iso void-live-x86_64-20250202-base.iso --work vm-work

Test-only differences from a real install: a serial console so this script can see the machine
(install.sh --serial), a wireless device that is only a name on top of the wired one (virt_wifi),
and install.sh fetched from this checkout over the VM's own network instead of from GitHub;
--raw also fetches it the way the README says and compares the two.

The console handling comes from kombain's tests/vm/install.py.
"""
import argparse
import functools
import http.server
import os
import re
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# The ISO's own boot arguments, with a serial console added.
LIVE_ARGS = (
    "root=live:CDLABEL=VOID_LIVE ro init=/sbin/init rd.luks=0 rd.md=0 rd.dm=0 loglevel=4 gpt add_efi_memmap "
    "vconsole.unicode=1 vconsole.keymap=us locale.LANG=en_US.UTF-8 rd.live.overlay.overlayfs=1 "
    "console=tty0 console=ttyS0,115200"
)
# None of these protect anything: they exist only inside this throwaway VM.
PASSWORD = "test-password"
WIFI_SSID = "void-min test"
WIFI_PASSPHRASE = "test-wifi-passphrase"
PROMPT = "VOIDMIN# "
USER = "Bivel"
HOST = "void"
ZONE = "Europe/Kyiv"

FIRMWARE = [
    ("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"),
    ("/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_VARS.fd"),
    ("/opt/homebrew/share/qemu/edk2-x86_64-code.fd", "/opt/homebrew/share/qemu/edk2-i386-vars.fd"),
]


class Failed(Exception):
    pass


class VM:
    """QEMU with its serial port on a pipe, plus a small expect."""

    def __init__(self, args, log_path):
        self.log = open(log_path, "ab")
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.buf = ""
        self.pos = 0
        self.lock = threading.Lock()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        while True:
            data = os.read(self.proc.stdout.fileno(), 65536)
            if not data:
                return
            self.log.write(data)
            self.log.flush()
            with self.lock:
                self.buf += data.decode("utf-8", "replace")

    def send(self, text):
        data = text.encode()
        for i in range(0, len(data), 128):
            self.proc.stdin.write(data[i:i + 128])
            self.proc.stdin.flush()
            time.sleep(0.02)

    def wait(self, patterns, timeout):
        """Returns (index of the pattern that matched first, match) and moves past it."""
        compiled = [re.compile(p) for p in patterns]
        end = time.time() + timeout
        while time.time() < end:
            with self.lock:
                text = self.buf[self.pos:]
                best = None
                for index, pattern in enumerate(compiled):
                    m = pattern.search(text)
                    if m and (best is None or m.start() < best[1].start()):
                        best = (index, m)
                if best:
                    self.pos += best[1].end()
                    return best
            if self.proc.poll() is not None and not self.reader.is_alive():
                raise Failed(f"the VM exited while waiting for {patterns}\n{self.tail()}")
            time.sleep(0.1)
        raise Failed(f"timed out after {timeout} s waiting for {patterns}\n{self.tail()}")

    def tail(self, chars=1500):
        with self.lock:
            return clean(self.buf[-chars:])

    def wait_exit(self, timeout):
        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Failed(f"the VM did not power off within {timeout} s\n{self.tail()}")

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


def clean(text):
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\r", "", text)


class Run:
    def __init__(self, opts):
        self.o = opts
        self.results = []
        self.vm = None
        os.makedirs(opts.work, exist_ok=True)
        self.disk = os.path.join(opts.work, "disk.qcow2")
        self.vars = os.path.join(opts.work, "vars.fd")
        self.log_path = os.path.join(opts.work, "serial.log")
        self.disk_dev = "/dev/vda" if opts.disk_bus == "virtio" else "/dev/nvme0n1"
        self.wired = ""
        self.notes = []

    # ------------------------------------------------------------ machine

    def firmware(self):
        for code, varsfile in FIRMWARE:
            if os.path.exists(code) and os.path.exists(varsfile):
                return code, varsfile
        raise Failed("no UEFI firmware found")

    def qemu(self, live):
        code, varsfile = self.firmware()
        if not os.path.exists(self.vars):
            with open(varsfile, "rb") as src, open(self.vars, "wb") as dst:
                dst.write(src.read())
        if not os.path.exists(self.disk):
            subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", self.disk, self.o.disk_size], check=True)
        kvm = os.access("/dev/kvm", os.R_OK | os.W_OK)
        args = [
            "qemu-system-x86_64", "-machine", "q35,vmport=off", "-m", str(self.o.memory), "-smp", str(self.o.cpus),
            "-accel", "kvm" if kvm else "tcg", "-cpu", "host" if kvm else "max",
            "-display", "none", "-serial", "stdio", "-no-reboot",
            "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
            "-drive", f"if=pflash,format=raw,file={self.vars}",
            "-drive", f"file={self.disk},if=none,id=disk0,format=qcow2,discard=unmap",
            "-device", "nvme,drive=disk0,serial=voidmin" if self.o.disk_bus == "nvme" else "virtio-blk-pci,drive=disk0",
            "-device", "virtio-vga",
            "-nic", "user,model=virtio-net-pci",
            "-device", "virtio-rng-pci",
        ]
        if live:
            kernel, initrd = self.extract_boot()
            args += ["-kernel", kernel, "-initrd", initrd, "-append", LIVE_ARGS, "-cdrom", self.o.iso]
        self.vm = VM(args, self.log_path)
        print(f"VM started ({'kvm' if kvm else 'tcg'}, {'live ISO' if live else 'installed disk'})", flush=True)

    def extract_boot(self):
        out = os.path.join(self.o.work, "boot")
        kernel, initrd = os.path.join(out, "vmlinuz"), os.path.join(out, "initrd")
        if not os.path.exists(kernel):
            tar = "bsdtar" if subprocess.run(["which", "bsdtar"], capture_output=True).returncode == 0 else "tar"
            subprocess.run([tar, "-xf", self.o.iso, "-C", self.o.work, "boot/vmlinuz", "boot/initrd"], check=True)
        return kernel, initrd

    def serve(self):
        """This checkout over HTTP, where the VM reaches the host as 10.0.2.2."""
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=REPO)
        handler.log_message = lambda *a, **k: None
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server.server_address[1]

    # ------------------------------------------------------------ shell

    def login(self, name, password, timeout):
        index, _ = self.vm.wait([r"login: ", r"[#$] $"], timeout)
        if index == 0:
            self.vm.send(name + "\n")
            self.vm.wait([r"Password: "], 60)
            self.vm.send(password + "\n")
        self.adopt_shell()

    def adopt_shell(self):
        time.sleep(1)
        self.vm.send(f"export PS1='{PROMPT}' TERM=dumb PAGER=cat; stty cols 200; echo ADOPT$((40+2))\n")
        self.vm.wait([r"ADOPT42"], 120)
        self.vm.wait([re.escape(PROMPT)], 60)

    def sh(self, text, timeout=600, check=True, what=None):
        """Runs a block in a subshell with `set -e`. Returns its output."""
        vm = self.vm
        marker = f"K{int(time.time() * 1000)}"
        vm.send(f"cat > /tmp/step <<'{marker}'\n{text}\n{marker}\n")
        vm.wait([re.escape(PROMPT)], 120)
        vm.send(f"( set -e; . /tmp/step ) 2>&1; echo \"{marker}=$((0+$?))=\"\n")
        # move past the echo of the command itself: the shell prints a literal $? in it
        vm.wait([re.escape(f'{marker}=$((0+$?))=') + r'"\r?\n'], 60)
        start = vm.pos
        _, m = vm.wait([rf"{marker}=(\d+)="], timeout)
        output = clean(vm.buf[start:vm.pos - len(m.group(0))])
        vm.wait([re.escape(PROMPT)], 60)
        if int(m.group(1)) != 0 and check:
            raise Failed(f"{what or text.splitlines()[0]} failed with {m.group(1)}\n{output[-1500:]}")
        return output

    def out(self, command):
        return self.sh(command, check=False, timeout=180).strip()

    def expect(self, name, ok, detail=""):
        self.results.append((bool(ok), name, str(detail)[:300]))
        print(f"{'ok  ' if ok else 'FAIL'}  {name}" + (f"  [{str(detail)[:200]}]" if not ok else ""), flush=True)

    def note(self, text):
        self.notes.append(text)
        print(f"      {text}", flush=True)

    # ------------------------------------------------------------ the install

    def wait_network(self, seconds=120):
        """Real name resolution: xbps-install -S exits 0 without a network."""
        start = time.time()
        while time.time() - start < seconds:
            if "net-yes" in self.out("getent hosts repo-de.voidlinux.org >/dev/null && echo net-yes || echo net-no"):
                return True
            time.sleep(3)
        print(self.out("cat /etc/resolv.conf; ip -br addr; ip route"), flush=True)
        return False

    def boot_live(self):
        self.qemu(live=True)
        self.login("root", "voidlinux", self.o.boot_timeout)
        self.expect("the live ISO boots to a shell over serial", True)
        self.expect("the live ISO has a network", self.wait_network())
        # the name install.sh will see for the cable
        self.wired = self.out("for d in /sys/class/net/*; do [ -e $d/device ] && [ ! -e $d/wireless ] && [ \"$(cat $d/operstate)\" = up ] && basename $d && break; done; true").strip().splitlines()[-1:]
        self.wired = self.wired[0].strip() if self.wired else ""
        print(f"wired interface in the live system: {self.wired!r}", flush=True)

    def install(self):
        vm = self.vm
        port = self.serve()
        self.sh(f"cd /root && rm -f install.sh && xbps-fetch -o install.sh http://10.0.2.2:{port}/install.sh && test -s install.sh", what="fetch install.sh from this checkout")
        if self.o.raw:
            fetched = self.out(f"cd /tmp && rm -f install.sh && xbps-fetch {self.o.raw} >/dev/null 2>&1; cmp -s /tmp/install.sh /root/install.sh && echo same-file")
            self.expect("the README's own command fetches the same file from GitHub", "same-file" in fetched, fetched[-300:])
        # test only: a radio and the network a person would have joined with the guide's three commands,
        # so install.sh has something to carry over. Nothing connects through it; the cable goes on working.
        radio = self.out("modprobe virt_wifi && for d in /sys/class/net/*; do [ -e $d/device ] && ip link add link ${d##*/} name wlan0 type virt_wifi && break; done; "
                         "[ -e /sys/class/net/wlan0/wireless ] && echo radio-ready; true")
        self.radio = radio.splitlines()[-1:] == ["radio-ready"]
        print(f"radio in the live system: {self.radio}", flush=True)
        self.sh(f"wpa_passphrase '{WIFI_SSID}' '{WIFI_PASSPHRASE}' >> /etc/wpa_supplicant/wpa_supplicant.conf", what="a Wi-Fi network in wpa_supplicant.conf")

        before = self.out(f"lsblk -nro NAME {self.disk_dev} | wc -l")
        dry = self.sh(f"printf '\\n' | sh /root/install.sh --dry-run --disk {self.disk_dev}", what="a dry run")
        self.expect("a dry run prints the commands and says so", "That was a dry run: nothing was changed." in dry and "sfdisk --wipe always" in dry, dry[-300:])
        self.expect("a dry run leaves the disk alone", self.out(f"lsblk -nro NAME {self.disk_dev} | wc -l") == before and before == "1", before)
        self.expect("a dry run does not show the Wi-Fi passphrase", WIFI_PASSPHRASE not in dry)

        name = self.disk_dev.rsplit("/", 1)[1]
        vm.send("sh /root/install.sh --serial; echo INSTALL-EXIT=$((0+$?))=\n")

        def say(pattern, answer=None, timeout=120):
            index, m = vm.wait([pattern, r"(?m)^install\.sh: [^\n]*", r"INSTALL-EXIT=(\d+)="], timeout)
            if index != 0:
                raise Failed(f"install.sh stopped while waiting for {pattern!r}: {m.group(0)}\n{vm.tail()}")
            if answer is not None:
                time.sleep(0.5)
                vm.send(answer + "\n")
            return m

        say(r"Install on disk number \[1\]: ", "7")
        say(r"That is not on the list")
        say(r"Install on disk number \[1\]: ", "")
        say(r"Time zone, as Europe/Kyiv \[UTC\]: ", "Europe/Nowhere")
        say(r"No such zone")
        say(r"Time zone, as Europe/Kyiv \[UTC\]: ", ZONE)
        plan = say(rf"(?s)Void Linux on {re.escape(self.disk_dev)}:.*?Type {name} to erase it, or stop to quit: ").group(0)
        self.expect("the plan names the user, the host and the time zone", f"User {USER}, host {HOST}, time zone {ZONE}." in plan, plan[:400])
        self.expect("the plan says the name is case sensitive", f"The name {USER} is typed at the login prompt exactly so" in plan)
        if self.wired:
            self.expect("the plan keeps the cable that is up", f"Wired network on {self.wired} stays." in plan, plan[:600])
        self.expect("the plan carries the Wi-Fi network over", f"Wi-Fi: {WIFI_SSID}, as joined here" in plan, plan[:800])
        vm.send(name[:-1] + "\n")
        say(r"That is not the disk's name\. Nothing was erased\.")
        self.expect("a wrong name erases nothing", True)
        say(rf"Type {name} to erase it, or stop to quit: ", name)

        say(r"==> The base system and mango", timeout=300)
        say(r"A password for root:", timeout=self.o.install_timeout)
        # a person mistypes it once
        say(r"New password: ", PASSWORD)
        say(r"Retype new password: ", PASSWORD + "x")
        say(r"Again:")
        say(r"New password: ", PASSWORD)
        say(r"Retype new password: ", PASSWORD)
        say(rf"A password for {USER}:")
        say(r"New password: ", PASSWORD)
        say(r"Retype new password: ", PASSWORD)
        say(rf"Wi-Fi: {re.escape(WIFI_SSID)} is saved for iwd")
        done = say(r"(?s)Done\. After the reboot.*?press Enter to reboot: ", timeout=self.o.install_timeout).group(0)
        self.expect("install.sh runs to its end", True)
        self.expect("it says how to start the desktop and put kombain on top", "dbus-run-session mango" in done and f"doas ./install.sh --user {USER}" in done, done[-400:])
        vm.send("\n")
        vm.wait_exit(180)

    # ------------------------------------------------------------ what it installed

    def boot_disk(self):
        self.qemu(live=False)
        started = time.time()
        _, m = self.vm.wait([r"(\S+) login: "], self.o.boot_timeout)
        self.note(f"power on to the login prompt: {time.time() - started:.0f} s")
        self.expect("the installed system boots to a login prompt named after the machine", m.group(1) == HOST, m.group(0))
        # the user's own login, the name typed as written
        self.vm.send(USER + "\n")
        self.vm.wait([r"Password: "], 60)
        self.vm.send(PASSWORD + "\n")
        self.adopt_shell()
        self.expect(f"{USER} logs in at the console", self.out("id -un").splitlines()[-1] == USER, self.out("id"))
        groups = self.out("id -Gn").split()
        self.expect(f"{USER} is in wheel, audio and video", {"wheel", "audio", "video"} <= set(groups), groups)
        self.expect("the home directory is the user's alone", self.out(f"stat -c '%a %U' /home/{USER}") == f"700 {USER}", self.out(f"ls -ld /home/{USER}"))
        self.vm.send("exit\n")
        self.login("root", PASSWORD, 120)

    def check(self):
        out, expect = self.out, self.expect
        expect("the host name", out("hostname") == HOST, out("hostname"))
        expect("the time zone", out("readlink /etc/localtime").endswith("/" + ZONE), out("readlink /etc/localtime"))
        cmdline = out("cat /proc/cmdline")
        expect("the kernel command line: root by UUID, full preemption, zram instead of zswap",
               all(w in cmdline for w in ("root=UUID=", "rootfstype=xfs", "preempt=full", "zswap.enabled=0", "nowatchdog")), cmdline)
        expect("no lockdown, debugfs left alone, 32-bit programs can run", not any(w in cmdline for w in ("lockdown", "debugfs", "ia32_emulation")), cmdline)
        expect("/ is XFS with noatime", "xfs" in out("findmnt -no FSTYPE /") and "noatime" in out("findmnt -no OPTIONS /"), out("findmnt -no FSTYPE,OPTIONS /"))
        expect("/boot is the EFI partition, readable by root alone", "vfat" in out("findmnt -no FSTYPE /boot") and "fmask=0077" in out("findmnt -no OPTIONS /boot"), out("findmnt -no FSTYPE,OPTIONS /boot"))
        expect("/tmp is in memory", out("findmnt -no FSTYPE /tmp") == "tmpfs", out("findmnt /tmp"))

        want = ["agetty-tty1", "agetty-tty2", "agetty-ttyS0", "chronyd", "dbus", "elogind", "iwd", "snooze-weekly", "udevd", "zramen"]
        if self.wired:
            want.append(f"dhcpcd-{self.wired}")
        services = out("ls /etc/runit/runsvdir/current/").split()
        expect("the services are the ones asked for, and no more", sorted(services) == sorted(want), services)
        time.sleep(5)
        status = out("for s in /var/service/*; do sv status $s; done")
        expect("every service runs", "down:" not in status and "fail:" not in status and status.count("run:") >= len(want), status)
        expect("the network works after the reboot", "net-yes" in out("getent hosts voidlinux.org >/dev/null && echo net-yes || echo net-no"), out("ip -br addr; cat /etc/resolv.conf"))
        expect("swap is zram, compressed with zstd", "zram" in out("swapon --noheadings --show=NAME") and "[zstd]" in out("cat /sys/block/zram0/comp_algorithm"),
               out("swapon --show; cat /sys/block/zram0/comp_algorithm"))

        gone = out("for p in wpa_supplicant sudo btrfs-progs f2fs-tools; do xbps-query $p >/dev/null 2>&1 && echo $p; done; true")
        expect("what this machine does not need is gone", gone == "", gone)
        here = out("for c in mango foot doas git iwctl limine zramen; do command -v $c >/dev/null || echo missing-$c; done; true")
        expect("mango, a terminal, doas, git and iwd are there", here == "", here)
        expect("mango finds all its libraries", out("ldd /usr/bin/mango | grep -c 'not found'") == "0", out("ldd /usr/bin/mango | grep 'not found'"))
        expect("mango's own default config is in place", out("grep -c '^bind=Alt,Return,spawn,foot' /etc/mango/config.conf") == "1", out("grep -n 'spawn,foot' /etc/mango/config.conf"))
        expect("doas is for wheel", out("cat /etc/doas.conf") == "permit :wheel" and out("stat -c %a /etc/doas.conf") == "400", out("cat /etc/doas.conf"))

        wifi = f"/var/lib/iwd/{WIFI_SSID}.psk"
        expect("the Wi-Fi network is saved for iwd, readable by root alone",
               out(f"cat '{wifi}'") == f"[Security]\nPassphrase={WIFI_PASSPHRASE}" and out(f"stat -c %a '{wifi}'") == "600" and out("stat -c %a /var/lib/iwd") == "700",
               out(f"ls -la /var/lib/iwd; cat '{wifi}'"))
        expect("iwd configures the network itself", "EnableNetworkConfiguration=true" in out("cat /etc/iwd/main.conf"), out("cat /etc/iwd/main.conf"))

        kernel = out("uname -r")
        menu = out("cat /boot/limine.conf")
        entries = re.findall(r"(?m)^/Void (\S+)$", menu)
        expect("the boot menu's first entry is the running kernel", entries[:1] == [kernel] and "timeout: 1" in menu, menu[:400])
        expect("the firmware has an entry for Limine", "Limine" in out("efibootmgr"), out("efibootmgr"))
        size = out("du -m /boot/initramfs-*.img | cut -f1")
        expect("the initramfs holds this machine's drivers only", size.isdigit() and int(size) <= 40, f"{size} MiB")
        expect("the package cache is empty", out("ls /var/cache/xbps | wc -l") == "0", out("du -sh /var/cache/xbps"))
        expect("the repositories are the mirror that was used", "repo-de.voidlinux.org/current" in out("cat /etc/xbps.d/00-repository-main.conf"), out("cat /etc/xbps.d/*.conf"))
        expect("resolv.conf is the installed system's own, not a copy of the live one", "resolvconf" in out("head -n 2 /etc/resolv.conf"), out("cat /etc/resolv.conf"))

        # what an idle machine uses: not checked, only shown
        self.note("kernel " + kernel + ", initramfs " + size + " MiB")
        self.note(out("free -m | awk '/^Mem/ {print \"memory used: \" $3 \" MiB of \" $2}'"))
        self.note("packages: " + out("xbps-query -l | wc -l") + ", processes: " + out("ps -e --no-headers | wc -l") + ", / holds " + out("du -sxm / 2>/dev/null | cut -f1") + " MiB")

    def go(self):
        try:
            self.boot_live()
            self.install()
            self.boot_disk()
            self.check()
        except Failed as e:
            self.expect("the run got to its end", False, str(e)[:300])
            print(str(e), flush=True)
        finally:
            if self.vm:
                self.vm.kill()
        failed = [r for r in self.results if not r[0]]
        with open(os.path.join(self.o.work, "summary.md"), "w") as f:
            f.write(f"{len(self.results) - len(failed)} passed, {len(failed)} failed\n\n")
            for ok, name, detail in self.results:
                f.write(f"- {'ok' if ok else 'FAIL'}: {name}" + (f" [{detail}]" if not ok else "") + "\n")
            for note in self.notes:
                f.write(f"- note: {note}\n")
        print(f"\n{len(self.results) - len(failed)} passed, {len(failed)} failed", flush=True)
        return 1 if failed else 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--iso", required=True)
    p.add_argument("--work", default="vm-work")
    p.add_argument("--raw", help="also fetch install.sh from this address, as the README says, and compare")
    p.add_argument("--disk-bus", choices=["nvme", "virtio"], default="nvme")
    p.add_argument("--disk-size", default="40G")
    p.add_argument("--memory", type=int, default=4096)
    p.add_argument("--cpus", type=int, default=4)
    p.add_argument("--boot-timeout", type=int, default=600)
    p.add_argument("--install-timeout", type=int, default=3000)
    sys.exit(Run(p.parse_args()).go())


if __name__ == "__main__":
    main()
