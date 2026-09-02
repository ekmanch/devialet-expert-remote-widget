// Phase 7.2.0 (spike/flyout-appletpopup-rebuild) - harness-only layout
// probe, the QML half of tools/flyout-harness/ (see its README.md and
// TODO.md's Phase 7.2.0 entry; basis: the investigation document's §5,
// context-on-spike-flyout-dialog-rebuild-b-quirky-wand.md).
//
// What it does, only while the harness is running: listens on a separate
// session-bus name (com.ekmanch.DevialetRemote.Harness, owned by
// tools/flyout-harness/fakeamp.py - never by the real daemon) for
//   PopupOpen  -> `popup.visible = value`, the same statement
//                 CompactRepresentation.qml's click handler runs, so no
//                 synthetic input is needed to open/close the flyout;
//   UiState    -> each key assigned onto `uiTarget` (QML-internal UI state
//                 that has no D-Bus property, e.g. ampListOpen - content
//                 phases point uiTarget at the item owning such state);
//   SettleMs   -> the settle timer's interval;
//   StateId/Seq-> a Seq change (with a non-empty StateId) restarts the
//                 settle timer, and when it fires every Item under `root`
//                 is logged as one JSON line per item via console.log,
//                 prefixed "[FlyoutProbe] ", which the harness reads back
//                 through journalctl (Phase 5.0.3's debug-logging path).
//
// Shippable permanently, stated plainly (asked for in the Phase 7.2.0 plan
// review): the only always-on cost is the DBusServiceWatcher below - a
// single NameOwnerChanged match rule for a name that never appears in
// normal use. Everything else lives inside a Loader that is inactive until
// that name is registered: no Dbus.Properties object, no GetAll, no timer,
// no tree walk, and this file never requests any bus name of its own (it
// is only ever a client). Nothing here needs stripping before Phase
// 7.8.0's cutover.
//
// Coordinates are logged raw (no rounding) - sub-pixel shifts are exactly
// what the harness exists to catch (the tooltip's three-round history,
// investigation document §2). Both window-relative (mapToItem(null)) and
// global (mapToGlobal) points are logged, plus width/height/implicit
// sizes, visibility, and - when the item has them - `text` and
// font.pixelSize, so a legitimately-changed label can be told apart from a
// bystander that moved. Keys: `objectName` when set (house rule for every
// anchored element from Phase 7.3.0 on), else the structural path.
// Non-Item children exposing a `mainItem` (a nested PlasmaCore.Dialog /
// AppletPopup - Phase 7.3.0's planned amp-list overlay window) are
// recursed with their own window-geometry record, so a second window is
// covered too.

pragma ComponentBehavior: Bound

import QtQuick
import org.kde.plasma.workspace.dbus as Dbus

