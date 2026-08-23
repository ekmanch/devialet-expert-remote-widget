// Phase 3: full functional controls (volume slider + step buttons, mute,
// power, source picker), default Kirigami/Plasma styling only - no mockup
// visuals yet (copper/graphite theme, fonts, blur, animation are Phase 4).
//
// D-Bus surface confirmed live via `busctl --user introspect` back in
// Phase 2 - see CLAUDE.md for the full property list. Two load-bearing
// findings from that phase, still true here:
// 1. Scalar properties other than bool arrive as {"value": X} wrapper
//    objects (sometimes bare X on later updates of the same key - both
//    tolerated by `unwrap()`); bool properties arrive as plain JS booleans.
// 2. Binding UI directly to `ampProps.properties.X` stops re-evaluating
//    after that key's first change (my own inference from observed
//    behavior, not a documented KDE bug - see Phase 2.5 notes). Workaround:
//    consume `onPropertiesChanged`/`onRefreshed` imperatively into plain
//    local QML properties (real Q_PROPERTYs with NOTIFY) and bind the UI
//    to those instead - used throughout below.
//
// Debounce behavior below is ported directly from MainActivity.kt
// (devialet-expert-remote, the Kotlin app), verified against that source
// this phase, not reconstructed from CLAUDE.md's summary alone:
// - Volume step buttons: EVERY step (single tap or each autoRepeat tick)
//   resets a single "last step at" timestamp - a sliding window, since the
//   incoming-update check always compares against the latest value. Ported
//   as `lastVolumeButtonStepAtMs` below, exactly mirroring Kotlin's
//   `lastVolumeButtonStepAtMs` / `volumeButtonDebounceMs` (100ms repeat +
//   300ms buffer = 400ms).
// - Volume slider: only sends (and only stamps a debounce timestamp) once,
//   on release - matches Kotlin's `onDragEnd`/`lastVolumeSliderReleaseAtMs`
//   exactly. Dragging itself is local-only, no sends, no timestamp
//   touches - matches Kotlin's `onDrag` (visual feedback only).
// - `userIsAdjustingVolume`: a separate boolean, true for the entire
//   duration of an active drag OR an active button hold, unconditionally
//   blocking incoming volume pushes regardless of the two timestamps above
//   - ported as `volumeInteracting` below, matching Kotlin's
//   `onDragStart`/`onDragEnd` and `startVolumeRepeat`/`stopVolumeRepeat`.
// - Mute/Power/Source debounce: the Kotlin app does NOT debounce these
//   (only volume) - but this phase's own task explicitly asks for "the
//   debounce treatment" on mute and power too, so a single-shot 400ms
//   window (like the slider-release case, no repeat/sliding concept needed
//   since these are simple one-shot toggles) is added for both, plus
//   source selection for the same reason (a source switch is at least as
//   visually jarring to have flicker back momentarily as a volume change,
//   and it triggers a forced volume change too - see below). Flagging this
//   as a deliberate addition beyond strict 1:1 Kotlin parity, not a silent
//   default.
//
// Volume range: -15.0dB ceiling is code-enforced (devialet-protocol's
// MAX_VOLUME_DB, clamped inside volume_packet() regardless of what QML
// sends - see known-gotchas.md #6). -60.0dB floor is NOT enforced anywhere
// in Rust - there is no floor in the protocol/daemon layer at all. It's a
// UI convention only, inherited from the Kotlin app's own slider bounds
// (MainActivity.kt's `minDb`/`maxDb`/`maxSteps`), used here for the same
// reason (a sensible, precedented range) rather than an arbitrary guess -
// but it is NOT a safety-critical enforced limit the way the ceiling is.
//
// Source selection: devialet-ctl's `source` subcommand already sends the
// forced -40dB follow-up volume internally (see
// crates/devialet-ctl/src/main.rs and devialet-protocol's
// SOURCE_SWITCH_VOLUME_DB) - confirmed by reading that source before
// writing this file, not assumed. QML only needs to invoke
// `devialet-ctl --ip <ip> source <index>` once; no extra volume command
// needed here.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.kirigami as Kirigami
import org.kde.ksvg as KSvg
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasmoid
import org.kde.plasma.workspace.dbus as Dbus
import org.kde.plasma.plasma5support as P5Support

