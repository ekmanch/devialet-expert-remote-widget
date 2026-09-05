// Phase 7.3.0 (spike/flyout-appletpopup-rebuild) - the real flyout content
// root, successor to FullRepresentation.qml's root Item, hosted inside
// FlyoutPopup.qml's PlasmaCore.AppletPopup mainItem. See TODO.md's Phase
// 7.3.0 entry and the plan it cites.
//
// Phase 7.3.0 built the amp header (AmpHeader.qml, in-flow) + the amp list
// (AmpListOverlay.qml, pulled out of flow per §4 point 4 option (b)).
// Phase 7.4.0 added the volume block (VolumeBlock.qml - dB/unit readout,
// source chip, -/slider/+). Phase 7.5.0 added the action row
// (ActionRow.qml - mute/power buttons). Phase 7.6.0 adds the source
// selector (SourceSelector.qml) and footer (Footer.qml), fully consuming
// `sectionsPlaceholder` - every row in this file is now real content, no
// placeholder spacer remains anywhere.
//
// State/functions below were the header-only subset ported verbatim from
// FullRepresentation.qml through 7.3.0 (online/deviceName/ampIp/power/
// powerState/knownAmps/selectedAmpIp + unwrap/unwrapKnownAmps/
// fetchKnownAmpsFresh/selectAmpByIp + headerName/headerSub + its
// Dbus.Properties mirror for exactly those properties). Phase 7.4.0 added
// activeSourceName (a plain scalar, trusted directly like ampIp/
// deviceName) plus the volume command surface (runCtl/exec/stepVolume/
// releaseVolume) - volumeDb/muted themselves are deliberately NOT a new
// local mirror, they're read from `pendingAmpState` (the required
// property already forwarded in) per Phase 5's shared, daemon-resolved
// architecture - see VolumeBlock.qml's header comment for the full
// reasoning. Phase 7.5.0 added the mute/power command surface
// (toggleMute/togglePower/beginPowerOnBoot): mute follows the same
// pendingAmpState.muted pattern volume already established (no local
// mirror, no debounce - Phase 5.0.2 Step B's daemon-resolved shape).
// Power/PowerState are different - PendingAmpState deliberately doesn't
// cover them (see its own header comment), so they stay in this file's
// own D-Bus mirror (already present since 7.3.0 for the header), which
// gained its first writer in 7.5.0 and therefore its first debounce guard
// (`lastPowerChangeAtMs`, ported from FullRepresentation.qml). Phase
// 7.6.0 adds `sources`/`activeSourceIndex` (array-of-struct, same
// "don't trust the PropertiesChanged delta, re-fetch on signal"
// treatment `knownAmps` already has - `unwrapSources`/
// `fetchSourcesFresh`) plus `selectSource()`. `activeSourceName` (added
// in 7.4.0 as an always-trusted scalar, since nothing wrote it locally
// back then) now shares `ActiveSourceIndex`'s debounce guard
// (`lastSourceChangeAtMs`) alongside it, for the identical reason Power/
// PowerState gained one in 7.5.0: this phase gives it its first local
// writer.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.workspace.dbus as Dbus
import org.kde.plasma.plasma5support as P5Support

