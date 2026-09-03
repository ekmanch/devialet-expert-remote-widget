// Phase 7.3.0 (spike/flyout-appletpopup-rebuild) - the real flyout content
// root, successor to FullRepresentation.qml's root Item, hosted inside
// FlyoutPopup.qml's PlasmaCore.AppletPopup mainItem. See TODO.md's Phase
// 7.3.0 entry and the plan it cites.
//
// This phase builds ONLY the amp header (AmpHeader.qml, in-flow) + the amp
// list (AmpListOverlay.qml, pulled out of flow per §4 point 4 option (b)).
// Everything below the header - volume block, action row, source selector,
// footer - is a declared placeholder spacer (`sectionsPlaceholder`) that
// 7.4.0-7.6.0 replace section by section; it exists so the popup's height
// is realistic from now on (the overlay would otherwise be clipped by a
// header-only ~72px popup). Do not port 7.4.0-7.6.0's sections here.
//
// State/functions below are the header-only subset ported verbatim from
// FullRepresentation.qml (online/deviceName/ampIp/power/powerState/
// knownAmps/selectedAmpIp + unwrap/unwrapKnownAmps/fetchKnownAmpsFresh/
// selectAmpByIp + headerName/headerSub + its Dbus.Properties mirror for
// exactly those properties). Volume/mute/power-debounce/sources handling
// is deliberately NOT ported - it arrives with 7.4.0-7.6.0 (and volume/
// mute go through pendingAmpState per Phase 5, not a local mirror).

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.ksvg as KSvg
import org.kde.plasma.plasmoid
import org.kde.plasma.workspace.dbus as Dbus

