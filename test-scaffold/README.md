# Manual test scaffold (throwaway, not part of the plasmoid)

Phase 1 has no real flyout UI yet. This directory exists only to manually
verify the daemon end-to-end (UDP receive -> parse -> D-Bus push -> QML
reactive binding) before building any real UI on top of it. Nothing here is
plasmoid packaging - delete this whole directory once the real
`contents/ui/` structure exists in a later phase.

## 0. Build and run the daemon

```sh
cargo run -p devialet-remote-daemon
```

Leave it running in a terminal. It logs what it's doing to stderr (bind,
D-Bus registration, etc). It needs a real Devialet Expert/Expert Pro
broadcasting on the LAN (UDP 45454) to have anything interesting to show -
until one broadcasts, every property just stays at its zero-value default
and `Online` stays `false`.

## 1. Fastest sanity check: busctl

In another terminal, with the daemon still running:

```sh
# Confirm the service is up and see all current property values:
busctl --user introspect com.ekmanch.DevialetRemote /com/ekmanch/DevialetRemote/Amp

# Read one property directly:
busctl --user get-property com.ekmanch.DevialetRemote /com/ekmanch/DevialetRemote/Amp \
    com.ekmanch.DevialetRemote.Amp1 Online

# Watch PropertiesChanged signals live as status broadcasts arrive
# (~1x/sec once an amp is on the LAN) - this is the actual push mechanism,
# not polling:
busctl --user monitor com.ekmanch.DevialetRemote
```

If `busctl monitor` shows `PropertiesChanged` firing roughly once a second
with real values once the amp is powered on, the daemon side of the
architecture is confirmed working end-to-end.

## 2. QML sanity check (confirms the actual consumption path the widget
## will use later: `Plasma.DBusProperties`, not busctl)

`watch.qml` in this directory is a bare, standalone QML window - not a
plasmoid, no packaging, nothing reused later - that binds to the same
properties reactively and prints changes to stdout. Run it with:

```sh
qml6 test-scaffold/watch.qml
```

(If `qml6` isn't on PATH, it's usually part of the `qt6-declarative` package
- already installed on this machine, see `qmake6` check from the CLAUDE.md
scaffold pass.)

Expected output: an initial snapshot line, then one new line every time the
daemon's properties change (again, ~1x/sec once an amp is broadcasting).
This is the actual proof that `org.kde.plasma.workspace.dbus`'s
`Plasma.DBusProperties` correctly reacts to `zbus`'s `PropertiesChanged`
emission - the thing the whole push-vs-poll architecture decision rested
on.

## 3. Manual command test

With the daemon running and showing live status:

```sh
cargo run -p devialet-ctl -- --ip <your amp's IP, from step 1's AmpIp property> power on
cargo run -p devialet-ctl -- --ip <ip> volume -30
cargo run -p devialet-ctl -- --ip <ip> mute on
cargo run -p devialet-ctl -- --ip <ip> source 2
```

Watch the amp's own display and/or the `busctl monitor`/QML output to
confirm each command actually reached and was applied by the amp - see
"what to verify against the real amp" in the phase summary for the full
checklist (counter behavior, source mapping, safety clamp, etc).
