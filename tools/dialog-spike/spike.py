#!/usr/bin/env python3
"""Phase 7.9.0 Dialog spike driver - THROWAWAY (see TODO.md Phase 7.9.0).

    spike.py serve                # own the bus name; DialogSpikeDriver.qml loads
    spike.py cmd <command>        # run one command in the widget, print JSON result
    spike.py shot out.png [--crop X,Y,W,H]   # spectacle capture (wayland forced)
    spike.py kwin script.js [--wait S]       # load/run/unload a KWin script, print its output
    spike.py quit

Commands understood by DialogSpikeDriver.qml: open, close, dump, grow:true|false,
combo-open, combo-close, focus-combo, focus-text, focus-main, click-combo,
click-popup:N, click-inside, click-text, key:<Qt.Key int>, type:<text>,
clear-text, tooltip:on|off, set-type:tooltip|appletpopup.

Bus name is requested with DO_NOT_QUEUE (never taken from anyone, never
queued). The real daemon is untouched - this uses a separate name only.
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

NAME = "com.ekmanch.DevialetRemote.DialogSpike"
PATH = "/com/ekmanch/DevialetRemote/DialogSpike"
IFACE = "com.ekmanch.DevialetRemote.DialogSpike1"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
TAG = "[DialogSpike] "
XML = f"""<node><interface name="{IFACE}">
<method name="Send"><arg name="cmd" type="s" direction="in"/><arg name="result" type="s" direction="out"/></method>
<method name="Quit"/>
<property name="Command" type="s" access="read"/>
<property name="Seq" type="u" access="read"/>
</interface></node>"""


class Server:
    def __init__(self):
        self.command = ""
        self.seq = 0
        self.pending = None  # (seq, invocation, log_lines, timeout_id)
        self.lock = threading.Lock()
        self.loop = GLib.MainLoop()

    def start(self):
        self.conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        info = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
        self.conn.register_object(PATH, info, self.on_method, self.get_prop, None)
        reply = self.conn.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            GLib.Variant("(su)", (NAME, 4)), GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 2000, None).unpack()[0]
        if reply != 1:
            sys.exit(f"RequestName({NAME}) -> {reply}; another serve running?")
        self.journal = subprocess.Popen(
            ["journalctl", "--user", "-f", "-o", "cat", "-n", "0", "_COMM=plasmashell"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        threading.Thread(target=self.follow, daemon=True).start()
        print(f"serve: owning {NAME}", flush=True)
        self.loop.run()

    def follow(self):
        for line in self.journal.stdout:
            line = line.rstrip("\n")
            if TAG not in line:
                continue
            body = line[line.index(TAG) + len(TAG):]
            with self.lock:
                p = self.pending
                if p is None:
                    continue
                p[2].append(body)
                if body.startswith('{"type":"result"'):
                    try:
                        res = json.loads(body)
                    except json.JSONDecodeError:
                        continue
                    if res.get("seq") == p[0]:
                        GLib.idle_add(self.reply, p, res)

    def reply(self, p, res):
        with self.lock:
            if self.pending is not p:
                return False
            self.pending = None
        GLib.source_remove(p[3])
        overlay = [json.loads(l) for l in p[2] if l.startswith('{"type":"overlayChild"')]
        p[1].return_value(GLib.Variant("(s)", (json.dumps({"result": res, "overlay": overlay, "log": p[2]}),)))
        return False

    def timeout(self, p):
        with self.lock:
            if self.pending is not p:
                return False
            self.pending = None
        p[1].return_value(GLib.Variant("(s)", (json.dumps({"error": "timeout waiting for result", "log": p[2]}),)))
        return False

    def get_prop(self, conn, sender, path, iface, name):
        return GLib.Variant("s", self.command) if name == "Command" else GLib.Variant("u", self.seq)

    def emit(self, name, variant):
        self.conn.emit_signal(None, PATH, PROPS_IFACE, "PropertiesChanged",
                              GLib.Variant("(sa{sv}as)", (IFACE, {name: variant}, [])))

    def on_method(self, conn, sender, path, iface, method, params, invocation):
        if method == "Quit":
            invocation.return_value(None)
            GLib.timeout_add(100, self.loop.quit)
            return
        cmd = params.unpack()[0]
        with self.lock:
            if self.pending is not None:
                invocation.return_value(GLib.Variant("(s)", (json.dumps({"error": "busy"}),)))
                return
            self.command = cmd
            self.seq += 1
            p = [self.seq, invocation, [], None]
            p[3] = GLib.timeout_add(15000, self.timeout, p)
            self.pending = p
        self.emit("Command", GLib.Variant("s", cmd))
        self.emit("Seq", GLib.Variant("u", self.seq))


def call(method, *args, sig="()"):
    conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    return conn.call_sync(NAME, PATH, IFACE, method, GLib.Variant(sig, args) if args else None,
                          None, Gio.DBusCallFlags.NONE, 20000, None)


def shot(path, crop=None):
    from PIL import Image
    env = dict(os.environ, QT_QPA_PLATFORM="wayland")
    for attempt in range(3):
        r = subprocess.run(["spectacle", "-b", "-n", "-f", "-o", path], capture_output=True, text=True, timeout=30, env=env)
        if r.returncode == 0 and os.path.exists(path):
            im = Image.open(path)
            if not (im.mode == "RGBA" and im.getchannel("A").getextrema()[1] == 0):
                if crop:
                    x, y, w, h = crop
                    im.crop((x, y, x + w, y + h)).save(path)
                print(f"shot: {path} {im.size} crop={crop}")
                return
            print("shot: fully transparent capture, retrying", file=sys.stderr)
        time.sleep(0.5)
    sys.exit("spectacle capture failed")


def kwin(script, wait):
    name = "dialogspike_" + str(int(time.time()))
    q = ["qdbus6", "org.kde.KWin", "/Scripting"]
    since = time.strftime("%Y-%m-%d %H:%M:%S")
    sid = subprocess.run(q + ["org.kde.kwin.Scripting.loadScript", os.path.abspath(script), name], capture_output=True, text=True).stdout.strip()
    subprocess.run(q + ["org.kde.kwin.Scripting.start"], capture_output=True)
    time.sleep(wait)
    subprocess.run(q + ["org.kde.kwin.Scripting.unloadScript", name], capture_output=True)
    out = subprocess.run(["journalctl", "--user", "-o", "cat", "--since", since, "_COMM=kwin_wayland"], capture_output=True, text=True).stdout
    lines = [l for l in out.splitlines() if "[SpikeKWin]" in l]
    print(f"kwin: script id {sid}, {len(lines)} lines")
    for l in lines:
        print(l[l.index("[SpikeKWin]"):])


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="mode", required=True)
    sub.add_parser("serve")
    sub.add_parser("quit")
    c = sub.add_parser("cmd"); c.add_argument("command"); c.add_argument("--brief", action="store_true")
    s = sub.add_parser("shot"); s.add_argument("path"); s.add_argument("--crop")
    k = sub.add_parser("kwin"); k.add_argument("script"); k.add_argument("--wait", type=float, default=1.5)
    a = ap.parse_args()
    if a.mode == "serve":
        Server().start()
    elif a.mode == "quit":
        call("Quit")
    elif a.mode == "cmd":
        out = json.loads(call("Send", a.command, sig="(s)").unpack()[0])
        if a.brief and "result" in out:
            r = out["result"]
            print(json.dumps({k: r[k] for k in ("cmd", "err", "win", "focus", "combo") if k in r}))
            print("log:", *out["log"][:-1], sep="\n  ")
        else:
            print(json.dumps(out, indent=1))
    elif a.mode == "shot":
        shot(a.path, [int(v) for v in a.crop.split(",")] if a.crop else None)
    elif a.mode == "kwin":
        kwin(a.script, a.wait)


if __name__ == "__main__":
    main()
