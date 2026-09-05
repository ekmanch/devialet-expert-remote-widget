#!/usr/bin/env python3
"""Fake devialet-remote-daemon + harness control interface (Phase 7.2.0).

Owns two session-bus names:

- com.ekmanch.DevialetRemote (the REAL daemon's name), object
  /com/ekmanch/DevialetRemote/Amp, interface com.ekmanch.DevialetRemote.Amp1:
  the 13 properties with the exact signatures the zbus daemon exports
  (`busctl introspect`, 2026-09-02) and its 4 methods (accepted, logged,
  no state effect). PropertiesChanged is emitted one property per signal
  in `emit_all()`'s order (interface.rs:706-721) so QML sees the same
  signal shape as with the real daemon.
- com.ekmanch.DevialetRemote.Harness, object /com/ekmanch/DevialetRemote/
  Harness, interface ...Harness1: the control channel LayoutProbe.qml
  listens to (PopupOpen, SettleMs, UiState, StateId, Seq).

Bus-name safety (see README.md "Bus-name conflict handling"): both names
are requested with DO_NOT_QUEUE and without REPLACE_EXISTING, so this can
never take a name from a running daemon and never sits queued to grab it
later. A name that is already owned raises NameOwnedError.

Standalone use for manual poking:
    fakeamp.py --state <id> [--open] [--ui ampListOpen=true] [--settle 600]
    fakeamp.py --list-states
(requires the real daemon to be stopped first:
    systemctl --user stop devialet-remote-daemon.service)
"""

import argparse
import json
import os
import signal
import sys
import threading

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenarios  # noqa: E402

AMP_NAME = "com.ekmanch.DevialetRemote"
AMP_PATH = "/com/ekmanch/DevialetRemote/Amp"
AMP_IFACE = "com.ekmanch.DevialetRemote.Amp1"
CTL_NAME = "com.ekmanch.DevialetRemote.Harness"
CTL_PATH = "/com/ekmanch/DevialetRemote/Harness"
CTL_IFACE = "com.ekmanch.DevialetRemote.Harness1"

# emit_all() order, interface.rs:706-721 - keep it.
AMP_PROPS = [
    ("DeviceName", "s"), ("AmpIp", "s"), ("Online", "b"), ("Power", "b"), ("PowerState", "s"),
    ("Muted", "b"), ("VolumeRaw", "y"), ("VolumeDb", "d"), ("ActiveSourceIndex", "y"),
    ("ActiveSourceName", "s"), ("Sources", "a(sybb)"), ("KnownAmps", "a(ssbs)"), ("SelectedAmpIp", "s"),
]
AMP_METHODS = [
    ("SelectAmp", [("ip", "s")]),
    ("BeginPowerOnBoot", [("ip", "s")]),
    ("NotifyVolumeCommand", [("ip", "s"), ("volume_db", "d")]),
    ("NotifyMuteCommand", [("ip", "s"), ("muted", "b")]),
]
# Seq deliberately last: it is the probe's trigger, everything else must
# already be applied when it lands.
# UiState is a JSON object serialised into a plain string: an `a{ss}` dict
# reaches QML as an opaque QDBusArgument (no keys visible - the same
# marshalling gap test-scaffold/watch.qml documents for `Sources`), a
# string round-trips exactly.
CTL_PROPS = [("PopupOpen", "b"), ("SettleMs", "u"), ("UiState", "s"), ("StateId", "s"), ("Seq", "u")]

DBUS_NAME_FLAG_DO_NOT_QUEUE = 4
REPLY_PRIMARY_OWNER = 1
REPLY_EXISTS = 3
REPLY_ALREADY_OWNER = 4

PROPS_IFACE = "org.freedesktop.DBus.Properties"


class NameOwnedError(RuntimeError):
    pass


def _iface_xml(name, props, methods=()):
    parts = [f'<node><interface name="{name}">']
    for mname, args in methods:
        parts.append(f'<method name="{mname}">')
        for aname, sig in args:
            parts.append(f'<arg name="{aname}" type="{sig}" direction="in"/>')
        parts.append("</method>")
    for pname, sig in props:
        parts.append(f'<property name="{pname}" type="{sig}" access="read"/>')
    parts.append("</interface></node>")
    return "".join(parts)


def name_owner(name, conn=None):
    """Unique name of `name`'s current owner, or None."""
    conn = conn or Gio.bus_get_sync(Gio.BusType.SESSION, None)
    try:
        reply = conn.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
            GLib.Variant("(s)", (name,)), GLib.VariantType("(s)"), Gio.DBusCallFlags.NONE, 2000, None,
        )
        return reply.unpack()[0]
    except GLib.Error as e:
        if "NameHasNoOwner" in str(e):
            return None
        raise


