// Phase 7.9.0 spike driver - THROWAWAY, loaded by DialogSpike.qml only
// while tools/dialog-spike/spike.py owns com.ekmanch.DevialetRemote.
// DialogSpike on the session bus. Executes one command per Seq bump of
// that name's DialogSpike1.Command/Seq properties and logs a JSON
// `result` line (prefixed "[DialogSpike] ") that spike.py reads back from
// journald - the same control shape as LayoutProbe.qml/fakeamp.py.
//
// Synthetic input comes from QtTest's TestEvent (QuickTestEvent): its
// mouseClick/keyClick go through QTest -> QWindowSystemInterface, i.e. the
// same in-process delivery path a real compositor event takes after it
// enters Qt. That is enough for everything that is decided inside Qt
// (Popup/Overlay handling, focus, Keys/Shortcut); the compositor-side
// half (another window taking activation = "clicked elsewhere") is done
// from a KWin script by spike.py, not from here.

import QtQuick
import QtQuick.Controls
import QtTest
import org.kde.plasma.workspace.dbus as Dbus

Item {
    id: drv
    visible: false
    width: 0
    height: 0

    property var spike: null
    property Item mainItem: null
    property var combo: null
    property var textField: null
    property var tooltipRef: null
    property var flyoutRef: null

    readonly property string tag: "[DialogSpike] "
    readonly property string service: "com.ekmanch.DevialetRemote.DialogSpike"
    readonly property string path: "/com/ekmanch/DevialetRemote/DialogSpike"
    readonly property string iface: "com.ekmanch.DevialetRemote.DialogSpike1"

    property int lastSeq: -1
    property string command: ""
    property string lastError: ""
    property bool started: false

    function unwrap(prop, fallback) {
        if (prop === undefined || prop === null) return fallback;
        if (typeof prop === "object" && prop.value !== undefined) return prop.value;
        return prop;
    }
    function clsName(o) {
        if (o === null || o === undefined) return "null";
        const s = String(o);
        const i = s.indexOf("(");
        return (i > 0 ? s.substring(0, i) : s).replace(/_QML(TYPE)?_\d+/g, "");
    }
    function itemTag(o) {
        if (!o) return "null";
        return drv.clsName(o) + (o.objectName ? "#" + o.objectName : "");
    }

    function start() {
        drv.started = true;
        console.log(drv.tag + "driver loaded (QtTest TestEvent available: " + (ev !== null) + ")");
    }
    Component.onDestruction: console.log(drv.tag + "driver unloaded")

    TestEvent { id: ev }

    Dbus.Properties {
        id: ctl
        busType: Dbus.BusType.Session
        service: drv.service
        path: drv.path
        iface: drv.iface
        onRefreshed: drv.applyAll(properties, true)
        onPropertiesChanged: (interfaceName, changed, invalidated) => drv.applyAll(changed, false)
    }

    Timer {
        id: settle
        interval: 450
        repeat: false
        onTriggered: drv.finish()
    }

    function applyAll(map, isRefresh) {
        if (map.Command !== undefined) {
            drv.command = String(drv.unwrap(map.Command, ""));
        }
        if (map.Seq !== undefined) {
            const seq = Number(drv.unwrap(map.Seq, 0));
            if (isRefresh) {
                drv.lastSeq = seq;
            } else if (seq !== drv.lastSeq) {
                drv.lastSeq = seq;
                drv.run(drv.command);
            }
        }
    }

    function run(cmd) {
        drv.lastError = "";
        console.log(drv.tag + "cmd#" + drv.lastSeq + " " + cmd);
        const colon = cmd.indexOf(":");
        const name = colon > 0 ? cmd.substring(0, colon) : cmd;
        const arg = colon > 0 ? cmd.substring(colon + 1) : "";
        try {
            drv.exec(name, arg);
        } catch (e) {
            drv.lastError = String(e);
            console.log(drv.tag + "cmd error: " + e);
        }
        settle.restart();
    }

    function exec(name, arg) {
        const s = drv.spike;
        const c = drv.combo;
        switch (name) {
        case "open": s.visible = true; break;
        case "close": s.visible = false; break;
        case "dump": break;
        case "grow": drv.mainItem.grow = (arg === "true"); break;
        case "wide": drv.mainItem.wide = (arg === "true"); break;
        case "combo-open": c.popup.open(); break;
        case "combo-close": c.popup.close(); break;
        case "focus-combo": c.forceActiveFocus(); break;
        case "focus-text": drv.textField.forceActiveFocus(); break;
        case "focus-main": drv.mainItem.forceActiveFocus(); break;
        case "click-combo":
            ev.mouseClick(c, c.width / 2, c.height / 2, Qt.LeftButton, 0, 0);
            break;
        case "click-popup": {
            const lv = c.popup.contentItem;
            const idx = Number(arg);
            if (!lv || lv.itemAtIndex === undefined) throw "popup contentItem is not a ListView: " + drv.itemTag(lv);
            lv.positionViewAtIndex(idx, 0);
            const d = lv.itemAtIndex(idx);
            if (!d) throw "no delegate at index " + idx;
            ev.mouseClick(d, d.width / 2, d.height / 2, Qt.LeftButton, 0, 0);
            break;
        }
        case "click-inside":
            // Empty spacer area of the card: inside the Dialog window, outside
            // the ComboBox and its popup.
            ev.mouseClick(drv.mainItem, 60, drv.mainItem.height - 75, Qt.LeftButton, 0, 0);
            break;
        case "click-at": {
            // "x,y" in mainItem coordinates.
            const xy = arg.split(",");
            ev.mouseClick(drv.mainItem, Number(xy[0]), Number(xy[1]), Qt.LeftButton, 0, 0);
            break;
        }
        case "click-text":
            ev.mouseClick(drv.textField, drv.textField.width / 2, drv.textField.height / 2, Qt.LeftButton, 0, 0);
            break;
        case "key": ev.keyClick(Number(arg), 0, 0); break;
        case "type":
            for (let i = 0; i < arg.length; i++) ev.keyClickChar(arg.charAt(i), 0, 0);
            break;
        case "clear-text": drv.textField.text = ""; break;
        case "tooltip":
            if (!drv.tooltipRef) throw "no tooltipRef";
            drv.tooltipRef.visible = (arg === "on");
            break;
        case "set-type":
            // Reproduce VolumeHoverTooltip.qml's exact window setup on this
            // same Dialog, to compare positioning against the AppletPopup
            // setup at the same anchor.
            // Dialog::WindowType values are NET::WindowType values
            // (dialog.h: `AppletPopup = NET::AppletPopup`): Tooltip = 12,
            // AppletPopup = 18 - confirmed by the first run's dump
            // reporting type 18 for PlasmaCore.Dialog.AppletPopup.
            if (arg === "tooltip") {
                s.flags = Qt.WindowDoesNotAcceptFocus;
                s.type = 12;
            } else {
                s.flags = Qt.Dialog;
                s.type = 18;
            }
            break;
        case "pin": drv.mainItem.pin = (arg === "true"); break;
        case "overlay-fix": drv.mainItem.overlayFix = (arg === "true"); break;
        case "overlay-reset": drv.mainItem.fixOverlay("manual"); break;
        case "flyout-open": drv.flyoutRef.visible = true; break;
        case "flyout-close": drv.flyoutRef.visible = false; break;
        case "flyout-click-combo": {
            const fc = drv.findByName(drv.flyoutRef.mainItem, "sourceCombo");
            if (!fc) throw "sourceCombo not found";
            ev.mouseClick(fc, fc.width / 2, fc.height / 2, Qt.LeftButton, 0, 0);
            break;
        }
        case "flyout-combo-close": {
            const fc = drv.findByName(drv.flyoutRef.mainItem, "sourceCombo");
            if (!fc) throw "sourceCombo not found";
            fc.popup.close();
            break;
        }
        case "flyout-click-inside": {
            // Footer strip of the real flyout: inside the window, no control.
            const fm = drv.flyoutRef.mainItem;
            ev.mouseClick(fm, 30, fm.height - 8, Qt.LeftButton, 0, 0);
            break;
        }
        case "flyout-key": {
            ev.keyClick(Number(arg), 0, 0);
            break;
        }
        // Phase 7.10.0: synthetic hover over the panel icon, through the
        // REAL hover path (MouseArea.onEntered -> hoverShowTimer ->
        // tooltip.visible = true) - QTest mouseMove -> QWindowSystemInterface
        // on the panel window. The compositor pointer does not move.
        case "hover-icon": {
            const vp = drv.flyoutRef.flyoutVisualParent;
            ev.mouseMove(vp, vp.width / 2, vp.height / 2, 0, 0, 0);
            break;
        }
        case "hover-away": {
            const vp = drv.flyoutRef.flyoutVisualParent;
            ev.mouseMove(vp, -300, vp.height / 2, 0, 0, 0);
            break;
        }
        case "flyout-click-at": {
            const xy = arg.split(",").map(Number);
            ev.mouseClick(drv.flyoutRef.mainItem, xy[0], xy[1], Qt.LeftButton, 0, 0);
            break;
        }
        case "flyout-click-named": {
            const b = drv.findByName(drv.flyoutRef.mainItem, arg);
            if (!b) throw "item not found: " + arg;
            ev.mouseClick(b, b.width / 2, b.height / 2, Qt.LeftButton, 0, 0);
            break;
        }
        default:
            throw "unknown command " + name;
        }
    }

    function findByName(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        const kids = item.children;
        for (let i = 0; i < kids.length; i++) {
            const r = drv.findByName(kids[i], name);
            if (r) return r;
        }
        return null;
    }

    function flyoutInfo() {
        const f = drv.flyoutRef;
        if (!f) return null;
        const fm = f.mainItem;
        const fc = drv.findByName(fm, "sourceCombo");
        let ovKids = [];
        let ovCls = null;
        let ovGeom = null;
        if (fm && fm.parent) {
            const root = fm.parent;
            for (let i = 0; i < root.children.length; i++) {
                const c = root.children[i];
                if (drv.clsName(c) === "QQuickOverlay") {
                    ovCls = drv.itemTag(c);
                    ovGeom = [c.x, c.y, c.width, c.height];
                    for (let j = 0; j < c.children.length; j++) {
                        const k = c.children[j];
                        ovKids.push([drv.itemTag(k), k.x, k.y, k.width, k.height, k.visible]);
                    }
                }
            }
        }
        const vp = f.flyoutVisualParent;
        const vpo = vp ? vp.mapToItem(null, 0, 0) : null;
        const span = vp ? drv.findByName(vp, "flyoutPanelSpan") : null;
        const spo = span ? span.mapToItem(null, 0, 0) : null;
        return {
            win: { x: f.x, y: f.y, w: f.width, h: f.height, visible: f.visible, active: f.active,
                   type: f.type, flags: Number(f.flags), mainItem: f.mainItem ? [f.mainItem.x, f.mainItem.y, f.mainItem.width, f.mainItem.height] : null },
            visualParent: vp ? { inWindow: [vpo.x, vpo.y, vp.width, vp.height], global: [vp.mapToGlobal(0, 0).x, vp.mapToGlobal(0, 0).y] } : null,
            panelSpan: span ? { inWindow: [spo.x, spo.y, span.width, span.height], global: [span.mapToGlobal(0, 0).x, span.mapToGlobal(0, 0).y], parentIsIcon: span.parent === vp } : null,
            dialogVisualParentIsSpan: f.visualParent === span,
            activeFocusItem: drv.itemTag(f.activeFocusItem),
            combo: fc ? { enabled: fc.enabled, popupVisible: fc.popup.visible, activeFocus: fc.activeFocus, currentIndex: fc.currentIndex,
                          scene: [fc.mapToItem(null, 0, 0).x, fc.mapToItem(null, 0, 0).y, fc.width, fc.height],
                          popupXY: [fc.popup.x, fc.popup.y, fc.popup.width, fc.popup.height] } : null,
            contentItem: f.contentItem ? { w: f.contentItem.width, h: f.contentItem.height } : null,
            overlay: ovCls, overlayGeom: ovGeom, overlayKids: ovKids
        };
    }

    function chainToOverlay(item) {
        const ov = Overlay.overlay;
        const chain = [];
        let p = item;
        let hitOverlay = false;
        let hitMain = false;
        let n = 0;
        while (p && n < 40) {
            chain.push(drv.itemTag(p));
            if (p === ov) { hitOverlay = true; break; }
            if (p === drv.mainItem) { hitMain = true; break; }
            p = p.parent;
            n++;
        }
        return { chain: chain, endsAtOverlay: hitOverlay, endsAtMainItem: hitMain };
    }

    function finish() {
        const s = drv.spike;
        const c = drv.combo;
        const m = drv.mainItem;
        const ov = Overlay.overlay;
        const afi = s.activeFocusItem;
        const popup = c.popup;
        const content = popup ? popup.contentItem : null;
        const g = content ? content.mapToGlobal(0, 0) : null;

        // Overlay children, one line each (journald line-length safety).
        let ovKids = 0;
        if (ov) {
            for (let i = 0; i < ov.children.length; i++) {
                const k = ov.children[i];
                ovKids++;
                console.log(drv.tag + JSON.stringify({
                    type: "overlayChild", seq: drv.lastSeq, i: i, cls: drv.itemTag(k),
                    x: k.x, y: k.y, w: k.width, h: k.height, vis: k.visible
                }));
            }
        }

        const res = {
            type: "result", seq: drv.lastSeq, cmd: drv.command, err: drv.lastError,
            dpr: Screen.devicePixelRatio,
            screen: { w: Screen.width, h: Screen.height, availW: Screen.desktopAvailableWidth, availH: Screen.desktopAvailableHeight },
            win: { x: s.x, y: s.y, w: s.width, h: s.height, visible: s.visible, active: s.active,
                   type: s.type, flags: Number(s.flags), hints: s.backgroundHints, location: s.location,
                   hideOnDeactivate: s.hideOnWindowDeactivate },
            mainItem: { x: m.x, y: m.y, w: m.width, h: m.height, iw: m.implicitWidth, ih: m.implicitHeight, grow: m.grow },
            focus: { activeFocusItem: drv.itemTag(afi), mainItem: m.activeFocus, combo: c.activeFocus,
                     text: drv.textField.activeFocus, popup: popup ? popup.activeFocus : null },
            combo: { currentIndex: c.currentIndex, currentText: c.currentText, popupVisible: popup ? popup.visible : null,
                     popupOpened: popup ? popup.opened : null,
                     popupType: (popup && popup.popupType !== undefined) ? popup.popupType : null,
                     contentItem: drv.itemTag(content),
                     contentGlobal: g ? [g.x, g.y] : null,
                     contentSize: content ? [content.width, content.height] : null,
                     parentChain: content ? drv.chainToOverlay(content) : null,
                     popupParentChain: popup && popup.parent ? drv.chainToOverlay(popup.parent) : null },
            popupGeom: popup ? { x: popup.x, y: popup.y, w: popup.width, h: popup.height,
                                 itemScene: (popup.contentItem && popup.contentItem.parent) ? [popup.contentItem.parent.mapToItem(null, 0, 0).x, popup.contentItem.parent.mapToItem(null, 0, 0).y] : null,
                                 itemXY: (popup.contentItem && popup.contentItem.parent) ? [popup.contentItem.parent.x, popup.contentItem.parent.y] : null,
                                 parentScene: popup.parent ? [popup.parent.mapToItem(null, 0, 0).x, popup.parent.mapToItem(null, 0, 0).y, popup.parent.width, popup.parent.height] : null } : null,
            contentItem: s.contentItem ? { w: s.contentItem.width, h: s.contentItem.height } : null,
            overlay: { present: !!ov, cls: drv.itemTag(ov), x: ov ? ov.x : null, y: ov ? ov.y : null, w: ov ? ov.width : null, h: ov ? ov.height : null,
                       childCount: ovKids, overlayParent: ov ? drv.itemTag(ov.parent) : null,
                       overlayIsSiblingOfMainItem: ov ? (ov.parent === m.parent) : null },
            text: drv.textField.text,
            flyout: drv.flyoutInfo(),
            tooltip: drv.tooltipRef ? { visible: drv.tooltipRef.visible, x: drv.tooltipRef.x, y: drv.tooltipRef.y,
                                        w: drv.tooltipRef.width, h: drv.tooltipRef.height } : null
        };
        console.log(drv.tag + JSON.stringify(res));
    }
}
