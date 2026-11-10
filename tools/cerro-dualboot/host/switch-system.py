#!/usr/bin/env python3
"""Host-controlled Cerro same-slot boot/dtbo swap. No GPT slot changes."""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import fcntl
import glob
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
DEFAULT_IMAGE = ROOT / "build/dualboot/linux-waydroid-c1-daily.img"
DEFAULT_SHA = "18886d05c015d60d5daf15ac76485a48ac2c16f684d837253c77ebc8b0ce535a"
KINDS = ("boot", "dtbo")


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def digest(path):
    with Path(path).open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def zero_digest(size):
    h = hashlib.sha256()
    chunk = bytes(1024 * 1024)
    while size:
        n = min(size, len(chunk))
        h.update(chunk[:n])
        size -= n
    return h.hexdigest()


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix(".tmp")
    with tmp.open("w") as f:
        os.chmod(tmp, 0o600)
        json.dump(value, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    tmp.replace(path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Phone:
    def __init__(self, serial, mode):
        self.serial, self.mode = serial, mode
        self.base = "/dev/block/by-name" if mode == "android" else "/dev/disk/by-partlabel"

    def adb(self, *args, **kwargs):
        return subprocess.run(["adb", "-s", self.serial, *args], check=True,
                              timeout=120, **kwargs)

    def root(self):
        if self.mode == "android":
            if self.run("id -u") != "0":
                self.adb("root", stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                self.adb("wait-for-device", stdout=subprocess.PIPE)
            require(self.run("id -u") == "0", "ADB root unavailable; no partitions written")

    def run(self, command, timeout=150):
        if self.mode == "android":
            return self.adb("shell", "sh", "-c", shlex.quote(command),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True).stdout.strip()
        # Encode the response to avoid serial-console echo/wrapping ambiguity.
        token = "SWAP_" + uuid.uuid4().hex
        wrapped = ("p=$(mktemp); (" + command + ") >\"$p\" 2>&1; r=$?; "
                   "printf '\\n" + token + "_BEGIN\\n'; base64 \"$p\"; "
                   "printf '" + token + "_END\\n'; rm -f \"$p\"; exit \"$r\"")
        r = subprocess.run([sys.executable, str(ROOT / "tools/cerro-acm-run.py"),
                            "--sudo", "--command-timeout", str(timeout), wrapped],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, timeout=timeout + 35)
        clean = r.stdout.replace("\r", "")
        match = re.search(r"^" + token + r"_BEGIN\n(.*?)^" + token + r"_END$",
                          clean, re.M | re.S)
        require(match is not None, "ACM response missing; " + r.stderr.strip())
        output = base64.b64decode(match[1]).decode("utf-8", "replace").strip()
        require(r.returncode == 0, "Phone command failed: " + output)
        return output

    def part(self, kind, slot):
        require(kind in KINDS and slot in ("a", "b"), "Invalid partition")
        return f"{self.base}/{kind}_{slot}"

    def sha(self, path):
        value = self.run("sha256sum " + shlex.quote(str(path))).split()[0]
        require(re.fullmatch("[0-9a-f]{64}", value), "Invalid SHA response")
        return value

    def info(self):
        if self.mode == "android":
            slot = self.run("getprop ro.boot.slot_suffix").removeprefix("_")
            label = "PenguinAOSP-" + self.run("getprop ro.build.fingerprint")
        else:
            cur = self.run("/usr/bin/qbootctl -c; /usr/bin/qbootctl -a")
            slots = re.findall(r"slot: _([ab])", cur, re.I)
            require(len(slots) == 2 and slots[0] == slots[1], "Current/active slot disagree: " + cur)
            slot, label = slots[0], "Cerro-Linux"
        require(slot in ("a", "b"), "Unknown slot: " + slot)
        commands = ["cat /proc/sys/kernel/random/boot_id",
                    "blkid " + self.base + "/cerro_linux"]
        for s in ("a", "b"):
            for k in KINDS:
                p = self.part(k, s)
                commands.extend(["blockdev --getsize64 " + p, "sha256sum " + p])
        lines = self.run(" && ".join(commands)).splitlines()
        require(len(lines) == 10, "Incomplete device snapshot")
        root_uuid = re.search(r'UUID="([^"]+)"', lines[1])
        require(root_uuid is not None, "Linux rootfs UUID unavailable")
        parts = {}
        for i, (s, k) in enumerate((s, k) for s in ("a", "b") for k in KINDS):
            parts[f"{k}_{s}"] = {"size": int(lines[2 + i * 2]),
                                  "sha": lines[3 + i * 2].split()[0]}
        return {"mode": self.mode, "slot": slot, "boot_id": lines[0],
                "root_uuid": root_uuid[1], "label": label, "parts": parts}

    def pull_part(self, kind, slot, path):
        require(self.mode == "android", "Full backup requires Android ADB root")
        with Path(path).open("xb") as out:
            self.adb("exec-out", "cat", self.part(kind, slot), stdout=out)
            out.flush()
            os.fsync(out.fileno())

    def push(self, path):
        remote = "/data/local/tmp/cerro-linux-" + digest(path)[:16] + ".img"
        self.adb("push", str(path), remote, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        require(self.sha(remote) == digest(path), "Uploaded image SHA mismatch")
        return remote

    def copy(self, source, target):
        self.run(f"dd if={source} of={target} bs=4194304 conv=fsync && sync")

    def zero(self, target, size):
        require(size % 1048576 == 0, "dtbo size must be a whole MiB")
        self.run(f"dd if=/dev/zero of={target} bs=1048576 count={size // 1048576} conv=fsync && sync")

    def reboot(self):
        if self.mode == "android":
            self.adb("reboot", stdout=subprocess.PIPE)
        else:
            self.run("sync; nohup sh -c 'sleep 2; /sbin/reboot' >/dev/null 2>&1 </dev/null &")


def detect(serial):
    r = subprocess.run(["adb", "devices"], capture_output=True, text=True, timeout=8)
    if any(line.split()[:2] == [serial, "device"] for line in r.stdout.splitlines()):
        return Phone(serial, "android")
    if glob.glob("/dev/serial/by-id/*nubia*cerro-debug-if00"):
        return Phone(serial, "linux")
    raise RuntimeError("No authorized Android ADB or Cerro Linux ACM; keep USB connected")


def resolve_serial(explicit, state_dir):
    if explicit:
        return explicit
    r = subprocess.run(["adb", "devices", "-l"], capture_output=True, text=True, timeout=8)
    candidates = [line.split()[0] for line in r.stdout.splitlines()
                  if len(line.split()) > 2 and line.split()[1] == "device"
                  and "device:PQ83A01" in line]
    if len(candidates) == 1:
        return candidates[0]
    manifests = list(Path(state_dir).glob("*/state.json"))
    require(not candidates and len(manifests) == 1,
            "Cannot uniquely identify Cerro; pass --serial ADB_SERIAL")
    return json.loads(manifests[0].read_text())["serial"]


class Swap:
    def __init__(self, phone, state_path):
        self.phone, self.state_path = phone, Path(state_path)
        self.state = json.loads(self.state_path.read_text()) if self.state_path.exists() else None

    def phase(self, value):
        self.state["phase"] = value
        atomic_json(self.state_path, self.state)
        print("Checkpoint: " + value, flush=True)

    def check_identity(self, info):
        require(self.state is not None, "No saved swap manifest; refusing to guess Android backup")
        require(self.state["serial"] == self.phone.serial, "ADB serial differs from saved manifest")
        require(self.state["cache_slot"] in ("a", "b") and self.state["cache_slot"] != self.state["slot"],
                "Invalid cache slot in saved manifest")
        for key in ("slot", "root_uuid"):
            require(info[key] == self.state[key], f"Device {key} differs from saved manifest")

    def expect(self, path, sha):
        require(self.phone.sha(path) == sha, "Partition readback mismatch: " + str(path))

    def backup(self, info):
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        run_dir = self.state_path.parent / stamp
        run_dir.mkdir(parents=True, mode=0o700)
        for slot in ("a", "b"):
            role = "PenguinAOSP_active_before_linux" if slot == info["slot"] else "inactive_before_backup_copy"
            folder = run_dir / f"slot_{slot}_{role}"
            folder.mkdir(mode=0o700)
            (folder / "LABEL.txt").write_text(info["label"] + "\nrole=" + role + "\n")
            sums = []
            for kind in KINDS:
                p = folder / f"{kind}_{slot}.img"
                self.phone.pull_part(kind, slot, p)
                expected = info["parts"][f"{kind}_{slot}"]
                require(p.stat().st_size == expected["size"], "Short partition backup: " + str(p))
                require(digest(p) == expected["sha"], "Backup SHA mismatch: " + str(p))
                sums.append(f"{expected['sha']}  {p.name}\n")
            (folder / "SHA256SUMS").write_text("".join(sums))
        atomic_json(run_dir / "before.json", info)
        return run_dir

    def to_linux(self, image, image_sha, dry_run=False):
        p = self.phone
        require(p.mode == "android", "Already running Linux; Android backup will not be overwritten")
        require(Path(image).stat().st_size == 100663296, "Linux boot must be padded to96MiB")
        require(digest(image) == image_sha, "Linux image SHA mismatch")
        info = p.info()
        slot = info["slot"]
        other = "b" if slot == "a" else "a"
        boot, dtbo = (info["parts"][f"{k}_{slot}"] for k in KINDS)
        require(boot["size"] == Path(image).stat().st_size, "Boot partition size mismatch")
        require(boot["sha"] != image_sha and dtbo["sha"] != zero_digest(dtbo["size"]),
                "Active boot/dtbo already prepared for Linux; refusing to overwrite Android cache")
        print(f"Android active={slot}; cache Android boot/dtbo in {other}; replace active {slot}; no set_active", flush=True)
        if dry_run:
            return info
        run_dir = self.backup(info)
        remote_image = p.push(image)
        # Revalidate after the full host backup/upload, before the first write.
        require(p.info() == info, "Device changed during backup; no partitions written")
        self.state = {"serial": p.serial, "slot": slot, "cache_slot": other,
                      "root_uuid": info["root_uuid"], "android_boot": boot["sha"],
                      "android_dtbo": dtbo["sha"], "linux_boot": image_sha,
                      "dtbo_size": dtbo["size"], "backup_dir": str(run_dir),
                      "before_boot_id": info["boot_id"]}
        self.phase("prepared")
        for kind, sha in (("boot", boot["sha"]), ("dtbo", dtbo["sha"])):
            p.copy(p.part(kind, slot), p.part(kind, other))
            self.expect(p.part(kind, other), sha)
        self.phase("android_cache_verified")
        p.zero(p.part("dtbo", slot), dtbo["size"])
        self.expect(p.part("dtbo", slot), zero_digest(dtbo["size"]))
        self.phase("active_dtbo_zero")
        p.copy(remote_image, p.part("boot", slot))
        self.expect(p.part("boot", slot), image_sha)
        self.check_ready(p.info(), "linux")
        self.phase("linux_ready")
        p.reboot()
        return info

    def check_ready(self, info, target):
        self.check_identity(info)
        s, other = self.state["slot"], self.state["cache_slot"]
        self.check_cache(info)
        wanted = {"boot": self.state["linux_boot"], "dtbo": zero_digest(self.state["dtbo_size"])} if target == "linux" else {
            "boot": self.state["android_boot"], "dtbo": self.state["android_dtbo"]}
        for kind, sha in wanted.items():
            require(info["parts"][f"{kind}_{s}"]["sha"] == sha, "Active partition mismatch: " + kind)

    def check_cache(self, info):
        self.check_identity(info)
        other = self.state["cache_slot"]
        for kind in KINDS:
            require(info["parts"][f"{kind}_{other}"]["sha"] == self.state[f"android_{kind}"],
                    "Inactive Android cache damaged; refusing to continue")

    def to_android(self, dry_run=False):
        p = self.phone
        info = p.info()
        self.check_identity(info)
        if p.mode == "android" and all(info["parts"][f"{k}_{info['slot']}"]["sha"] == self.state[f"android_{k}"] for k in KINDS):
            print("Android images already intact; no partitions changed", flush=True)
            if not dry_run:
                self.phase("android_booted")
            return None
        # Also recover an interrupted preparation while Android is still running.
        # Source identity + both cached hashes are mandatory before any restore.
        self.check_cache(info)
        print(f"Restore cached Android boot/dtbo from {self.state['cache_slot']} to active {info['slot']}; no set_active", flush=True)
        if dry_run:
            return info
        self.phase("restoring_android")
        for kind in ("dtbo", "boot"):
            p.copy(p.part(kind, self.state["cache_slot"]), p.part(kind, info["slot"]))
            self.expect(p.part(kind, info["slot"]), self.state[f"android_{kind}"])
        self.check_ready(p.info(), "android")
        self.phase("android_ready")
        p.reboot()
        return info


def observe(serial, target, swap, old_boot, seconds):
    deadline, last_report = time.monotonic() + seconds, 0
    last_error = "no control channel"
    while time.monotonic() < deadline:
        try:
            p = detect(serial)
            if p.mode == target:
                if target == "android":
                    require(p.run("getprop sys.boot_completed") == "1", "Android still booting")
                p.root()
                now = p.info()
                require(now["boot_id"] != old_boot, "Old boot still running")
                swap.check_ready(now, target)
                if target == "linux":
                    require("cerro_boot=" in p.run("cat /proc/cmdline"), "Missing Cerro Linux image marker")
                    p.run("/usr/bin/qbootctl -m")
                swap.phase(target + "_booted")
                atomic_json(Path(swap.state["backup_dir"]) / (target + "-observed.json"), now)
                print(f"Verified {target}: same slot {now['slot']}, new boot {now['boot_id']}", flush=True)
                return
        except (RuntimeError, subprocess.SubprocessError, OSError) as error:
            last_error = str(error)
        if time.monotonic() - last_report > 30:
            print("Observing boot: " + last_error, flush=True)
            last_report = time.monotonic()
        time.sleep(2)
    raise RuntimeError(f"Boot not confirmed after{seconds}s: {last_error}. No further writes or slot changes made.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("system", choices=("status", "linux", "android"))
    parser.add_argument("--serial", help="Defaults to the connected Cerro or the sole saved swap")
    parser.add_argument("--linux-boot", type=Path, default=DEFAULT_IMAGE)
    parser.add_argument("--linux-sha256", default=DEFAULT_SHA)
    parser.add_argument("--state-dir", type=Path, default=ROOT / "backups/dualboot-swap")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--observe-seconds", type=int, default=510)
    args = parser.parse_args()
    args.serial = resolve_serial(args.serial, args.state_dir)
    require(re.fullmatch(r"[A-Za-z0-9_-]+", args.serial), "Invalid serial")
    folder = args.state_dir.resolve() / args.serial
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (folder / "switch.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        phone = detect(args.serial)
        phone.root()
        swap = Swap(phone, folder / "state.json")
        if args.system == "status":
            print(json.dumps({"device": phone.info(), "saved_swap": swap.state}, indent=2))
            return
        pending = swap.state and swap.state.get("phase") not in ("android_booted", "linux_booted")
        if args.system == phone.mode and not (args.system == "android" and pending):
            print("Already running " + phone.mode + "; no partitions changed")
            return
        before = (swap.to_linux(args.linux_boot, args.linux_sha256, args.dry_run)
                  if args.system == "linux" else swap.to_android(args.dry_run))
        if not args.dry_run and before is not None:
            observe(args.serial, args.system, swap, before["boot_id"], args.observe_seconds)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print("STOP: " + str(error), file=sys.stderr)
        sys.exit(1)