Item {
    id: probe
    objectName: "layoutProbe"
    visible: false
    width: 0
    height: 0

    // The PlasmaCore.AppletPopup (Window-derived, not an Item) whose
    // visibility this probe drives and whose geometry it reports.
    required property var popup
    // The item tree to walk - the popup's mainItem.
    required property Item root
    // Object whose properties Harness1.UiState keys are assigned onto.
    property var uiTarget: probe.root

    readonly property string harnessService: "com.ekmanch.DevialetRemote.Harness"
    readonly property string harnessPath: "/com/ekmanch/DevialetRemote/Harness"
    readonly property string harnessIface: "com.ekmanch.DevialetRemote.Harness1"
    readonly property string tag: "[FlyoutProbe] "

    // Same unwrap shape as CompactRepresentation.qml/PendingAmpState.qml:
    // typed D-Bus scalars can arrive as {value: ...} wrappers.
    function unwrap(prop, fallback) {
        if (prop === undefined || prop === null) return fallback;
        if (typeof prop === "object" && prop.value !== undefined) return prop.value;
        return prop;
    }

    Dbus.DBusServiceWatcher {
        id: watcher
        busType: Dbus.BusType.Session
        watchedService: probe.harnessService
    }

    Loader {
        id: live
        active: watcher.registered
        sourceComponent: liveComponent
    }

    Component {
        id: liveComponent

        Item {
            id: session
            visible: false
            width: 0
            height: 0

            property int lastSeq: -1
            property string stateId: ""
            property var uiWarnings: []
            // Last UiState actually applied ({key: value | "MISSING"}) -
            // logged in `begin` so a run shows what UI state it drove.
            property var uiApplied: ({})
            property int count: 0

            // Logged from the loaded item's own lifecycle (not the Loader's
            // `active` signal, which also fires once at construction when
            // the default `true` gives way to the binding's `false` without
            // anything having been instantiated).
            Component.onCompleted: console.log(probe.tag + "harness service registered - probe live")
            Component.onDestruction: console.log(probe.tag + "harness service gone - probe inert")

            Dbus.Properties {
                id: ctl
                busType: Dbus.BusType.Session
                service: probe.harnessService
                path: probe.harnessPath
                iface: probe.harnessIface
                onRefreshed: session.applyAll(properties, true)
                onPropertiesChanged: (interfaceName, changed, invalidated) => session.applyAll(changed, false)
            }

            // Snapshot of Amp1 as seen from inside plasmashell - logged in
            // every `begin` record so the harness can assert the state it
            // set actually reached the widget before trusting a dump.
            Dbus.Properties {
                id: ampView
                busType: Dbus.BusType.Session
                service: "com.ekmanch.DevialetRemote"
                path: "/com/ekmanch/DevialetRemote/Amp"
                iface: "com.ekmanch.DevialetRemote.Amp1"
            }

            Timer {
                id: settle
                interval: 600
                repeat: false
                onTriggered: session.dump()
            }

            function applyAll(map, isRefresh) {
                if (map.SettleMs !== undefined) {
                    settle.interval = Number(probe.unwrap(map.SettleMs, 600));
                }
                if (map.PopupOpen !== undefined) {
                    const open = !!probe.unwrap(map.PopupOpen, false);
                    if (probe.popup.visible !== open) {
                        console.log(probe.tag + "PopupOpen -> " + open);
                        probe.popup.visible = open;
                    }
                }
                if (map.UiState !== undefined) {
                    session.applyUiState(probe.unwrap(map.UiState, {}));
                }
                // StateId before Seq, always: Seq is the trigger.
                if (map.StateId !== undefined) {
                    session.stateId = String(probe.unwrap(map.StateId, ""));
                }
                if (map.Seq !== undefined) {
                    const seq = Number(probe.unwrap(map.Seq, 0));
                    if (seq !== session.lastSeq && session.stateId !== "") {
                        session.lastSeq = seq;
                        settle.restart();
                    } else if (isRefresh) {
                        session.lastSeq = seq;
                    }
                }
            }

            function parseValue(v) {
                const s = String(v);
                if (s === "true") return true;
                if (s === "false") return false;
                if (s !== "" && !isNaN(Number(s))) return Number(s);
                return s;
            }

            // UiState arrives as a JSON string (an a{ss} dict would reach
            // QML as an opaque QDBusArgument with no visible keys - the
            // same marshalling gap test-scaffold/watch.qml documents for
            // the daemon's `Sources` array).
            function applyUiState(raw) {
                let ui;
                try {
                    ui = JSON.parse(String(raw));
                } catch (e) {
                    const msg = "UiState is not valid JSON: " + String(raw);
                    console.warn(probe.tag + msg);
                    session.uiWarnings = session.uiWarnings.concat([msg]);
                    return;
                }
                if (ui === null || typeof ui !== "object") return;
                session.uiApplied = {};
                const keys = Object.keys(ui);
                for (let i = 0; i < keys.length; i++) {
                    const key = keys[i];
                    const value = session.parseValue(probe.unwrap(ui[key], ""));
                    const target = probe.uiTarget;
                    if (!target || typeof target[key] === "undefined") {
                        const msg = "UiState key not on uiTarget: " + key;
                        console.warn(probe.tag + msg);
                        session.uiWarnings = session.uiWarnings.concat([msg]);
                        session.uiApplied[key] = "MISSING";
                        continue;
                    }
                    if (target[key] !== value) {
                        target[key] = value;
                    }
                    session.uiApplied[key] = value;
                }
            }

            // "Label_QMLTYPE_45(0x...)" -> "Label": the numeric suffix is
            // per-engine load order, so it must not leak into path keys.
            function clsName(o) {
                const s = String(o);
                const i = s.indexOf("(");
                return (i > 0 ? s.substring(0, i) : s).replace(/_QML(TYPE)?_\d+/g, "");
            }

            function knownAmpsLen() {
                const k = probe.unwrap(ampView.properties.KnownAmps, null);
                return (k !== null && k !== undefined && k.length !== undefined) ? k.length : null;
            }

            function dump() {
                const st = session.stateId;
                const seq = session.lastSeq;
                const p = probe.popup;
                const r = probe.root;
                const begin = {
                    type: "begin", state: st, seq: seq,
                    dpr: Screen.devicePixelRatio,
                    win: { x: p.x, y: p.y, w: p.width, h: p.height, visible: p.visible },
                    mainItem: { w: r.width, h: r.height, iw: r.implicitWidth, ih: r.implicitHeight },
                    amp: {
                        AmpIp: probe.unwrap(ampView.properties.AmpIp, null),
                        VolumeDb: probe.unwrap(ampView.properties.VolumeDb, null),
                        PowerState: probe.unwrap(ampView.properties.PowerState, null),
                        KnownAmpsLen: session.knownAmpsLen()
                    },
                    uiApplied: session.uiApplied,
                    uiWarnings: session.uiWarnings
                };
                console.log(probe.tag + JSON.stringify(begin));
                session.count = 0;
                session.walk(r, "root");
                console.log(probe.tag + JSON.stringify({ type: "end", state: st, seq: seq, count: session.count }));
                session.uiWarnings = [];
            }

            function walk(item, path) {
                if (item === probe || item === session) return;
                const wp = item.mapToItem(null, 0, 0);
                const gp = item.mapToGlobal(0, 0);
                const rec = {
                    type: "item",
                    key: item.objectName !== "" ? item.objectName : path,
                    path: path, on: item.objectName, cls: session.clsName(item),
                    x: item.x, y: item.y, w: item.width, h: item.height,
                    wx: wp.x, wy: wp.y, gx: gp.x, gy: gp.y,
                    iw: item.implicitWidth, ih: item.implicitHeight,
                    vis: item.visible, op: item.opacity
                };
                if (item.text !== undefined) rec.text = String(item.text);
                if (item.font !== undefined && item.font !== null && item.font.pixelSize !== undefined) rec.fpx = item.font.pixelSize;
                console.log(probe.tag + JSON.stringify(rec));
                session.count++;

                const counts = {};
                const kids = item.children;
                for (let i = 0; i < kids.length; i++) {
                    const c = kids[i];
                    const cn = session.clsName(c);
                    const n = counts[cn] === undefined ? 0 : counts[cn];
                    counts[cn] = n + 1;
                    session.walk(c, path + "/" + cn + "[" + n + "]");
                }

                // Nested popup windows (PlasmaCore.Dialog / AppletPopup are
                // not Items - they only appear in `data`, and expose
                // `mainItem`). Logged with their own window geometry, then
                // walked; their mapToItem(null) is relative to their own
                // window, which is what the window record is for.
                const data = item.data;
                for (let i = 0; i < data.length; i++) {
                    const o = data[i];
                    if (!o || o.mainItem === undefined || !o.mainItem || o.mainItem.width === undefined) continue;
                    const cn = session.clsName(o);
                    const wpath = path + "/" + cn + "[" + i + "]";
                    console.log(probe.tag + JSON.stringify({
                        type: "window", key: o.objectName !== undefined && o.objectName !== "" ? o.objectName : wpath,
                        path: wpath, cls: cn,
                        x: o.x, y: o.y, w: o.width, h: o.height, visible: o.visible
                    }));
                    session.walk(o.mainItem, wpath + ".mainItem");
                }
            }
        }
    }
}