// Phase 4.0: root changed from ColumnLayout to Item. Not a restructure for
// its own sake - needed so the settings-trigger and background overlay
// (see below) can be positioned/layered independently of the main
// content's vertical flow, which a ColumnLayout can't do for its direct
// children (everything in one stacks in one column, no free positioning,
// no layering). `Layout.minimumWidth/Height` from Phase 2/3 are dropped,
// not preserved-but-unused: root was never a child of another Layout
// (fullRepresentation is assigned directly, not placed inside a Layout),
// so those attached properties were already inert before this change -
// removing them doesn't alter any actual sizing behavior. Sizing is now
// implicit width (matches the mockup's fixed 300px flyout) + implicit
// height driven by mainColumn's own content height below, which is how
// Plasma's Dialog reads a mainItem's size regardless of its root type.
//
// Phase 4.0.1 (box-in-box flyout bug fix): `width` is deliberately NOT
// bound to theme.panelWidth here (only `implicitWidth` is) - confirmed via
// a live geometry trace (Component.onCompleted + onWidthChanged logging
// root's actual x/y/w/h and its full ancestor chain). At the time this fix
// was written, metadata.json still had X-Plasma-NotificationArea: true, so
// fullRepresentation was hosted inside the System Tray applet's own shared
// popup, several levels below what CLAUDE.md's architecture notes assumed
// was a PlasmaQuick::Dialog wrapping this file's root directly - it was
// actually nested under SystemTray's ExpandedRepresentation ->
// QQuickColumnLayout -> PlasmoidPopupsContainer, and THAT container was
// what root's parent actually was. That host container programmatically
// (re)bound the loaded item's width/height to its own available content
// size once the popup was shown.
//
// Architecture change (see CLAUDE.md's "why not a system tray plasmoid"
// note): NotificationArea/NotificationAreaCategory were later removed from
// metadata.json, so this plasmoid can no longer be tray-hosted at all - it
// installs as a normal panel-pinned applet (drag onto the panel via "Add
// Widgets", like Digital Clock or Compact Pager), and fullRepresentation is
// now shown via the standard non-tray popup path: a genuine top-level
// PlasmaQuick::Dialog wrapping this file's root directly, with no
// SystemTray container in between. Re-verified live after that change
// (kpackagetool6 --upgrade + plasmashell --replace, widget added to a real
// panel via the Plasma scripting API, actual click + screenshot): still no
// box-in-box, single clean panel, no back-arrow/title header - the fix
// below still holds. Root cause and reasoning kept as-is since they're
// still accurate for what the Dialog itself draws; only the hosting
// container identity changed. implicitWidth/implicitHeight are still kept
// as sizing hints for the (now-standard, not edge-case) case where the
// host doesn't override width/height directly - the host's rebind only
// touches width/height, not implicitWidth/implicitHeight.
//
// The actual "box within a box" root cause (confirmed by comparing
// against org.kde.plasma.networkmanagement's decompiled FullRepresentation
// - its root is bare `PlasmaExtras.Representation { header:
// PlasmaExtras.PlasmoidHeading {...} ... }`, no custom Rectangle
// background at all): this file's root draws its OWN separately-bordered,
// separately-rounded Rectangle as a second background, stacked on top of
// the Dialog's real background. That real background - the themed
// "dialogs/background" Plasma SVG frame - is drawn by the popup window
// itself (shared across every popup applet, tray-hosted or not; confirmed
// via plasmaquick/dialog.h and PlasmaCore's own theme, not owned or
// paintable by this KPackage) and already spans the *entire* window, edge
// to edge,
// with nothing needed from us. Stock representations never draw a second
// background at all - they let that one show through and look "flush" for
// free. Ours drew a second, independently-styled panel *inset from* that
// real background by the SVG frame's own margin/inset metrics (the
// border+shadow region every "dialogs/background" frame reserves - see
// plasmaquick/dialog.h's `margins`/`inset`: "Margins where the dialog
// background actually starts, excluding things like shadows or borders"),
// which is what produced the visible navy ring: two backgrounds, the
// outer one (the real Dialog background, full window) and the inner one
// (ours, inset by the frame's margin).
//
// Fix: don't add a second background at all - instead read that same
// "dialogs/background" SVG frame's own inset ourselves (KSvg.FrameSvgItem
// is public API, not the private org.kde.plasma.extras/private
// BackgroundMetrics.qml that PlasmaExtras.Representation uses internally
// for the equivalent trick, `collapseMarginsHint` - reimplemented here
// directly rather than restructuring this file's root around
// PlasmaExtras.Representation/Page, since that would mean reworking the
// header/contentItem/footer split for no behavioral gain over just
// bleeding this file's own tint Rectangle out by the same metrics) and
// expand our copper/graphite tint Rectangle outward by exactly that
// amount, so it paints over the *entire* solid part of the real Dialog
// background instead of sitting inset within it - one visible panel, not
// two. See dialogBackgroundInset below.
Item {
    id: root

    implicitWidth: theme.panelWidth
    implicitHeight: mainColumn.implicitHeight

    readonly property Theme theme: Theme {}

    // Public KSvg API (not the private org.kde.plasma.extras/private
    // BackgroundMetrics.qml that PlasmaExtras.Representation's
    // `collapseMarginsHint` uses internally for this exact purpose - same
    // technique, public import instead of a private one). `fixedMargins`
    // (full border+shadow region) minus `inset` (where the real dialog
    // background's solid fill starts) gives the amount our own background
    // needs to bleed outward by to reach that solid fill's true edge,
    // without also painting over the pure-shadow-only fringe beyond it -
    // exactly the formula BackgroundMetrics.getMargin() uses. Hardcoded to
    // "dialogs/background" (not conditional on window type like
    // BackgroundMetrics.qml) because this plasmoid's fullRepresentation is
    // only ever shown inside a popup Dialog - this file's root is never
    // rendered inline in Planar form factor (there's no such branch in
    // main.qml; compactRepresentation/fullRepresentation always implies a
    // click-to-open popup) - so the Planar/"widgets/background" branch
    // upstream handles doesn't apply here. This is independent of whether
    // the applet's *icon* sits in a tray or directly on a panel (see
    // CLAUDE.md - this plasmoid is panel-pinned, not tray-hosted, as of
    // the architecture change that removed X-Plasma-NotificationArea):
    // either way, opening it always means a real top-level
    // PlasmaQuick::Dialog using this same "dialogs/background" frame.
    KSvg.FrameSvgItem {
        id: dialogBg
        visible: false
        imagePath: "dialogs/background"
    }
    readonly property real insetLeft: dialogBg.fixedMargins.left - dialogBg.inset.left
    readonly property real insetTop: dialogBg.fixedMargins.top - dialogBg.inset.top
    readonly property real insetRight: dialogBg.fixedMargins.right - dialogBg.inset.right
    readonly property real insetBottom: dialogBg.fixedMargins.bottom - dialogBg.inset.bottom

    // ---- Open/close pop animation (see mockup's @keyframes pop) ----
    // Bound to Plasmoid.expanded rather than Component.onCompleted:
    // whether fullRepresentation is recreated fresh on every popup open or
    // instantiated once and reused for the process lifetime isn't
    // something this file can determine from QML alone (PlasmoidItem's
    // fullRepresentation/fullRepresentationItem split - confirmed via
    // plasmoidplugin.qmltypes - is consistent with either lifecycle, and
    // no QML-visible source was available to confirm which). Component.
    // onCompleted would only ever fire once in the reused-instance case,
    // silently breaking "plays on every open." Driving off the
    // expanded/expandedChanged signal instead works correctly either way.
    // Starts false regardless of Plasmoid.expanded's value at construction
    // time (a Timer-deferred flip to true, not a direct initial binding)
    // so there's always a real 0->1 transition to animate on first show,
    // not a same-tick jump straight to the end state.
    property bool poppedIn: false
    Component.onCompleted: poppedInTimer.start()
    Timer { id: poppedInTimer; interval: 1; onTriggered: root.poppedIn = true }
    Connections {
        target: Plasmoid
        function onExpandedChanged() { root.poppedIn = Plasmoid.expanded; }
    }

    opacity: root.poppedIn ? 1 : 0
    scale: root.poppedIn ? 1 : 0.98
    Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.2, 0.9, 0.3, 1, 1, 1] } }
    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.2, 0.9, 0.3, 1, 1, 1] } }

    readonly property real volumeStepDb: 0.5
    readonly property real volumeCeilingDb: -15.0
    readonly property real volumeFloorDb: -60.0
    readonly property int debounceMs: 400
    readonly property string devialetCtlCommand: "devialet-ctl"

    // ---- Local mirrors of D-Bus state (see header comment, finding 2) ----
    property bool online: false
    property string deviceName: ""
    property string ampIp: ""

    property var volumeDb: undefined
    property double lastVolumeButtonStepAtMs: 0
    property double lastVolumeSliderReleaseAtMs: 0
    property bool volumeInteracting: false

    property bool muted: false
    property double lastMuteChangeAtMs: 0

    property bool power: false
    property double lastPowerChangeAtMs: 0

    property int activeSourceIndex: -1
    property string activeSourceName: ""
    property var sources: []
    property double lastSourceChangeAtMs: 0

    readonly property var enabledSources: root.sources.filter(function (s) { return s.enabled; })

    function now() { return Date.now(); }
    function within(lastMs, windowMs) { return (now() - lastMs) < windowMs; }

    function unwrap(prop, fallback) {
        if (prop === undefined || prop === null) return fallback;
        if (typeof prop === "object" && prop.value !== undefined) return prop.value;
        return prop;
    }

    // Sources is an array of (name, index, enabled, selected) tuples; name
    // and index can individually be wrapped or bare per the same
    // inconsistency `unwrap()` handles - enabled/selected are always plain
    // booleans (confirmed in Phase 2).
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
    // repeat updates (see the "Sources" branch in onPropertiesChanged for
    // the full wire-level evidence) - every other property in this file
    // is a D-Bus scalar (s/b/y/d, confirmed via `busctl introspect`:
    // DeviceName/AmpIp/ActiveSourceName are s, Online/Power/Muted are b,
    // VolumeRaw/ActiveSourceIndex are y, VolumeDb is d) and decodes fine
    // from the signal itself; Sources (a(sybb)) is the only array/struct-
    // typed property here, and is the only one affected.
    //
    // Race check (verified, not assumed): the daemon's apply_and_emit()
    // (crates/devialet-remote-daemon/src/main.rs) writes
    // `*iface = new_state.clone()` as a plain synchronous statement
    // BEFORE the async block that emits any `_changed()` signal even
    // starts - so by the time literally any signal from a given update
    // has left the daemon (Sources' own signal is emitted last in that
    // function, after 9 others), the interface's state is already fully
    // updated. Separately, the `iface` binding is zbus's get_mut() guard,
    // held for the entire function - if the object server's own Get/GetAll
    // handling for an incoming request needs that same guard (the
    // standard implementation shape for this kind of interface wrapper),
    // an incoming Get arriving mid-emission would block briefly and then
    // read the fully-updated state once unblocked, not race it. Either
    // way, there's no path here to a Get reply carrying stale data. I
    // have not read zbus's own internal object-server dispatch source to
    // confirm the locking detail with 100% certainty - noting that
    // explicitly rather than asserting it as directly-verified.
    property bool sourcesFetchInFlight: false

    function fetchSourcesFresh() {
        if (root.sourcesFetchInFlight) return;
        root.sourcesFetchInFlight = true;
        Dbus.SessionBus.asyncCall(
            new Dbus.dbusMessage({
                service: "com.ekmanch.DevialetRemote",
                path: "/com/ekmanch/DevialetRemote/Amp",
                // NOTE: the object-literal key must be "interface", not the
                // "iface" alias used everywhere else in this file (e.g.
                // Dbus.Properties.iface) - confirmed empirically:
                // DBusMessage's QVariantMap constructor silently left
                // "iface" unset (logged the constructed message's own
                // properties and saw iface come back empty), while
                // "interface" applies correctly. Likely reads the literal
                // C++ property name rather than going through the
                // QML-exposed alias - not confirmed by reading the
                // constructor's source, just observed behavior.
                interface: "org.freedesktop.DBus.Properties",
                member: "Get",
                arguments: ["com.ekmanch.DevialetRemote.Amp1", "Sources"]
            }),
            function (reply) {
                root.sourcesFetchInFlight = false;
                // `reply` is the full DBusPendingReply-shaped object, not
                // the value directly - confirmed empirically the same way
                // as the interface/iface issue above (logged its JSON
                // shape before assuming). The actual Get() return value is
                // reply.value.
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

    function runCtl(argsString) {
        const cmd = root.devialetCtlCommand + " --ip " + root.ampIp + " " + argsString;
        console.log("running:", cmd);
        exec.connectSource(cmd);
    }

    // ---- Phase 4.0 presentational-only helpers (no new D-Bus/backend
    // state - pure derivations of properties that already existed before
    // this phase) ----

    // "Devialet Expert 140 Pro" style names already come from the daemon
    // as-is (see CLAUDE.md's Phase 3.7 note: DeviceName is
    // modelName-or-udpName) - nothing to derive here beyond what
    // deviceName already is, kept as a named readonly for clarity at each
    // call site below.
    readonly property string ampDisplayName: root.deviceName !== "" ? root.deviceName : "Devialet"

    function stepVolume(direction) {
        const base = root.volumeDb !== undefined ? root.volumeDb : root.volumeFloorDb;
        const stepped = base + direction * root.volumeStepDb;
        const clamped = Math.min(root.volumeCeilingDb, Math.max(root.volumeFloorDb, stepped));
        root.volumeDb = clamped;
        root.lastVolumeButtonStepAtMs = root.now();
        root.runCtl("volume " + clamped);
    }

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
            root.volumeDb = root.unwrap(properties.VolumeDb, undefined);
            root.muted = root.unwrap(properties.Muted, false);
            root.power = root.unwrap(properties.Power, false);
            root.activeSourceIndex = root.unwrap(properties.ActiveSourceIndex, -1);
            root.activeSourceName = root.unwrap(properties.ActiveSourceName, "");
            // Guarded the same way as the onPropertiesChanged Sources
            // branch below (see its comment) - only overwrite if real
            // data comes back.
            const initialSources = root.unwrapSources(root.unwrap(properties.Sources, []));
            if (initialSources.length > 0) {
                root.sources = initialSources;
            }
        }

        onPropertiesChanged: (interfaceName, changed, invalidated) => {
            if ("Online" in changed) root.online = root.unwrap(changed.Online, root.online);
            if ("DeviceName" in changed) root.deviceName = root.unwrap(changed.DeviceName, root.deviceName);
            if ("AmpIp" in changed) root.ampIp = root.unwrap(changed.AmpIp, root.ampIp);

            if ("VolumeDb" in changed) {
                const blocked = root.volumeInteracting
                    || root.within(root.lastVolumeButtonStepAtMs, root.debounceMs)
                    || root.within(root.lastVolumeSliderReleaseAtMs, root.debounceMs);
                if (!blocked) root.volumeDb = root.unwrap(changed.VolumeDb, root.volumeDb);
            }
            if ("Muted" in changed) {
                if (!root.within(root.lastMuteChangeAtMs, root.debounceMs)) {
                    root.muted = root.unwrap(changed.Muted, root.muted);
                }
            }
            if ("Power" in changed) {
                if (!root.within(root.lastPowerChangeAtMs, root.debounceMs)) {
                    root.power = root.unwrap(changed.Power, root.power);
                }
            }
            if (("ActiveSourceIndex" in changed || "ActiveSourceName" in changed)
                && !root.within(root.lastSourceChangeAtMs, root.debounceMs)) {
                if ("ActiveSourceIndex" in changed) root.activeSourceIndex = root.unwrap(changed.ActiveSourceIndex, root.activeSourceIndex);
                if ("ActiveSourceName" in changed) root.activeSourceName = root.unwrap(changed.ActiveSourceName, root.activeSourceName);
            }
            if ("Sources" in changed) {
                // Root-caused with wire-level evidence (busctl monitor
                // independent of QML, plus the daemon's own source code -
                // see fetchSourcesFresh()'s doc comment for the full
                // finding): the PropertiesChanged signal's own delta
                // payload is not trustworthy for this specific
                // array-of-struct property, even though the wire data
                // behind it is always correct. Rather than trust
                // `changed.Sources`, treat the signal only as a trigger:
                // explicitly re-fetch the authoritative current value via
                // a real Get call. Still entirely push-driven - the
                // signal is what causes the fetch, no polling/timer
                // involved - it just stops trusting data embedded in the
                // signal itself for this one property.
                root.fetchSourcesFresh();
            }
        }
    }

    // Fires devialet-ctl once per connectSource() call, then disconnects
    // itself - confirmed pattern from Phase 2 (luisbocanegra.panel.colorizer's
    // RunCommand.qml).
    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            console.log("devialet-ctl finished - exit code:", data["exit code"], "stderr:", data["stderr"]);
            disconnectSource(source);
        }
    }

    // ---- Background overlay ----
    // Plasmoid.backgroundHints deliberately left unset (default) so
    // Plasma's own Dialog draws its normal themed background underneath -
    // that's what actually carries genuine KWin blur-behind (confirmed by
    // reading PlasmaQuick::Dialog's header: backgroundHints' doc comment
    // states NoBackground is what loses "kwin side shadows and blur",
    // implying the default keeps them - and no QML-exposed
    // KWindowEffects::enableBlurBehind exists in org.kde.kwindowsystem's
    // QML module to request it manually, confirmed by reading its
    // qmltypes, so a fully custom-drawn background would lose blur with no
    // way to compensate without C++). This Rectangle is layered on TOP of
    // that (real, live) blurred backdrop as a semi-transparent copper/
    // graphite tint, mirroring the mockup's own technique exactly
    // (`.flyout.blur-enabled` is backdrop-filter:blur PLUS a semi-
    // transparent gradient, not blur alone) - reviewed and confirmed as
    // the chosen approach before implementing, not picked silently.
    //
    // Bled outward by root.insetLeft/Top/Right/Bottom (see root's
    // dialogBg/inset properties above) rather than plain anchors.fill -
    // this is the actual box-in-box fix. Without the bleed, this Rectangle
    // sits exactly at root's own bounds, which are inset from the real
    // Dialog background by the theme's "dialogs/background" frame margin,
    // producing a second, visibly smaller panel nested inside the real
    // one. Bleeding outward by that same margin makes this the *only*
    // visible panel, flush with the real Dialog background's own solid
    // edge - matching how stock representations look flush (they just
    // never draw a second background to begin with).
    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -root.insetLeft
        anchors.topMargin: -root.insetTop
        anchors.rightMargin: -root.insetRight
        anchors.bottomMargin: -root.insetBottom
        radius: root.theme.radiusLg
        border.width: 1
        border.color: root.theme.divider
        gradient: Gradient {
            GradientStop { position: 0.0; color: root.theme.panelGradientTop }
            GradientStop { position: 1.0; color: root.theme.panelGradientBottom }
        }
    }

    // ---- Settings trigger ----
    // Opens nothing yet - Phase 4.3 builds the actual settings view. Wired
    // as an explicit no-op (not left silently unwired) so it's obvious
    // this is deliberately deferred, not forgotten.
    Rectangle {
        id: settingsTrigger
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 10
        width: 24
        height: 24
        radius: root.theme.radiusSm
        color: settingsTriggerArea.containsMouse ? root.theme.surface2 : "transparent"
        z: 10

        Label {
            anchors.centerIn: parent
            text: "⋯" // "⋯"
            font.pixelSize: 15
            color: settingsTriggerArea.containsMouse ? root.theme.copperBright : root.theme.textFaint
        }

        MouseArea {
            id: settingsTriggerArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                // TODO(Phase 4.3): open the settings view. No-op for now -
                // out of scope for Phase 4.0's pure visual pass.
            }
        }
    }

    ColumnLayout {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 0

        // ---- Amp header ----
        // Static display only this phase - no caret, no click handler.
        // The mockup's clickable dropdown-to-amp-list behavior is Phase
        // 4.1's job, built against the existing KnownAmps/SelectedAmpIp/
        // SelectAmp D-Bus surface (Phase 3.5) - deliberately not started
        // here.
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 14
            Layout.bottomMargin: 12
            Layout.leftMargin: 16
            Layout.rightMargin: 40
            spacing: 10

            Rectangle {
                id: ampDot
                Layout.alignment: Qt.AlignVCenter
                width: 8
                height: 8
                radius: 4
                // Three states mirrored from existing D-Bus state, no new
                // properties: no amp at all (ampIp empty) -> dashed ring,
                // matches ".amp-dot.none"; known but not currently
                // broadcasting -> dim; broadcasting -> bright copper dot,
                // dimmed further while powered off (mockup's
                // togglePower() -> ampDot opacity 0.3).
                color: root.ampIp === "" ? "transparent" : (root.online ? root.theme.copperBright : root.theme.textFaint)
                border.width: root.ampIp === "" ? 1.5 : 0
                border.color: root.theme.textFaint
                opacity: root.online && !root.power ? 0.3 : 1.0
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Label {
                    Layout.fillWidth: true
                    text: "DEVIALET"
                    font.family: root.theme.fontMono
                    font.pixelSize: 10
                    font.letterSpacing: 1.2
                    color: root.theme.textFaint
                    elide: Text.ElideRight
                }

                Label {
                    Layout.fillWidth: true
                    text: root.ampDisplayName
                    font.family: root.theme.fontDisplay
                    font.weight: Font.DemiBold
                    font.pixelSize: 14
                    color: root.theme.text
                    elide: Text.ElideRight
                }

                Label {
                    Layout.fillWidth: true
                    text: root.ampIp === "" ? "No amp selected" : root.ampIp + " · " + (root.online ? "Connected" : "Not responding")
                    font.family: root.theme.fontMono
                    font.pixelSize: 11
                    color: root.theme.textFaint
                    elide: Text.ElideRight
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: root.theme.divider }

        // ---- Volume block ----
        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: 16
            Layout.bottomMargin: 6
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            spacing: 10

            RowLayout {
                Layout.fillWidth: true

                RowLayout {
                    spacing: 0
                    Layout.alignment: Qt.AlignBaseline

                    Label {
                        // See the pre-existing comment on volumeSlider.value
                        // below (unchanged from Phase 3) for why this binds
                        // to the slider's live value, not root.volumeDb
                        // directly.
                        text: root.volumeDb !== undefined ? volumeSlider.value.toFixed(1) : "—"
                        font.family: root.theme.fontMono
                        font.weight: Font.Medium
                        font.pixelSize: 26
                        color: root.theme.copperBright
                    }
                    Label {
                        text: "dB"
                        font.pixelSize: 12
                        color: root.theme.textDim
                        Layout.leftMargin: 3
                    }
                }

                Item { Layout.fillWidth: true }

                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    radius: 999
                    color: root.theme.surface
                    border.width: 1
                    border.color: root.theme.divider
                    implicitWidth: sourceChipLabel.implicitWidth + 18
                    implicitHeight: sourceChipLabel.implicitHeight + 6

                    Label {
                        id: sourceChipLabel
                        anchors.centerIn: parent
                        text: root.activeSourceName !== "" ? root.activeSourceName : "—"
                        font.family: root.theme.fontMono
                        font.pixelSize: 11
                        color: root.theme.textFaint
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Button {
                    text: "−"
                    enabled: root.ampIp !== ""
                    autoRepeat: true
                    autoRepeatDelay: 300
                    autoRepeatInterval: 100
                    onPressedChanged: root.volumeInteracting = pressed
                    onClicked: root.stepVolume(-1)

                    implicitWidth: 26
                    implicitHeight: 26
                    background: Rectangle {
                        radius: root.theme.radiusSm
                        color: root.theme.surface
                        border.width: 1
                        border.color: parent.hovered ? root.theme.copperDim : root.theme.divider
                    }
                    contentItem: Label {
                        text: parent.text
                        font.family: root.theme.fontDisplay
                        font.weight: Font.DemiBold
                        font.pixelSize: 14
                        color: parent.hovered ? root.theme.copperBright : root.theme.text
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Slider {
                    id: volumeSlider
                    Layout.fillWidth: true
                    from: root.volumeFloorDb
                    to: root.volumeCeilingDb
                    stepSize: root.volumeStepDb
                    enabled: root.ampIp !== ""

                    // External state drives `value` except while the user is
                    // actively dragging - standard QML idiom for "live data feeds a
                    // control the user can also directly manipulate" (avoids the
                    // imperative-assignment-breaks-binding trap of binding `value`
                    // straight to root.volumeDb).
                    Binding {
                        target: volumeSlider
                        property: "value"
                        value: root.volumeDb !== undefined ? root.volumeDb : root.volumeFloorDb
                        when: !volumeSlider.pressed
                    }

                    onPressedChanged: {
                        root.volumeInteracting = pressed;
                        if (!pressed) {
                            root.lastVolumeSliderReleaseAtMs = root.now();
                            root.volumeDb = volumeSlider.value;
                            root.runCtl("volume " + volumeSlider.value);
                        }
                    }

                    background: Rectangle {
                        x: volumeSlider.leftPadding
                        y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                        implicitHeight: 4
                        width: volumeSlider.availableWidth
                        height: 4
                        radius: 999
                        color: root.theme.surface3

                        Rectangle {
                            width: volumeSlider.visualPosition * parent.width
                            height: parent.height
                            radius: 999
                            color: root.theme.copper
                        }
                    }

                    handle: Rectangle {
                        x: volumeSlider.leftPadding + volumeSlider.visualPosition * (volumeSlider.availableWidth - width)
                        y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                        width: 15
                        height: 15
                        radius: 999
                        color: root.theme.copperBright
                    }
                }

                Button {
                    text: "+"
                    enabled: root.ampIp !== ""
                    autoRepeat: true
                    autoRepeatDelay: 300
                    autoRepeatInterval: 100
                    onPressedChanged: root.volumeInteracting = pressed
                    onClicked: root.stepVolume(1)

                    implicitWidth: 26
                    implicitHeight: 26
                    background: Rectangle {
                        radius: root.theme.radiusSm
                        color: root.theme.surface
                        border.width: 1
                        border.color: parent.hovered ? root.theme.copperDim : root.theme.divider
                    }
                    contentItem: Label {
                        text: parent.text
                        font.family: root.theme.fontDisplay
                        font.weight: Font.DemiBold
                        font.pixelSize: 14
                        color: parent.hovered ? root.theme.copperBright : root.theme.text
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            Label {
                Layout.fillWidth: true
                Layout.topMargin: 9
                horizontalAlignment: Text.AlignHCenter
                // Decorative only in this phase - matches the mockup's
                // text (adjusted from "tray icon" to "panel icon": this
                // plasmoid is panel-pinned, not tray-hosted - see CLAUDE.md),
                // but scroll-over-icon volume control itself is Phase 4.4's
                // job, not implemented here. Don't read this label's
                // presence as that feature already working.
                text: "Scroll over the panel icon to adjust"
                font.family: root.theme.fontMono
                font.pixelSize: 10
                color: root.theme.textFaint
            }
        }

        // ---- Action row ----
        GridLayout {
            Layout.fillWidth: true
            Layout.topMargin: 14
            Layout.bottomMargin: 4
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            columns: 2
            columnSpacing: 8
            rowSpacing: 8

            Button {
                Layout.fillWidth: true
                Layout.preferredHeight: 38
                enabled: root.ampIp !== ""
                onClicked: {
                    const newMuted = !root.muted;
                    root.muted = newMuted;
                    root.lastMuteChangeAtMs = root.now();
                    root.runCtl("mute " + (newMuted ? "on" : "off"));
                }

                background: Rectangle {
                    radius: root.theme.radiusMd
                    color: root.muted ? Qt.rgba(root.theme.copper.r, root.theme.copper.g, root.theme.copper.b, 0.14) : root.theme.surface
                    border.width: 1
                    border.color: root.muted ? root.theme.copperDim : (parent.hovered ? root.theme.copperDim : root.theme.divider)
                }
                contentItem: RowLayout {
                    spacing: 6
                    Item { Layout.fillWidth: true }
                    Kirigami.Icon {
                        implicitWidth: 13
                        implicitHeight: 13
                        source: "audio-volume-muted-symbolic"
                        color: root.muted ? root.theme.copperBright : root.theme.text
                    }
                    Label {
                        text: root.muted ? "Unmute" : "Mute"
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        color: root.muted ? root.theme.copperBright : root.theme.text
                    }
                    Item { Layout.fillWidth: true }
                }
            }

            Button {
                Layout.fillWidth: true
                Layout.preferredHeight: 38
                enabled: root.ampIp !== ""
                onClicked: {
                    const newPower = !root.power;
                    root.power = newPower;
                    root.lastPowerChangeAtMs = root.now();
                    root.runCtl("power " + (newPower ? "on" : "off"));
                }

                background: Rectangle {
                    radius: root.theme.radiusMd
                    color: root.theme.surface
                    border.width: 1
                    border.color: parent.hovered ? root.theme.danger : root.theme.divider
                }
                contentItem: RowLayout {
                    spacing: 6
                    Item { Layout.fillWidth: true }
                    Kirigami.Icon {
                        implicitWidth: 13
                        implicitHeight: 13
                        source: "system-shutdown-symbolic"
                        color: root.theme.text
                    }
                    Label {
                        text: root.power ? "Power Off" : "Power On"
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        color: root.theme.text
                    }
                    Item { Layout.fillWidth: true }
                }
            }
        }

        // ---- Source block ----
        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: 10
            Layout.bottomMargin: 14
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            spacing: 4

            Label {
                text: "SOURCE"
                font.family: root.theme.fontMono
                font.pixelSize: 10
                font.letterSpacing: 1
                color: root.theme.textFaint
            }

            // Uses org.kde.plasma.components' ComboBox, not QtQuick.Controls'
    // (which is what every other control in this file still uses) -
    // deliberate, not a stray import. Evidence, checked rather than
    // asserted:
    // 1. Every ComboBox usage across every plasmoid installed on this
    //    machine (org.kde.desktopcontainment, luisbocanegra.panel.colorizer,
    //    org.kde.plasma.advanced-weather-widget, etc.) appears ONLY inside
    //    a separate settings/config dialog, never inside the applet's own
    //    popup/flyout content - checked via grep across
    //    /usr/share/plasma/plasmoids and ~/.local/share/plasma/plasmoids,
    //    not a single counterexample found.
    // 2. PlasmaComponents3's own ComboBox.qml
    //    (/usr/lib/qt6/qml/org/kde/plasma/components/ComboBox.qml) contains
    //    an explicit source comment acknowledging this exact category of
    //    problem: "HACK: When the ComboBox is not inside a top-level
    //    Window, its Popup does not inherit the LayoutMirroring options."
    //    - linking QTBUG-66446 - and works around it by overriding
    //    LayoutMirroring itself, plus supplying its own popup/background
    //    entirely rather than relying on QQC2's default Popup+Overlay
    //    machinery. A Plasma applet's fullRepresentation is hosted inside
    //    Plasma's own Dialog window, not a plain top-level
    //    ApplicationWindow - exactly the condition this comment describes.
    // This is real, checkable KDE source-code evidence for "QQC2 ComboBox's
    // popup has known problems outside a genuine top-level Window," which
    // covers a Plasma popup - it is NOT a citation of the *exact* symptom
    // originally reported (popup failing to open at all), which I could
    // not find independently documented anywhere (bounded search: general
    // web, bugs.kde.org).
    //
    // Separately: the popup-not-opening symptom this component switch
    // fixed is NOT the same root cause as the earlier displayText bug
    // (that was selected-text rendering, with the popup opening fine even
    // in plasmawindowed; this was the popup failing to open at all, a
    // regression that only showed up once this ComboBox switch itself
    // exposed a second, unrelated bug - see the enabled/model source below
    // - so the two are separate issues that happened to compound, not the
    // same cause twice). The displayText override is kept below
    // regardless, since it's still correct and harmless with this
    // component too.
            // Restyled via background/contentItem/indicator only - popup/
            // delegate deliberately untouched, that's the Phase 3 hard-won
            // fix (see comment above); all bindings/onActivated logic below
            // are unchanged from Phase 3, not touched by this phase.
            PlasmaComponents3.ComboBox {
                id: sourceCombo
                Layout.fillWidth: true
                enabled: root.ampIp !== "" && root.enabledSources.length > 0
                textRole: "name"
                model: root.enabledSources

                currentIndex: {
                    for (var i = 0; i < root.enabledSources.length; i++) {
                        if (root.enabledSources[i].index === root.activeSourceIndex) return i;
                    }
                    return -1;
                }

                displayText: root.activeSourceName !== "" ? root.activeSourceName : (currentIndex >= 0 && currentIndex < model.length ? model[currentIndex].name : "")

                // `activated` fires only on genuine user interaction (mouse/
                // keyboard selection), not on the programmatic `currentIndex`
                // binding above - avoids a feedback loop.
                onActivated: (idx) => {
                    if (idx < 0 || idx >= root.enabledSources.length) return;
                    const chosen = root.enabledSources[idx];
                    root.activeSourceIndex = chosen.index;
                    root.activeSourceName = chosen.name;
                    root.lastSourceChangeAtMs = root.now();
                    root.runCtl("source " + chosen.index);
                }

                implicitHeight: 42
                background: Rectangle {
                    radius: root.theme.radiusMd
                    color: root.theme.surface
                    border.width: 1
                    border.color: sourceCombo.hovered ? root.theme.copperDim : root.theme.divider
                }
                contentItem: RowLayout {
                    spacing: 10
                    // Matches inset/spacing roughly - ComboBox's own
                    // leftPadding still applies around this contentItem.
                    Rectangle {
                        Layout.preferredWidth: 24
                        Layout.preferredHeight: 24
                        radius: root.theme.radiusSm
                        color: root.theme.surface3
                        Label {
                            anchors.centerIn: parent
                            text: "◉"
                            font.pixelSize: 12
                            color: root.theme.copperBright
                        }
                    }
                    Label {
                        Layout.fillWidth: true
                        text: sourceCombo.displayText
                        font.family: root.theme.fontDisplay
                        font.weight: Font.DemiBold
                        font.pixelSize: 13
                        color: root.theme.text
                        elide: Text.ElideRight
                    }
                }
                indicator: Label {
                    x: sourceCombo.width - width - 10
                    y: sourceCombo.topPadding + (sourceCombo.availableHeight - height) / 2
                    text: "⌄"
                    font.pixelSize: 11
                    color: root.theme.textFaint
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: root.theme.divider }

        // ---- Footer ----
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 9
            Layout.bottomMargin: 11
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            Layout.alignment: Qt.AlignHCenter

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                width: 5
                height: 5
                radius: 2.5
                color: root.online ? root.theme.copperBright : root.theme.textFaint
            }

            Label {
                Layout.leftMargin: 5
                text: root.ampIp === "" ? "Not connected" : (root.online ? "Connected" : "Not responding")
                font.family: root.theme.fontMono
                font.pixelSize: 10
                color: root.theme.textFaint
            }
        }
    }
}
