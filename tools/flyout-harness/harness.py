#!/usr/bin/env python3
"""Flyout verification harness driver (Phase 7.2.0). See README.md.

    harness.py states [--set NAME | --vary d1,d2] [--fix dim=value]...
    harness.py run    [selection flags] [--settle-ms N] [--noise-mask]
                      [--crop x,y,w,h] [--pad PX] [--keep-full] [--label L]
                      [--timeout S] [--expected FILE] [--no-daemon-mgmt]
    harness.py report RUN_DIR [--expected FILE]
    harness.py compare RUN_A RUN_B      (exit 3 if coordinates differ)

`run` = stop the real daemon (if active) -> own its bus name with the fake
-> open the popup via the probe -> for each state: set Amp1 properties,
set UiState, bump Seq, wait for the probe's journald dump, screenshot,
crop -> restore everything -> analyze.
"""

import argparse
import datetime as dt
import json
import os
import queue
import shutil
import signal
import subprocess
import sys
import threading
import time

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import analyze  # noqa: E402
import fakeamp  # noqa: E402
import scenarios  # noqa: E402

DAEMON_UNIT = "devialet-remote-daemon.service"
TAG = "[FlyoutProbe] "
RUNS_DIR = os.path.join(HERE, "runs")


class ProbeTimeout(RuntimeError):
    pass