Item {
    id: root

    required property PlasmoidItem plasmoidItem
    // Forwarded from FlyoutPopup; unused until 7.4.0's volume section reads
    // it (Phase 5's shared pending-state consumer).
    required property PendingAmpState pendingAmpState
    // Bound one-way from FlyoutPopup.visible - drives the amp-list reset on
    // flyout hide below (and is the future binding target for the deferred
    // pop-in animation, 7.7.0 polish).
    property bool popupVisible: false

    readonly property Theme theme: Theme {}

    implicitWidth: theme.panelWidth
    implicitHeight: mainColumn.implicitHeight

    // ---- box-in-box / inset math for the background tint, ported from
    // FullRepresentation.qml (see its own long comment for the full
    // reasoning; unchanged here). ----
    KSvg.FrameSvgItem {
        id: dialogBg
        visible: false
        imagePath: "dialogs/background"
    }
    readonly property real insetLeft: dialogBg.fixedMargins.left - dialogBg.inset.left
    readonly property real insetTop: dialogBg.fixedMargins.top - dialogBg.inset.top
    readonly property real insetRight: dialogBg.fixedMargins.right - dialogBg.inset.right
    readonly property real insetBottom: dialogBg.fixedMargins.bottom - dialogBg.inset.bottom

    // ---- amp state (header subset) ----
    property bool online: false
    property string deviceName: ""
    property string ampIp: ""
    property bool power: false
    property string powerState: "Off"
    property var knownAmps: []
    property string selectedAmpIp: ""

    // The single UI-state hook (harness `uiTarget` points here). Writers
    // are all imperative - see the header of this file's plan; no binding
    // touches it, so the header->overlay->Popup chain can't loop.
    property bool ampListOpen: false

    // Reset the list when the flyout hides, so it isn't already expanded on
    // the next open (neither the old flyout nor a QtQuick Popup resets on
    // window hide on its own).
    onPopupVisibleChanged: if (!root.popupVisible) root.ampListOpen = false

    // Drive the overlay Popup imperatively off ampListOpen. close() on an
    // already-closed Popup is a no-op emitting nothing, so the re-entrant
    // path (overlay dismiss -> onClosed sets false -> here calls close())
    // terminates safely.
    onAmpListOpenChanged: root.ampListOpen ? ampListOverlay.open() : ampListOverlay.close()

    function unwrap(prop, fallback) {
        if (prop === undefined || prop === null) return fallback;
        if (typeof prop === "object" && prop.value !== undefined) return prop.value;
        return prop;
    }

    function unwrapKnownAmps(raw) {
        if (raw === undefined || raw === null) return [];
        var result = [];
        for (var i = 0; i < raw.length; i++) {
            var t = raw[i];
            result.push({
                ip: root.unwrap(t[0], ""),
                deviceName: root.unwrap(t[1], ""),
                online: t[2],
                modelName: root.unwrap(t[3], "")
            });
        }
        return result;
    }

    property bool knownAmpsFetchInFlight: false

    // KnownAmps is array-of-struct: its PropertiesChanged delta is not
    // trustworthy on repeat updates (see FullRepresentation.qml's
    // fetchKnownAmpsFresh doc for the wire-level finding), so re-fetch via
    // an explicit Get on the signal rather than trusting `changed.KnownAmps`.
    function fetchKnownAmpsFresh() {
        if (root.knownAmpsFetchInFlight) return;
        root.knownAmpsFetchInFlight = true;
        Dbus.SessionBus.asyncCall(
            new Dbus.dbusMessage({
                service: "com.ekmanch.DevialetRemote",
                path: "/com/ekmanch/DevialetRemote/Amp",
                interface: "org.freedesktop.DBus.Properties",
                member: "Get",
                arguments: ["com.ekmanch.DevialetRemote.Amp1", "KnownAmps"]
            }),
            function (reply) {
                root.knownAmpsFetchInFlight = false;
                if (reply.isError) {
                    console.log("[WARN] explicit Get(KnownAmps) returned a D-Bus error:", JSON.stringify(reply.error));
                    return;
                }
                const unwrapped = root.unwrapKnownAmps(root.unwrap(reply.value, []));
                if (unwrapped.length > 0) {
                    root.knownAmps = unwrapped;
                }
            },
            function (reply) {
                root.knownAmpsFetchInFlight = false;
                console.log("[WARN] explicit Get(KnownAmps) call failed:", JSON.stringify(reply.error));
            }
        );
    }

    function selectAmpByIp(ip) {
        root.ampListOpen = false;
        Dbus.SessionBus.asyncCall(
            new Dbus.dbusMessage({
                service: "com.ekmanch.DevialetRemote",
                path: "/com/ekmanch/DevialetRemote/Amp",
                interface: "com.ekmanch.DevialetRemote.Amp1",
                member: "SelectAmp",
                arguments: [ip]
            }),
            function (reply) {
                if (reply.isError) {
                    console.log("[WARN] SelectAmp call returned a D-Bus error:", JSON.stringify(reply.error));
                }
            },
            function (reply) {
                console.log("[WARN] SelectAmp call failed:", JSON.stringify(reply.error));
            }
        );
    }

    readonly property string ampDisplayName: root.deviceName !== "" ? root.deviceName : "Devialet"
    readonly property string headerName: root.ampIp === "" ? "No Amplifier" : root.ampDisplayName
    readonly property string headerSub: root.ampIp === "" ? "Tap to connect" : (root.powerState === "Booting" ? "Booting…" : (root.ampIp + " · " + (root.online ? "Connected" : "Not responding")))

    Dbus.Properties {
        id: ampProps
        busType: Dbus.BusType.Session
        service: "com.ekmanch.DevialetRemote"
        path: "/com/ekmanch/DevialetRemote/Amp"
        iface: "com.ekmanch.DevialetRemote.Amp1"

        onRefreshed: {
            root.online = root.unwrap(properties.Online, false);
            root.deviceName = root.unwrap(properties.DeviceName, "");
            root.ampIp = root.unwrap(properties.AmpIp, "");
            root.power = root.unwrap(properties.Power, false);
            root.powerState = root.unwrap(properties.PowerState, "Off");
            const initialKnownAmps = root.unwrapKnownAmps(root.unwrap(properties.KnownAmps, []));
            if (initialKnownAmps.length > 0) {
                root.knownAmps = initialKnownAmps;
            }
            root.selectedAmpIp = root.unwrap(properties.SelectedAmpIp, "");
        }

        onPropertiesChanged: (interfaceName, changed, invalidated) => {
            if ("Online" in changed) root.online = root.unwrap(changed.Online, root.online);
            if ("DeviceName" in changed) root.deviceName = root.unwrap(changed.DeviceName, root.deviceName);
            if ("AmpIp" in changed) root.ampIp = root.unwrap(changed.AmpIp, root.ampIp);
            if ("Power" in changed) root.power = root.unwrap(changed.Power, root.power);
            if ("PowerState" in changed) root.powerState = root.unwrap(changed.PowerState, root.powerState);
            if ("SelectedAmpIp" in changed) root.selectedAmpIp = root.unwrap(changed.SelectedAmpIp, root.selectedAmpIp);
            if ("KnownAmps" in changed) root.fetchKnownAmpsFresh();
        }
    }

    // ---- background tint, ported from FullRepresentation.qml:740-754
    // (bled outward by the inset margins - the box-in-box fix; see there).
    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -root.insetLeft
        anchors.topMargin: -root.insetTop
        anchors.rightMargin: -root.insetRight
        anchors.bottomMargin: -root.insetBottom
        radius: Kirigami.Units.cornerRadius
        antialiasing: true
        border.width: 1
        border.color: root.theme.divider
        gradient: Gradient {
            GradientStop { position: 0.0; color: root.theme.panelGradientTop }
            GradientStop { position: 1.0; color: root.theme.panelGradientBottom }
        }
    }

    ColumnLayout {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 0

        AmpHeader {
            id: ampHeader
            theme: root.theme
            ampIp: root.ampIp
            headerName: root.headerName
            headerSub: root.headerSub
            online: root.online
            power: root.power
            powerState: root.powerState
            listOpen: root.ampListOpen
            onToggleRequested: root.ampListOpen = !root.ampListOpen
        }

        // Stand-in for 7.4.0-7.6.0's sections (volume block, action row,
        // source selector, footer). Height is an estimate of that combined
        // content so the popup is a realistic size and the overlay isn't
        // clipped; each later phase replaces part of it, and it is gone by
        // 7.6.0. Not a binding to any real content - purely a spacer.
        Item {
            objectName: "sectionsPlaceholder"
            Layout.fillWidth: true
            Layout.preferredHeight: 270
        }
    }

    // Amp list overlay - parented to the header so it anchors flush beneath
    // it (Popup positions relative to `parent`), content reparented into
    // the flyout window's Overlay (no new window). Owner never binds its
    // `visible`; drives open()/close() via onAmpListOpenChanged above and
    // listens to `closed`.
    AmpListOverlay {
        id: ampListOverlay
        parent: ampHeader
        theme: root.theme
        knownAmps: root.knownAmps
        ampIp: root.ampIp
        onClosed: root.ampListOpen = false
        onAmpChosen: ip => root.selectAmpByIp(ip)
    }

    // ---- settings trigger, ported from FullRepresentation.qml:772-801 ----
    Rectangle {
        id: settingsTrigger
        objectName: "settingsTrigger"
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 10
        width: 24
        height: 24
        radius: root.theme.radiusSm
        color: settingsTriggerArea.containsMouse ? root.theme.surface2 : "transparent"
        z: 10

        Kirigami.Icon {
            anchors.centerIn: parent
            width: 15
            height: 15
            source: Qt.resolvedUrl("../icons/settings_gear.svg")
            isMask: true
            color: settingsTriggerArea.containsMouse ? root.theme.copperBright : root.theme.textFaint
        }

        MouseArea {
            id: settingsTriggerArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                Plasmoid.internalAction("configure")?.trigger()
            }
        }
    }
}
