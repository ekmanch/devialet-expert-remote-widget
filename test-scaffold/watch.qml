// THROWAWAY manual test scaffold - not part of the plasmoid. See README.md
// in this directory. Confirms the daemon's zbus PropertiesChanged signals
// are actually consumable via org.kde.plasma.workspace.dbus's
// Plasma.DBusProperties, the exact mechanism the real flyout will use.
//
// Run with: qml6 test-scaffold/watch.qml

import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.plasma.workspace.dbus as Dbus

Window {
    id: root
    visible: true
    width: 420
    height: 360
    title: "devialet-remote-daemon watch (throwaway)"

    Dbus.Properties {
        id: ampProps
        busType: Dbus.BusType.Session
        service: "com.ekmanch.DevialetRemote"
        path: "/com/ekmanch/DevialetRemote/Amp"
        iface: "com.ekmanch.DevialetRemote.Amp1"

        onPropertiesChanged: (interfaceName, changed, invalidated) => {
            console.log("[" + new Date().toISOString() + "] PropertiesChanged:", JSON.stringify(changed))
        }
        onRefreshed: {
            console.log("[" + new Date().toISOString() + "] initial snapshot received")
        }
    }

    Dbus.DBusServiceWatcher {
        id: serviceWatcher
        busType: Dbus.BusType.Session
        watchedService: "com.ekmanch.DevialetRemote"
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 6

        Label {
            text: serviceWatcher.registered
                ? "daemon: registered on session bus"
                : "daemon: NOT registered (is `cargo run -p devialet-remote-daemon` running?)"
            color: serviceWatcher.registered ? "darkgreen" : "crimson"
            font.bold: true
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: "lightgray" }

        Label { text: "DeviceName: " + (ampProps.properties.DeviceName ?? "(none yet)") }
        Label { text: "AmpIp: " + (ampProps.properties.AmpIp ?? "(none yet)") }
        Label { text: "Online: " + (ampProps.properties.Online ?? "(none yet)") }
        Label { text: "Power: " + (ampProps.properties.Power ?? "(none yet)") }
        Label { text: "Muted: " + (ampProps.properties.Muted ?? "(none yet)") }
        Label { text: "VolumeRaw: " + (ampProps.properties.VolumeRaw ?? "(none yet)") }
        Label { text: "VolumeDb: " + (ampProps.properties.VolumeDb ?? "(none yet)") }
        Label { text: "ActiveSourceIndex: " + (ampProps.properties.ActiveSourceIndex ?? "(none yet)") }
        Label { text: "ActiveSourceName: " + (ampProps.properties.ActiveSourceName ?? "(none yet)") }

        Rectangle { Layout.fillWidth: true; height: 1; color: "lightgray" }

        Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            // KNOWN ISSUE, found during Phase 1 manual verification: the
            // Sources property (D-Bus signature a(sybb), an array of
            // structs) arrives here as an opaque QVariant(QDBusArgument),
            // NOT a plain JS array - .filter()/.map() throw a TypeError on
            // it directly (confirmed live via `qml6` + journalctl during
            // this phase's testing). Scalar properties (String/bool/u8/
            // f64) all marshal cleanly; this only affects the
            // array-of-struct case. Needs real handling (likely manual
            // QDBusArgument iteration, or restructuring how the source
            // list is exposed) before the real source-picker UI is built -
            // flagging here rather than silently working around it, since
            // it's a concrete open item for that later phase.
            text: "Sources: (array-of-struct property - see comment above, not readable as a JS array yet)"
        }

        Item { Layout.fillHeight: true }

        Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font.italic: true
            text: "Full change log is on stdout, not in this window - watch the terminal you launched qml6 from."
        }
    }
}