class FakeAmp:
    def __init__(self, log=None):
        self.log = log or (lambda msg: print(msg, file=sys.stderr, flush=True))
        self.amp = dict(scenarios.NOT_CONNECTED, KnownAmps=[], SelectedAmpIp="", AmpIp="")
        self.ctl = {"PopupOpen": False, "SettleMs": 600, "UiState": "{}", "StateId": "", "Seq": 0}
        self.conn = None
        self.loop = None
        self.thread = None
        self._reg_ids = []
        self._owned = []
        self.name_lost = threading.Event()
        self._sub_id = None
        self._stopping = False

    # ---- lifecycle -----------------------------------------------------
    def start(self):
        self.conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        # Refuse up front with a clear message rather than relying only on
        # RequestName's reply - covers both the systemd daemon and a
        # manually started foreground instance.
        for name in (AMP_NAME, CTL_NAME):
            owner = name_owner(name, self.conn)
            if owner is not None:
                raise NameOwnedError(f"{name} is already owned by {owner} - stop the real daemon first "
                                     f"(systemctl --user stop devialet-remote-daemon.service)")
        # Objects first, names second: a client reacting to NameOwnerChanged
        # must find GetAll already answerable.
        amp_info = Gio.DBusNodeInfo.new_for_xml(_iface_xml(AMP_IFACE, AMP_PROPS, AMP_METHODS)).interfaces[0]
        ctl_info = Gio.DBusNodeInfo.new_for_xml(_iface_xml(CTL_IFACE, CTL_PROPS)).interfaces[0]
        self._reg_ids.append(self.conn.register_object(AMP_PATH, amp_info, self._on_method, self._get_amp, None))
        self._reg_ids.append(self.conn.register_object(CTL_PATH, ctl_info, self._on_method, self._get_ctl, None))
        self._sub_id = self.conn.signal_subscribe(
            "org.freedesktop.DBus", "org.freedesktop.DBus", "NameLost", "/org/freedesktop/DBus", None,
            Gio.DBusSignalFlags.NONE, self._on_name_lost,
        )
        for name in (AMP_NAME, CTL_NAME):
            self._request_name(name)
            self._owned.append(name)
        self.loop = GLib.MainLoop()
        self.thread = threading.Thread(target=self.loop.run, name="fakeamp-glib", daemon=True)
        self.thread.start()
        self.log(f"fakeamp: owning {AMP_NAME} and {CTL_NAME} (unique {self.conn.get_unique_name()})")

    def _request_name(self, name):
        reply = self.conn.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            GLib.Variant("(su)", (name, DBUS_NAME_FLAG_DO_NOT_QUEUE)), GLib.VariantType("(u)"),
            Gio.DBusCallFlags.NONE, 2000, None,
        ).unpack()[0]
        if reply not in (REPLY_PRIMARY_OWNER, REPLY_ALREADY_OWNER):
            raise NameOwnedError(f"RequestName({name}) returned {reply} (3 = already owned) - refusing")

    def stop(self):
        if self.conn is None:
            return
        self._stopping = True
        for name in self._owned:
            try:
                self.conn.call_sync(
                    "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
                    GLib.Variant("(s)", (name,)), GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 2000, None,
                )
            except GLib.Error as e:
                self.log(f"fakeamp: ReleaseName({name}) failed: {e}")
        self._owned = []
        if self._sub_id is not None:
            self.conn.signal_unsubscribe(self._sub_id)
            self._sub_id = None
        for rid in self._reg_ids:
            self.conn.unregister_object(rid)
        self._reg_ids = []
        if self.loop is not None:
            self.loop.quit()
            self.thread.join(timeout=5)
            self.loop = None
        self.conn.flush_sync(None)
        self.log("fakeamp: released names, stopped")

    # ---- D-Bus callbacks (run on the GLib loop thread) ------------------
    def _get_amp(self, conn, sender, path, iface, name):
        sig = dict(AMP_PROPS)[name]
        return GLib.Variant(sig, self._coerce(sig, self.amp[name]))

    def _get_ctl(self, conn, sender, path, iface, name):
        sig = dict(CTL_PROPS)[name]
        return GLib.Variant(sig, self._coerce(sig, self.ctl[name]))

    def _on_method(self, conn, sender, path, iface, method, params, invocation):
        self.log(f"fakeamp: method call {iface}.{method}{params.unpack()} from {sender} (no-op)")
        invocation.return_value(None)

    def _on_name_lost(self, conn, sender, path, iface, signal_name, params):
        lost = params.unpack()[0]
        if lost in (AMP_NAME, CTL_NAME) and not self._stopping:
            self.log(f"fakeamp: NameLost {lost} - aborting")
            self.name_lost.set()

    @staticmethod
    def _coerce(sig, value):
        if sig == "d":
            return float(value)
        if sig in ("y", "u"):
            return int(value)
        if sig == "b":
            return bool(value)
        if sig == "a(sybb)":
            return [(str(n), int(i), bool(e), bool(s)) for (n, i, e, s) in value]
        if sig == "a(ssbs)":
            return [(str(ip), str(dn), bool(on), str(mn)) for (ip, dn, on, mn) in value]
        if sig == "a{ss}":
            return {str(k): str(v) for k, v in dict(value).items()}
        if sig == "s" and isinstance(value, dict):  # UiState
            return json.dumps({str(k): str(v) for k, v in value.items()}, sort_keys=True)
        return str(value)

    # ---- state mutation (any thread; marshalled onto the loop) ----------
    def _in_loop(self, fn):
        done = threading.Event()
        box = {}

        def wrapper():
            try:
                box["v"] = fn()
            except Exception as e:  # noqa: BLE001
                box["e"] = e
            done.set()
            return False

        GLib.idle_add(wrapper)
        if not done.wait(5):
            raise RuntimeError("fakeamp: GLib loop not responding")
        if "e" in box:
            raise box["e"]
        return box.get("v")

    def _emit(self, path, iface, name, sig, value):
        self.conn.emit_signal(
            None, path, PROPS_IFACE, "PropertiesChanged",
            GLib.Variant("(sa{sv}as)", (iface, {name: GLib.Variant(sig, self._coerce(sig, value))}, [])),
        )

    def set_amp(self, props):
        """Apply Amp1 property values and emit every property, like the
        daemon's unconditional emit_all() after a state change."""
        unknown = set(props) - set(dict(AMP_PROPS))
        if unknown:
            raise ValueError(f"unknown Amp1 properties: {sorted(unknown)}")

        def apply():
            self.amp.update(props)
            for name, sig in AMP_PROPS:
                self._emit(AMP_PATH, AMP_IFACE, name, sig, self.amp[name])

        self._in_loop(apply)

    def set_ctl(self, **props):
        unknown = set(props) - set(dict(CTL_PROPS))
        if unknown:
            raise ValueError(f"unknown Harness1 properties: {sorted(unknown)}")

        def apply():
            self.ctl.update(props)
            for name, sig in CTL_PROPS:  # fixed order, Seq last
                if name in props:
                    self._emit(CTL_PATH, CTL_IFACE, name, sig, self.ctl[name])

        self._in_loop(apply)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--state", help="state id from scenarios (see --list-states)")
    ap.add_argument("--list-states", action="store_true")
    ap.add_argument("--open", action="store_true", help="also set Harness1.PopupOpen = true")
    ap.add_argument("--ui", action="append", default=[], metavar="KEY=VALUE", help="Harness1.UiState entries")
    ap.add_argument("--settle", type=int, default=600, help="Harness1.SettleMs")
    args = ap.parse_args(argv)

    if args.list_states:
        for s in scenarios.full():
            print(s["id"])
        return 0

    state = None
    if args.state:
        state = next((s for s in scenarios.full() if s["id"] == args.state), None)
        if state is None:
            print(f"unknown state id {args.state!r} (see --list-states)", file=sys.stderr)
            return 2

    fake = FakeAmp()
    try:
        fake.start()
    except NameOwnedError as e:
        print(f"refusing to start: {e}", file=sys.stderr)
        return 3

    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    try:
        ui = dict(kv.split("=", 1) for kv in args.ui)
        if state is not None:
            fake.set_amp(state["props"])
            ui = dict(state["ui"], **ui)
        fake.set_ctl(PopupOpen=bool(args.open), SettleMs=args.settle, UiState=ui,
                     StateId=(state["id"] if state else "manual"), Seq=1)
        print("fakeamp: running - Ctrl-C to stop (releases the names, restart the real daemon yourself)",
              file=sys.stderr, flush=True)
        while not stop.is_set() and not fake.name_lost.is_set():
            stop.wait(0.5)
        if fake.name_lost.is_set():
            return 4
    finally:
        fake.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