Item {
    id: root

    required property PlasmoidItem plasmoidItem
    // Forwarded from FlyoutPopup - Phase 5's shared, daemon-resolved
    // pending-state consumer. Phase 7.4.0: VolumeBlock's volumeDb is fed
    // from pendingAmpState.volumeDb, and stepVolume/releaseVolume below
    // call pendingAmpState.notifyVolume() - see VolumeBlock.qml's header
    // comment for why this is deliberately not a new local mirror.
    required property PendingAmpState pendingAmpState
    // Bound one-way from FlyoutPopup.visible - drives the amp-list reset on
    // flyout hide below (and is the future binding target for the deferred
    // pop-in animation, 7.7.0 polish).
    property bool popupVisible: false

    readonly property Theme theme: Theme {}

    implicitWidth: theme.panelWidth
    implicitHeight: mainColumn.implicitHeight

    // ---- amp state (header subset) ----
    property bool online: false
    property string deviceName: ""
    property string ampIp: ""
    property bool power: false
    property string powerState: "Off"
    property var knownAmps: []
    property string selectedAmpIp: ""

    // ---- Phase 7.4.0/7.6.0: source state ----
    // activeSourceName: plain scalar mirror (added 7.4.0), trusted like
    // online/deviceName/ampIp - but see the Phase 7.6.0 debounce guard on
    // it below now that selectSource() writes it locally.
    property string activeSourceName: ""
    // Phase 7.6.0: ActiveSourceIndex is a scalar too (`y`/byte, confirmed
    // via FullRepresentation.qml's own busctl-checked header comment), no
    // fetch-fresh workaround needed. `sources` (a(sybb)) IS array-of-
    // struct like KnownAmps, so it gets the identical treatment -
    // unwrapSources()/fetchSourcesFresh() below, ported from
    // FullRepresentation.qml.
    property int activeSourceIndex: -1
    property var sources: []
    property double lastSourceChangeAtMs: 0

    property bool sourcesFetchInFlight: false

    function unwrapSources(raw) {
        if (raw === undefined || raw === null) return [];
        var result = [];
        for (var i = 0; i < raw.length; i++) {
            var t = raw[i];
            result.push({
                name: root.unwrap(t[0], ""),
                index: root.unwrap(t[1], i),
                enabled: t[2],
                selected: t[3]
            });
        }
        return result;
    }

    // Sources' PropertiesChanged delta payload is not trustworthy on
    // repeat updates (see FullRepresentation.qml's own fetchSourcesFresh
    // doc for the wire-level finding, same basis as fetchKnownAmpsFresh
    // above) - re-fetch via an explicit Get on the signal rather than
    // trusting `changed.Sources`.
    function fetchSourcesFresh() {
        if (root.sourcesFetchInFlight) return;
        root.sourcesFetchInFlight = true;
        Dbus.SessionBus.asyncCall(
            new Dbus.dbusMessage({
                service: "com.ekmanch.DevialetRemote",
                path: "/com/ekmanch/DevialetRemote/Amp",
                interface: "org.freedesktop.DBus.Properties",
                member: "Get",
                arguments: ["com.ekmanch.DevialetRemote.Amp1", "Sources"]
            }),
            function (reply) {
                root.sourcesFetchInFlight = false;
                if (reply.isError) {
                    console.log("[WARN] explicit Get(Sources) returned a D-Bus error:", JSON.stringify(reply.error));
                    return;
                }
                const unwrapped = root.unwrapSources(root.unwrap(reply.value, []));
                if (unwrapped.length > 0) {
                    root.sources = unwrapped;
                } else {
                    console.log("[WARN] explicit Get(Sources) resolved but produced no usable data:", JSON.stringify(reply.value).substring(0, 200));
                }
            },
            function (reply) {
                root.sourcesFetchInFlight = false;
                console.log("[WARN] explicit Get(Sources) call failed:", JSON.stringify(reply.error));
            }
        );
    }

    // Called from SourceSelector's sourceChosen signal - index/name are
    // already validated against the component's own model (see
    // SourceSelector.qml's onActivated), so no bounds check needed here,
    // matching FullRepresentation.qml's original onActivated body.
    function selectSource(index, name) {
        if (root.ampIp === "") return;
        root.activeSourceIndex = index;
        root.activeSourceName = name;
        root.lastSourceChangeAtMs = root.now();
        root.runCtl("source " + index);
    }

    readonly property real volumeStepDb: Plasmoid.configuration.volumeStepDb
    readonly property real volumeCeilingDb: -15.0
    readonly property real volumeFloorDb: -60.0
    readonly property string devialetCtlCommand: "devialet-ctl"

    // ---- Phase 7.5.0: action row (mute/power) state ----
    // Power/PowerState debounce - see this file's header comment for why
    // this is still needed here (no daemon-owned pending-command state for
    // Power, unlike VolumeDb/Muted) and PendingAmpState.qml's own comment
    // for why it doesn't cover this either.
    readonly property int debounceMs: 400
    property double lastPowerChangeAtMs: 0

    function now() { return Date.now(); }
    function within(lastMs, windowMs) { return (root.now() - lastMs) < windowMs; }

    function runCtl(argsString) {
        const cmd = root.devialetCtlCommand + " --ip " + root.ampIp + " " + argsString;
        console.log("running:", cmd);
        exec.connectSource(cmd);
    }

    // Button/wheel step - mirrors CompactRepresentation.qml's stepVolume()
    // exactly (Phase 5.0.2 Step B shape): reads pendingAmpState.volumeDb as
    // its base (safe because notifyVolume() writes it synchronously before
    // firing its D-Bus call, so a rapid second step still reads the value
    // this call is about to set), not a local copy.
    function stepVolume(direction) {
        if (root.ampIp === "") return;
        const base = root.pendingAmpState.volumeDb !== undefined ? root.pendingAmpState.volumeDb : root.volumeFloorDb;
        const stepped = base + direction * root.volumeStepDb;
        const clamped = Math.min(root.volumeCeilingDb, Math.max(root.volumeFloorDb, stepped));
        // Mirrors CompactRepresentation.qml's stepVolume() - a volume
        // change from any input (panel-icon scroll or the flyout's own
        // +/- buttons/slider) auto-unmutes for real, matching KDE's own
        // Audio Devices applet convention. Deliberately applied
        // consistently across every volume-adjusting input in the
        // widget, not just scroll - explicit scope decision, not an
        // oversight.
        if (root.pendingAmpState.muted) {
            root.runCtl("mute off");
            root.pendingAmpState.notifyMute(false);
        }
        root.runCtl("volume " + clamped);
        root.pendingAmpState.notifyVolume(clamped);
    }

    // Slider release - the value is already the authoritative drag result
    // (computed inside VolumeBlock from its own live value), sent as-is.
    function releaseVolume(value) {
        if (root.ampIp === "") return;
        // Same auto-unmute-on-volume-change as stepVolume() above - a
        // slider drag counts as a volume-adjusting input too.
        if (root.pendingAmpState.muted) {
            root.runCtl("mute off");
            root.pendingAmpState.notifyMute(false);
        }
        root.runCtl("volume " + value);
        root.pendingAmpState.notifyVolume(value);
    }

    // Mirrors CompactRepresentation.qml's toggleMute() exactly (Phase
    // 5.0.2 Step B shape) - reads pendingAmpState.muted directly, no local
    // mirror, no debounce (see this file's header comment).
    function toggleMute() {
        if (root.ampIp === "") return;
        const newMuted = !root.pendingAmpState.muted;
        root.runCtl("mute " + (newMuted ? "on" : "off"));
        root.pendingAmpState.notifyMute(newMuted);
    }

    // Tells the daemon a power-on boot is starting, so it can start
    // tracking BOOT_TIMEOUT (Phase 4.3.0) - ported verbatim from
    // FullRepresentation.qml. Called synchronously, back-to-back with
    // runCtl("power on") in togglePower() below, before the devialet-ctl
    // invocation - both are fire-and-forget async dispatches issued in the
    // same handler, with no wait on either one's completion in between, so
    // there's no window where the real power-on command has gone out but
    // the daemon doesn't yet know a boot is in progress.
    function beginPowerOnBoot() {
        Dbus.SessionBus.asyncCall(
            new Dbus.dbusMessage({
                service: "com.ekmanch.DevialetRemote",
                path: "/com/ekmanch/DevialetRemote/Amp",
                interface: "com.ekmanch.DevialetRemote.Amp1",
                member: "BeginPowerOnBoot",
                arguments: [root.ampIp]
            }),
            function (reply) {
                if (reply.isError) {
                    console.log("[WARN] BeginPowerOnBoot call returned a D-Bus error:", JSON.stringify(reply.error));
                }
            },
            function (reply) {
                console.log("[WARN] BeginPowerOnBoot call failed:", JSON.stringify(reply.error));
            }
        );
    }

    // Ported verbatim from FullRepresentation.qml's power button
    // onClicked. Optimistic set on both power/powerState, stamped so the
    // debounce guard in onPropertiesChanged below holds them through the
    // 400ms window - see this file's header comment for why Power still
    // needs this (unlike volume/mute).
    function togglePower() {
        if (root.ampIp === "" || root.powerState === "Booting") return;
        const newPower = !root.power;
        root.power = newPower;
        root.powerState = newPower ? "Booting" : "Off";
        root.lastPowerChangeAtMs = root.now();
        if (newPower) {
            // Told the daemon first, then the real command - see
            // beginPowerOnBoot()'s own doc for why this ordering leaves no
            // gap. Power-off stays exactly as before: immediate, no
            // daemon notification.
            root.beginPowerOnBoot();
        }
        root.runCtl("power " + (newPower ? "on" : "off"));
    }

    // Fires devialet-ctl once per connectSource() call, then disconnects
    // itself - same pattern as CompactRepresentation.qml/
    // FullRepresentation.qml's own `exec`.
    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            console.log("devialet-ctl finished - exit code:", data["exit code"], "stderr:", data["stderr"]);
            disconnectSource(source);
        }
    }

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
            root.activeSourceName = root.unwrap(properties.ActiveSourceName, "");
            root.activeSourceIndex = root.unwrap(properties.ActiveSourceIndex, -1);
            const initialSources = root.unwrapSources(root.unwrap(properties.Sources, []));
            if (initialSources.length > 0) {
                root.sources = initialSources;
            }
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
            // Phase 7.5.0: debounce guard added now that togglePower()
            // below writes these optimistically - see this file's header
            // comment for why Power/PowerState still need one (unlike
            // volume/mute, which are pendingAmpState-resolved). Both share
            // lastPowerChangeAtMs: one click drives both, so one guard is
            // enough (matches FullRepresentation.qml's own reasoning).
            if ("Power" in changed) {
                if (!root.within(root.lastPowerChangeAtMs, root.debounceMs)) {
                    root.power = root.unwrap(changed.Power, root.power);
                }
            }
            if ("PowerState" in changed) {
                if (!root.within(root.lastPowerChangeAtMs, root.debounceMs)) {
                    root.powerState = root.unwrap(changed.PowerState, root.powerState);
                }
            }
            // Phase 7.6.0: debounce guard added now that selectSource()
            // writes both of these optimistically - same reasoning as the
            // Power/PowerState guard above (one guard, one click drives
            // both), ported from FullRepresentation.qml's identical
            // treatment.
            if (("ActiveSourceIndex" in changed || "ActiveSourceName" in changed)
                && !root.within(root.lastSourceChangeAtMs, root.debounceMs)) {
                if ("ActiveSourceIndex" in changed) root.activeSourceIndex = root.unwrap(changed.ActiveSourceIndex, root.activeSourceIndex);
                if ("ActiveSourceName" in changed) root.activeSourceName = root.unwrap(changed.ActiveSourceName, root.activeSourceName);
            }
            if ("Sources" in changed) root.fetchSourcesFresh();
            if ("SelectedAmpIp" in changed) root.selectedAmpIp = root.unwrap(changed.SelectedAmpIp, root.selectedAmpIp);
            if ("KnownAmps" in changed) root.fetchKnownAmpsFresh();
        }
    }

    // ---- background tint, ported from FullRepresentation.qml:740-754.
    // Phase 7.10.0: this is now the flyout's entire visible surface. The
    // host window (FlyoutPopup.qml) is a PlasmaCore.Dialog with
    // backgroundHints: NoBackground, so there is no Plasma frame SVG
    // around this content any more - and with it went the box-in-box
    // inset math this Rectangle used to bleed outward by (a FrameSvgItem
    // measuring dialogs/background's fixedMargins minus its inset, to
    // fill the frame's transparent inner margin). Under NoBackground
    // mainItem is the whole window (Dialog's frame margins are 0 when the
    // frame image path is empty, dialog.cpp updateTheme(); measured
    // window == mainItem in the 7.9.0 spike), so a negative margin here
    // would only push the rounded corners outside the window and clip
    // them square. Edge to edge, radius as before (Phase 7.12.0 owns the
    // corner-radius question).
    Rectangle {
        anchors.fill: parent
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

        VolumeBlock {
            id: volumeBlock
            theme: root.theme
            ampIp: root.ampIp
            volumeDb: root.pendingAmpState.volumeDb
            volumeFloorDb: root.volumeFloorDb
            volumeCeilingDb: root.volumeCeilingDb
            volumeStepDb: root.volumeStepDb
            activeSourceName: root.activeSourceName
            onStepRequested: direction => root.stepVolume(direction)
            onSliderReleased: value => root.releaseVolume(value)
        }

        ActionRow {
            id: actionRow
            theme: root.theme
            ampIp: root.ampIp
            muted: root.pendingAmpState.muted
            power: root.power
            powerState: root.powerState
            onMuteToggleRequested: root.toggleMute()
            onPowerToggleRequested: root.togglePower()
        }

        SourceSelector {
            id: sourceSelector
            theme: root.theme
            ampIp: root.ampIp
            sources: root.sources
            activeSourceIndex: root.activeSourceIndex
            activeSourceName: root.activeSourceName
            onSourceChosen: (index, name) => root.selectSource(index, name)
        }

        // Plain, unconditional section divider between the source
        // selector and the footer - lives directly in mainColumn, not
        // owned by either component, matching FullRepresentation.qml's
        // own structure exactly (a bare Rectangle sibling of the source
        // ColumnLayout and footer RowLayout there too, not nested inside
        // either).
        Rectangle {
            objectName: "sourceFooterDivider"
            Layout.fillWidth: true
            height: 1
            color: root.theme.divider
        }

        Footer {
            id: footer
            theme: root.theme
            ampIp: root.ampIp
            online: root.online
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
