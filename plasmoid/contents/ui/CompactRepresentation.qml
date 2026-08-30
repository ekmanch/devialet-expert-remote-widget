// Minimal panel icon: click to open/close the flyout. No status glyph,
// no drag-and-drop - that's what org.kde.kdeconnect's CompactRepresentation
// (the real, shipped reference this pattern was taken from) adds on top for
// its own feature set; not needed here yet. Same structure works whether
// the applet ends up tray-hosted or panel-pinned - this plasmoid is
// panel-pinned (see CLAUDE.md).
//
// Phase 4.5.0: scroll-to-adjust-volume + hover/toast volume indicators,
// added directly on this icon. Deliberately an INDEPENDENT D-Bus mirror
// and stepVolume() from FullRepresentation.qml's much richer one, not a
// shared refactor - confirmed via libplasma's appletquickitem.cpp
// (createFullRepresentationItem()'s preload path, AppletQuickItem::init())
// that fullRepresentationItem is only *opportunistically* preloaded in the
// background per an adaptive weight/policy, not guaranteed to exist by the
// time a user first hovers this icon - so this file can't safely reach
// into FullRepresentation's state. Real precedent for keeping compact and
// full representations' interaction logic independent rather than shared:
// the real org.kde.plasma.volume applet's own compactRepresentation
// MouseArea (applet/main.qml) and its VolumeSlider.qml each implement
// wheel-to-volume separately, with no shared function between them either
// - both call into the same underlying service, but don't share code.
// Only Plasmoid.configuration.volumeStepDb (global KConfig, no plumbing
// needed) and the -15dB ceiling / -60dB floor UI convention (hardcoded
// here exactly as in FullRepresentation.qml - the real safety ceiling is
// enforced deeper, in devialet-protocol, regardless of what either file
// sends) are duplicated in spirit, not by reference.

pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.workspace.dbus as Dbus
import org.kde.plasma.plasma5support as P5Support

MouseArea {
    id: root

    required property PlasmoidItem plasmoidItem

    // ---- Local mirror of just the D-Bus state this icon needs (see
    // header comment for why this isn't shared with FullRepresentation) ----
    property string ampIp: ""
    property string deviceName: ""
    property var volumeDb: undefined
    property double lastIconStepAtMs: 0

    readonly property real volumeStepDb: Plasmoid.configuration.volumeStepDb
    readonly property real volumeCeilingDb: -15.0
    readonly property real volumeFloorDb: -60.0
    readonly property int debounceMs: 400
    readonly property string devialetCtlCommand: "devialet-ctl"

    // Exposed for main.qml's toolTipItem binding (see main.qml).
    readonly property string ampDisplayName: root.deviceName !== "" ? root.deviceName : "Devialet"
    readonly property string tooltipAmpName: root.ampIp === "" ? "No Amplifier" : root.ampDisplayName
    readonly property string iconSource: Plasmoid.icon

    function now() { return Date.now(); }
    function within(lastMs, windowMs) { return (root.now() - lastMs) < windowMs; }

    function unwrap(prop, fallback) {
        if (prop === undefined || prop === null) return fallback;
        if (typeof prop === "object" && prop.value !== undefined) return prop.value;
        return prop;
    }

    function stepVolume(direction) {
        if (root.ampIp === "") return;
        const base = root.volumeDb !== undefined ? root.volumeDb : root.volumeFloorDb;
        const stepped = base + direction * root.volumeStepDb;
        const clamped = Math.min(root.volumeCeilingDb, Math.max(root.volumeFloorDb, stepped));
        root.volumeDb = clamped;
        root.lastIconStepAtMs = root.now();
        exec.connectSource(root.devialetCtlCommand + " --ip " + root.ampIp + " volume " + clamped);
        volumeToast.iconSource = root.iconSource;
        volumeToast.show(root.tooltipAmpName + ": " + clamped.toFixed(1) + " dB");
    }

    hoverEnabled: true
    onClicked: root.plasmoidItem.expanded = !root.plasmoidItem.expanded

    property int wheelDelta: 0
    onWheel: wheel => {
        const delta = (wheel.inverted ? -1 : 1) * (wheel.angleDelta.y ? wheel.angleDelta.y : -wheel.angleDelta.x);
        if ((root.wheelDelta > 0 && delta < 0) || (root.wheelDelta < 0 && delta > 0)) {
            root.wheelDelta = 0;
        }
        root.wheelDelta += delta;

        // Magic number 120 for common "one click" - see
        // https://doc.qt.io/qt-6/qml-qtquick-wheelevent.html#angleDelta-prop
        while (root.wheelDelta >= 120) {
            root.wheelDelta -= 120;
            root.stepVolume(1);
        }
        while (root.wheelDelta <= -120) {
            root.wheelDelta += 120;
            root.stepVolume(-1);
        }
    }

    Kirigami.Icon {
        anchors.fill: parent
        source: Plasmoid.icon
        // Phase 4.2.5: devialet_icon_glow_dot.svg uses hardcoded copper
        // fill/stroke (not currentColor), unlike the previous
        // devialet_icon_currentColor_tray.svg this replaced - isMask is
        // deliberately off so the SVG's own colors (and the outer ring's
        // opacity, the "glow") render as designed, rather than being
        // collapsed into a flat Kirigami.Theme.textColor mask the way the
        // old currentColor icon needed. Trade-off: this icon no longer
        // adapts to a light panel theme the way a true symbolic/mask icon
        // would - not yet verified against a light Plasma theme.
        isMask: false
    }

    VolumeToast {
        id: volumeToast
    }

    // Fires devialet-ctl once per connectSource() call, then disconnects
    // itself - same pattern as FullRepresentation.qml's own `exec`
    // (confirmed pattern from Phase 2 (luisbocanegra.panel.colorizer's
    // RunCommand.qml)), kept as an independent instance here rather than
    // shared - see header comment.
    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            console.log("devialet-ctl finished - exit code:", data["exit code"], "stderr:", data["stderr"]);
            disconnectSource(source);
        }
    }

    Dbus.Properties {
        id: ampProps
        busType: Dbus.BusType.Session
        service: "com.ekmanch.DevialetRemote"
        path: "/com/ekmanch/DevialetRemote/Amp"
        iface: "com.ekmanch.DevialetRemote.Amp1"

        onRefreshed: {
            root.ampIp = root.unwrap(properties.AmpIp, "");
            root.deviceName = root.unwrap(properties.DeviceName, "");
            root.volumeDb = root.unwrap(properties.VolumeDb, undefined);
        }

        onPropertiesChanged: (interfaceName, changed, invalidated) => {
            if ("AmpIp" in changed) root.ampIp = root.unwrap(changed.AmpIp, root.ampIp);
            if ("DeviceName" in changed) root.deviceName = root.unwrap(changed.DeviceName, root.deviceName);
            if ("VolumeDb" in changed) {
                if (!root.within(root.lastIconStepAtMs, root.debounceMs)) {
                    root.volumeDb = root.unwrap(changed.VolumeDb, root.volumeDb);
                }
            }
        }
    }
}
