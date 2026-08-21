// Phase 2: bare-minimum flyout content, proving the architecture, not the
// design. No Kirigami theming, no mockup visuals - see CLAUDE.md.
//
// D-Bus surface below (service/path/interface/property names) was
// confirmed live via `busctl --user introspect` before writing this file,
// not assumed from earlier notes - see the Phase 2 verification report.
//
// IMPORTANT finding from live testing, load-bearing for the structure of
// this file: binding a Label's `text:` directly to
// `ampProps.properties.SomeKey` only re-evaluates for that key's FIRST
// change - confirmed with debug logging that `Dbus.Properties`' own
// `onPropertiesChanged` signal keeps firing correctly and continuously
// (~10Hz, matching the amp's real broadcast rate, confirmed against
// `busctl monitor` showing a consistently-typed `VARIANT "d"` on the wire
// the whole time - this is not a daemon-side bug), but a QML binding
// reading `properties.<Key>` directly stops re-evaluating after the first
// update, even though the underlying QQmlPropertyMap keeps being updated.
// This looks like an upstream reactivity limitation in
// org.kde.plasma.workspace.dbus's DBusPropertyMap, not something fixable
// from a binding expression alone (tried both direct inline property
// access and a wrapper function - same result either way).
//
// Workaround, used below: consume `onPropertiesChanged` imperatively into
// plain local QML properties (real Q_PROPERTYs with NOTIFY, not dynamic
// QQmlPropertyMap keys), and bind the UI to those instead. Still entirely
// push-driven by the same D-Bus signal - no polling/timers introduced -
// just a more robust way of consuming it. Values also arrive inconsistently
// wrapped ({"value": X} vs a bare X) between updates of the same property;
// `unwrap()` tolerates both.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.plasma.workspace.dbus as Dbus
import org.kde.plasma.plasma5support as P5Support

ColumnLayout {
    id: root

    Layout.minimumWidth: 260
    Layout.minimumHeight: 120

    readonly property real volumeStepDb: 1.0

    // ASSUMPTION, flagged per your request rather than silently
    // hardcoded as final: there is no install/packaging step for
    // devialet-ctl yet (Phase 3 here only installs the plasmoid itself).
    // This absolute path only works on this dev machine and must be
    // revisited (e.g. installed to something on PATH, or resolved via a
    // config value) before this is usable anywhere else.
    readonly property string devialetCtlPath: "/mnt/media/github/devialet-expert-remote-widget/target/debug/devialet-ctl"

    // Local mirror of the D-Bus properties we care about, kept in sync
    // imperatively from Dbus.Properties' signals - see header comment.
    property bool online: false
    property string deviceName: ""
    property string ampIp: ""
    property var volumeDb: undefined

    function unwrap(prop, fallback) {
        if (prop === undefined || prop === null) return fallback;
        if (typeof prop === "object" && prop.value !== undefined) return prop.value;
        return prop;
    }

    Dbus.Properties {
        id: ampProps
        busType: Dbus.BusType.Session
        service: "com.ekmanch.DevialetRemote"
        path: "/com/ekmanch/DevialetRemote/Amp"
        iface: "com.ekmanch.DevialetRemote.Amp1"

        onRefreshed: {
            // Initial GetAll snapshot.
            root.online = root.unwrap(properties.Online, false);
            root.deviceName = root.unwrap(properties.DeviceName, "");
            root.ampIp = root.unwrap(properties.AmpIp, "");
            root.volumeDb = root.unwrap(properties.VolumeDb, undefined);
        }

        onPropertiesChanged: (interfaceName, changed, invalidated) => {
            if ("Online" in changed) root.online = root.unwrap(changed.Online, root.online);
            if ("DeviceName" in changed) root.deviceName = root.unwrap(changed.DeviceName, root.deviceName);
            if ("AmpIp" in changed) root.ampIp = root.unwrap(changed.AmpIp, root.ampIp);
            if ("VolumeDb" in changed) root.volumeDb = root.unwrap(changed.VolumeDb, root.volumeDb);
        }
    }

    // Fires devialet-ctl once per connectSource() call, then disconnects
    // itself - pattern confirmed against a real installed third-party
    // plasmoid using the same "executable" engine
    // (luisbocanegra.panel.colorizer's RunCommand.qml), not invented from
    // the dataengine's API alone.
    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            console.log("devialet-ctl finished - exit code:", data["exit code"], "stderr:", data["stderr"]);
            disconnectSource(source);
        }
    }

    function stepVolumeDown() {
        const currentDb = root.volumeDb !== undefined ? root.volumeDb : 0;
        const newDb = currentDb - root.volumeStepDb;
        const cmd = root.devialetCtlPath + " --ip " + root.ampIp + " volume " + newDb;
        console.log("running:", cmd);
        exec.connectSource(cmd);
    }

    Label {
        text: root.online ? "Connected: " + root.deviceName : "Not connected"
    }

    Label {
        text: "Volume: " + (root.volumeDb !== undefined ? root.volumeDb.toFixed(1) + " dB" : "—")
    }

    Button {
        text: "Volume −" + root.volumeStepDb.toFixed(1) + " dB"
        enabled: root.ampIp !== ""
        onClicked: root.stepVolumeDown()
    }
}