class Journal:
    """Follows plasmashell's journal and queues parsed [FlyoutProbe] records."""

    def __init__(self):
        self.q = queue.Queue()
        self.raw_count = 0
        self.proc = subprocess.Popen(
            ["journalctl", "--user", "-f", "-o", "cat", "-n", "0", "_COMM=plasmashell"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        self.thread = threading.Thread(target=self._reader, daemon=True, name="journal")
        self.thread.start()

    def _reader(self):
        for line in iter(self.proc.stdout.readline, ""):
            i = line.find(TAG)
            if i < 0:
                continue
            payload = line[i + len(TAG):].strip()
            self.raw_count += 1
            if payload.startswith("{"):
                try:
                    self.q.put(json.loads(payload))
                    continue
                except json.JSONDecodeError:
                    pass
            self.q.put({"type": "text", "text": payload})

    def wait_dump(self, state, seq, timeout):
        deadline = time.monotonic() + timeout
        collecting = False
        dump = {"begin": None, "items": [], "windows": [], "end": None, "text": []}
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProbeTimeout(f"no probe dump for state={state} seq={seq} within {timeout}s")
            try:
                rec = self.q.get(timeout=remaining)
            except queue.Empty:
                continue
            t = rec.get("type")
            if t == "begin":
                if rec.get("state") == state and rec.get("seq") == seq:
                    collecting = True
                    dump["begin"] = rec
                else:
                    collecting = False  # stale dump from an earlier seq
            elif t == "text":
                dump["text"].append(rec["text"])
            elif collecting and t == "item":
                dump["items"].append(rec)
            elif collecting and t == "window":
                dump["windows"].append(rec)
            elif collecting and t == "end" and rec.get("state") == state and rec.get("seq") == seq:
                dump["end"] = rec
                return dump

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()


# ---- systemd daemon management ------------------------------------------
def daemon_active():
    r = subprocess.run(["systemctl", "--user", "is-active", DAEMON_UNIT], capture_output=True, text=True)
    return r.stdout.strip() == "active"


def daemon_ctl(verb):
    subprocess.run(["systemctl", "--user", verb, DAEMON_UNIT], check=True)


def wait_name_free(name, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if fakeamp.name_owner(name) is None:
            return True
        time.sleep(0.1)
    return False


# ---- popup size keys (KConfig collision, Phase 7.1.0/7.2.0) --------------
APPLETSRC = os.path.expanduser("~/.config/plasma-org.kde.plasma.desktop-appletsrc")
PLUGIN_ID = "com.ekmanch.devialetremote"
SIZE_KEYS = ("popupWidth", "popupHeight")


def applet_config_groups():
    """kwriteconfig6-style group chains for every instance of this applet,
    e.g. ['Containments', '46', 'Applets', '128', 'Configuration']."""
    groups = []
    try:
        with open(APPLETSRC, encoding="utf-8") as f:
            current = None
            for line in f:
                line = line.strip()
                if line.startswith("["):
                    current = [seg.strip("[]") for seg in line[1:-1].split("][")]
                elif line == f"plugin={PLUGIN_ID}" and current is not None:
                    groups.append(current + ["Configuration"])
    except OSError:
        pass
    return groups


def _kconfig(args_list):
    r = subprocess.run(args_list, capture_output=True, text=True)
    return r.stdout.strip()


def read_size_keys():
    """{group-chain-string: {key: value-or-None}} for every applet instance."""
    out = {}
    for g in applet_config_groups():
        gargs = [a for seg in g for a in ("--group", seg)]
        vals = {}
        for k in SIZE_KEYS:
            v = _kconfig(["kreadconfig6", "--file", os.path.basename(APPLETSRC)] + gargs + ["--key", k])
            vals[k] = v if v != "" else None
        out["/".join(g)] = vals
    return out


def restore_size_keys(snapshot):
    """Put popupWidth/popupHeight back exactly as they were before the run.

    libplasma 6.7.4 AppletPopup::hideEvent() writes both keys unconditionally
    on every close when appletInterface is set (read from appletpopup.cpp,
    confirmed empirically in Phase 7.2.0: keys absent before a run, 324x180
    after, with no resize). FlyoutPopup and the shell's real flyout share
    the same applet config group until Phase 7.8.0's cutover, and the real
    popup applies these keys when it is constructed (setAppletInterface ->
    m_sizeExplicitlySetFromConfig -> resize), so a harness run would
    otherwise leave the real flyout truncated to the spike's size after the
    next plasmashell restart."""
    changed = []
    for gkey, vals in snapshot.items():
        gargs = [a for seg in gkey.split("/") for a in ("--group", seg)]
        for k, v in vals.items():
            base = ["kwriteconfig6", "--file", os.path.basename(APPLETSRC)] + gargs + ["--key", k]
            if v is None:
                subprocess.run(base + ["--delete"], check=False)
            else:
                subprocess.run(base + [v], check=False)
        now = read_size_keys().get(gkey)
        if now != vals:
            changed.append((gkey, vals, now))
    return changed


# ---- capture --------------------------------------------------------------
def capture(path):
    # QT_QPA_PLATFORM=wayland is load-bearing: launched from a non-interactive
    # shell in this Wayland session, spectacle otherwise picks the xcb
    # backend and an XWayland grab of a Wayland session is a fully
    # transparent 3840x2160 image with exit code 0 (found in the first
    # Phase 7.2.0 smoke run). The alpha check below turns that silent
    # failure mode into a hard error should it ever recur.
    env = dict(os.environ)
    if env.get("XDG_SESSION_TYPE", "wayland") == "wayland":
        env["QT_QPA_PLATFORM"] = "wayland"
    r = subprocess.run(["spectacle", "-b", "-n", "-f", "-o", path], capture_output=True, text=True, timeout=30, env=env)
    if r.returncode != 0 or not os.path.exists(path):
        raise RuntimeError(f"spectacle failed (rc={r.returncode}): {r.stderr.strip()[-300:]}")
    im = Image.open(path)
    if im.mode == "RGBA" and im.getchannel("A").getextrema()[1] == 0:
        raise RuntimeError(f"spectacle wrote a fully transparent image ({path}) - capture backend problem, see README")


def crop_box_from_dump(dump, pad, size):
    """Crop to the mainItem rectangle (window position + the root item's
    window-relative offset), not the whole popup window: the theme frame's
    antialiased rounded corners and bottom edge let the desktop behind the
    popup bleed through, which showed up as ~150 differing pixels in a
    same-state control capture. The frame never changes with state, so
    excluding it loses nothing the harness is for."""
    begin = dump["begin"]
    dpr = float(begin.get("dpr") or 1.0)
    w = begin["win"]
    if not w.get("visible") or w["w"] <= 0 or w["h"] <= 0:
        return None
    root = next((it for it in dump.get("items", []) if it.get("path") == "root"), None)
    if root is not None and root["w"] > 0 and root["h"] > 0:
        rx, ry, rw, rh = w["x"] + root["wx"], w["y"] + root["wy"], root["w"], root["h"]
    else:
        rx, ry, rw, rh = w["x"], w["y"], w["w"], w["h"]
    x0 = int(round(rx * dpr)) - pad
    y0 = int(round(ry * dpr)) - pad
    x1 = int(round((rx + rw) * dpr)) + pad
    y1 = int(round((ry + rh) * dpr)) + pad
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(size[0], x1), min(size[1], y1)
    if x1 - x0 <= 0 or y1 - y0 <= 0:
        return None
    return [x0, y0, x1, y1]


def crop_file(src, dst, box):
    im = Image.open(src)
    im.crop(tuple(box)).save(dst)


# ---- snapshot validation --------------------------------------------------
def snapshot_mismatch(begin, props):
    snap = begin.get("amp") or {}
    problems = []
    if snap.get("AmpIp") is not None and snap["AmpIp"] != props["AmpIp"]:
        problems.append(f"AmpIp {snap['AmpIp']!r} != {props['AmpIp']!r}")
    if snap.get("VolumeDb") is not None and abs(float(snap["VolumeDb"]) - float(props["VolumeDb"])) > 1e-6:
        problems.append(f"VolumeDb {snap['VolumeDb']} != {props['VolumeDb']}")
    if snap.get("PowerState") is not None and snap["PowerState"] != props["PowerState"]:
        problems.append(f"PowerState {snap['PowerState']!r} != {props['PowerState']!r}")
    if snap.get("KnownAmpsLen") is not None and snap["KnownAmpsLen"] != len(props["KnownAmps"]):
        problems.append(f"KnownAmps len {snap['KnownAmpsLen']} != {len(props['KnownAmps'])}")
    return problems


# ---- CLI ------------------------------------------------------------------
def add_selection_args(ap):
    ap.add_argument("--set", dest="set_name", choices=sorted(scenarios.SETS), help="named state set (default: smoke)")
    ap.add_argument("--vary", help="comma-separated dims to vary, others held at BASE")
    ap.add_argument("--fix", action="append", default=[], metavar="DIM=VALUE", help="keep only states with this value")


def resolve_selection(args):
    vary = args.vary.split(",") if args.vary else None
    fixes = dict(kv.split("=", 1) for kv in args.fix)
    states = scenarios.select(args.set_name, vary, fixes)
    desc = f"--set {args.set_name}" if args.set_name else (f"--vary {args.vary}" if args.vary else "--set smoke")
    if fixes:
        desc += " " + " ".join(f"--fix {k}={v}" for k, v in fixes.items())
    return states, desc


def cmd_states(args):
    states, desc = resolve_selection(args)
    if args.json:
        print(json.dumps(states, indent=1))
    else:
        for s in states:
            print(s["id"])
        print(f"# {len(states)} state(s) for {desc}; {len(scenarios.adjacent_pairs(states))} single-dimension pair(s)", file=sys.stderr)
    return 0


def log(msg):
    print(f"[{dt.datetime.now():%H:%M:%S}] {msg}", flush=True)


def cmd_run(args):
    states, desc = resolve_selection(args)
    if not states:
        log("no states selected")
        return 2
    if shutil.which("spectacle") is None:
        log("spectacle not found on PATH")
        return 2
    plasmashell = subprocess.run(["pgrep", "-x", "plasmashell"], capture_output=True, text=True).stdout.split()
    if not plasmashell:
        log("plasmashell is not running")
        return 2

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = os.path.join(RUNS_DIR, stamp + (f"-{args.label}" if args.label else ""))
    shots, coords = os.path.join(run_dir, "shots"), os.path.join(run_dir, "coords")
    os.makedirs(shots)
    os.makedirs(coords)
    for st in states:
        st["captures"] = [st["id"]]
    run_info = {
        "started": dt.datetime.now().isoformat(timespec="seconds"), "selection": desc, "settle_ms": args.settle_ms,
        "noise_mask": args.noise_mask, "pad": args.pad, "crop": None, "crop_source": None, "timings": {},
        "warnings": [], "daemon_was_active": None, "plasmashell_pids": plasmashell,
    }
    log(f"run dir {run_dir}; {len(states)} state(s) for {desc}")

    def save_run_info():
        with open(os.path.join(run_dir, "run.json"), "w", encoding="utf-8") as f:
            json.dump(run_info, f, indent=1)
        with open(os.path.join(run_dir, "states.json"), "w", encoding="utf-8") as f:
            json.dump(states, f, indent=1)

    save_run_info()

    # SIGTERM -> KeyboardInterrupt so the finally block always runs.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))

    fake = None
    journal = None
    daemon_was_active = False
    size_keys_before = read_size_keys()
    run_info["size_keys_before"] = size_keys_before
    log(f"popup size keys before run: {size_keys_before}")
    crop = [int(v) for v in args.crop.split(",")] if args.crop else None
    if crop:
        crop = [crop[0], crop[1], crop[0] + crop[2], crop[1] + crop[3]]
        run_info["crop_source"] = "--crop"
    seq = 0
    exit_code = 1
    try:
        if not args.no_daemon_mgmt:
            daemon_was_active = daemon_active()
            run_info["daemon_was_active"] = daemon_was_active
            if daemon_was_active:
                log(f"stopping {DAEMON_UNIT} (will be restarted on exit)")
                daemon_ctl("stop")
                if not wait_name_free(fakeamp.AMP_NAME):
                    raise RuntimeError(f"{fakeamp.AMP_NAME} still owned after stopping the unit")
        owner = fakeamp.name_owner(fakeamp.AMP_NAME)
        if owner is not None:
            raise RuntimeError(f"{fakeamp.AMP_NAME} is owned by {owner} (a foreground daemon?) - stop it first")

        journal = Journal()
        fake = fakeamp.FakeAmp(log=log)
        fake.start()

        closed_shot = os.path.join(run_dir, "_closed_full.png")
        capture(closed_shot)
        screen_size = Image.open(closed_shot).size
        log(f"screen {screen_size[0]}x{screen_size[1]} (popup-closed reference saved)")

        fake.set_ctl(SettleMs=args.settle_ms, PopupOpen=True)
        time.sleep(0.8)

        def run_capture(st, cid):
            nonlocal seq, crop
            t0 = time.monotonic()
            fake.set_amp(st["props"])
            fake.set_ctl(UiState=st["ui"])
            dump = None
            for attempt in (1, 2):
                seq += 1
                fake.set_ctl(StateId=cid, Seq=seq)
                try:
                    dump = journal.wait_dump(cid, seq, args.timeout)
                    break
                except ProbeTimeout as e:
                    if attempt == 2:
                        raise ProbeTimeout(
                            f"{e}\n  hints: is main.qml's appletPopupSpikeEnabled true and the plasmoid reloaded "
                            f"(kpackagetool6 --upgrade + plasmashell --replace)? Did the popup open? "
                            f"journal saw {journal.raw_count} [FlyoutProbe] lines so far.") from None
                    log(f"  probe timeout for {cid}, retrying once with a new Seq")
            if fake.name_lost.is_set():
                raise RuntimeError("lost a bus name mid-run (another owner appeared) - aborting")
            begin = dump["begin"]
            if not begin["win"].get("visible"):
                raise RuntimeError(f"{cid}: popup window is not visible - PopupOpen was not honoured")
            problems = snapshot_mismatch(begin, st["props"])
            if problems:
                raise RuntimeError(f"{cid}: state did not reach the widget: {problems}")
            if dump["end"]["count"] != len(dump["items"]):
                run_info["warnings"].append(f"{cid}: probe logged {dump['end']['count']} items, parsed {len(dump['items'])}")
            for w in begin.get("uiWarnings") or []:
                if w not in run_info["warnings"]:
                    run_info["warnings"].append(f"{cid}: {w}")
            with open(os.path.join(coords, cid + ".json"), "w", encoding="utf-8") as f:
                json.dump(dump, f)

            full_path = os.path.join(shots, cid + ".full.png")
            capture(full_path)
            if crop is None:
                crop = crop_box_from_dump(dump, args.pad, screen_size)
                if crop is None:
                    raise RuntimeError(f"cannot derive a crop box from popup geometry {begin['win']} (dpr {begin.get('dpr')}); pass --crop x,y,w,h")
                run_info["crop"] = crop
                run_info["crop_source"] = "probe mainItem rect (window pos + root offset) x dpr"
                log(f"crop box {crop} from mainItem rect inside popup {begin['win']} @ dpr {begin.get('dpr')}")
            crop_file(full_path, os.path.join(shots, cid + ".png"), crop)
            if not args.keep_full:
                os.remove(full_path)
            run_info["timings"][cid] = round(time.monotonic() - t0, 3)
            log(f"  {cid}: {len(dump['items'])} items, win {begin['win']['w']}x{begin['win']['h']}, {run_info['timings'][cid]}s")

        for idx, st in enumerate(states):
            log(f"[{idx + 1}/{len(states)}] {st['id']}")
            run_capture(st, st["id"])
            if idx == 0 or args.noise_mask:
                ccid = st["id"] + "__control"
                st["captures"].append(ccid)
                run_capture(st, ccid)
            save_run_info()

        run_info["finished"] = dt.datetime.now().isoformat(timespec="seconds")
        if run_info["timings"]:
            run_info["avg_state_seconds"] = round(sum(run_info["timings"].values()) / len(run_info["timings"]), 2)
        exit_code = 0
    except KeyboardInterrupt:
        log("interrupted")
        run_info["warnings"].append("run interrupted")
    except Exception as e:  # noqa: BLE001
        log(f"ERROR: {e}")
        run_info["warnings"].append(f"aborted: {e}")
    finally:
        save_run_info()
        if fake is not None:
            try:
                fake.set_ctl(PopupOpen=False)
                time.sleep(0.2)
            except Exception as e:  # noqa: BLE001
                log(f"could not close popup: {e}")
            fake.stop()
        if journal is not None:
            journal.close()
        after = read_size_keys()
        if after != size_keys_before:
            log(f"popup size keys rewritten by the popup's hideEvent ({after}) - restoring pre-run values")
            problems = restore_size_keys(size_keys_before)
            run_info["size_keys_restored"] = not problems
            if problems:
                log(f"FAILED to restore popup size keys: {problems} - fix by hand with kwriteconfig6 before the next plasmashell restart")
            else:
                log(f"popup size keys restored: {read_size_keys()}")
        if daemon_was_active and not args.no_daemon_mgmt:
            log(f"restarting {DAEMON_UNIT}")
            try:
                daemon_ctl("start")
                time.sleep(0.5)
                log(f"{DAEMON_UNIT}: {'active' if daemon_active() else 'NOT active - check systemctl --user status'}")
            except Exception as e:  # noqa: BLE001
                log(f"FAILED to restart {DAEMON_UNIT}: {e}")

    if exit_code == 0 and not args.no_report:
        summ = analyze.run(run_dir, args.expected)
        log(f"report: {os.path.join(run_dir, 'report.md')} -> exit {summ['exit_code']} "
            f"(control_unstable={summ['control_unstable']}, unexpected_moves={len(summ['unexpected_moves'])}, warnings={len(summ['warnings'])})")
        return summ["exit_code"]
    return exit_code


def cmd_compare(args):
    r = analyze.compare_runs(args.run_a, args.run_b)
    log(f"{r['common']} common capture(s) (only in a: {r['only_a']}, only in b: {r['only_b']})")
    for cid, moves in r["diffs"].items():
        log(f"  {cid}: {len(moves)} element(s) differ")
        for mv in moves[:10]:
            log(f"    {mv['key']}: {mv['kind']}" + (f" dx={mv['dx']} dy={mv['dy']} dw={mv['dw']} dh={mv['dh']}" if mv["kind"] == "moved" else ""))
    for cid, g in r["geometry_diffs"].items():
        log(f"  {cid}: window geometry differs {g[0]} vs {g[1]}")
    log("IDENTICAL coordinates across both runs" if r["identical"] else "coordinates DIFFER between runs")
    return 0 if r["identical"] else 3


def cmd_report(args):
    summ = analyze.run(args.run_dir, args.expected)
    log(f"report: {os.path.join(args.run_dir, 'report.md')} -> exit {summ['exit_code']}")
    return summ["exit_code"]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    ps = sub.add_parser("states", help="list the resolved states without running anything")
    add_selection_args(ps)
    ps.add_argument("--json", action="store_true")
    ps.set_defaults(fn=cmd_states)

    pr = sub.add_parser("run", help="drive the popup through the selected states and capture")
    add_selection_args(pr)
    pr.add_argument("--settle-ms", type=int, default=600)
    pr.add_argument("--noise-mask", action="store_true", help="capture every state twice (self-noise mask)")
    pr.add_argument("--crop", help="physical px x,y,w,h override for the popup crop")
    # Default 0: the popup window rectangle already contains its frame, and
    # any padding lets the desktop behind the popup's shadow into the
    # crop - the first smoke run's control capture showed ~8k differing
    # pixels there (the terminal scrolling this run's own log).
    pr.add_argument("--pad", type=int, default=0, help="crop padding in physical px (default 0)")
    pr.add_argument("--keep-full", action="store_true", help="keep full-screen PNGs")
    pr.add_argument("--label", help="suffix for the run directory name")
    pr.add_argument("--timeout", type=float, default=5.0, help="seconds to wait for each probe dump")
    pr.add_argument("--expected", help="expected.json allowlist for analyze")
    pr.add_argument("--no-daemon-mgmt", action="store_true", help="do not stop/restart the systemd daemon unit")
    pr.add_argument("--no-report", action="store_true")
    pr.set_defaults(fn=cmd_run)

    pc = sub.add_parser("compare", help="coordinate diff of the captures two runs share (run-to-run stability, settle-floor check)")
    pc.add_argument("run_a")
    pc.add_argument("run_b")
    pc.set_defaults(fn=cmd_compare)

    pp = sub.add_parser("report", help="re-analyze an existing run directory")
    pp.add_argument("run_dir")
    pp.add_argument("--expected")
    pp.set_defaults(fn=cmd_report)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
