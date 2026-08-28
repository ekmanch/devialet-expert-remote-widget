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

    // ---- Phase 4.1: amp picker state ----
    // KnownAmps entries as {ip, deviceName, online, modelName} objects (raw
    // tuples unwrapped below, same shape as unwrapSources()). SelectedAmpIp
    // is a plain string scalar (like Online/DeviceName/AmpIp above) so its
    // PropertiesChanged delta is trusted directly - no fetch-on-signal
    // needed for it specifically.
    property var knownAmps: []
    property string selectedAmpIp: ""
    property bool ampListOpen: false

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

    // KnownAmps (ip, device_name, online, model_name) tuples - same
    // array-of-struct category as Sources above, so its PropertiesChanged
    // delta payload gets the same "not trustworthy on repeat updates"
    // treatment (see fetchSourcesFresh()'s doc comment for the full
    // wire-level finding this generalizes from): re-fetch via an explicit
    // Get rather than trusting `changed.KnownAmps`.
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
                // Guarded the same way as fetchSourcesFresh() - KnownAmps is
                // never pruned (daemon side), so a real transition back to
                // empty never legitimately happens once at least one amp has
                // ever been seen; only overwrite on a non-empty result so a
                // spurious empty reply can't wipe already-known amps.
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

    // Selecting an amp is fire-and-forget from QML's perspective: the
    // primary properties (DeviceName/AmpIp/Online/...) update via the
    // existing onPropertiesChanged handling above once the daemon emits,
    // same path already used for every other control in this file. This
    // phase has zero awareness of Phase 4.2's persistence work - it just
    // calls SelectAmp, exactly like it always will.
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

    // Header name/sub-text for the true "nothing selected" state
    // (root.ampIp === "" - same basis the amp-dot/None-row/other picker
    // logic already uses). Ported verbatim from the Android app
    // (devialet-expert-remote, MainActivity.updateDeviceCard() +
    // res/values/strings.xml): `device_none_selected` = "No Amplifier",
    // `device_tap_to_choose` = "Tap to connect" (lowercase "connect",
    // confirmed by reading strings.xml directly, not guessed) - previously
    // this fell through to the generic ampDisplayName ("Devialet") fallback
    // and an invented "No amp selected" string, neither of which matched
    // the app this widget ports. Deliberately distinct from the "selected
    // but not currently online" case (ampIp non-empty, deviceName empty),
    // which keeps using ampDisplayName's own "Devialet" fallback - Android's
    // equivalent there falls back to selectedName/selectedIp instead of its
    // "No Amplifier" string too (see updateDeviceCard()).
    readonly property string headerName: root.ampIp === "" ? "No Amplifier" : root.ampDisplayName
    readonly property string headerSub: root.ampIp === "" ? "Tap to connect" : (root.ampIp + " · " + (root.online ? "Connected" : "Not responding"))

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
            if ("SelectedAmpIp" in changed) root.selectedAmpIp = root.unwrap(changed.SelectedAmpIp, root.selectedAmpIp);
            if ("KnownAmps" in changed) root.fetchKnownAmpsFresh();
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
    //
    // Corner radius bug fix (found investigating design/visual_bugs'
    // corner-artifact report): this was `root.theme.radiusLg` (16) - a
    // value picked purely for our own visual design, never reconciled
    // against the *real* Dialog window's own corner shape. That real
    // shape comes from the active Plasma style's "dialogs/background"
    // frame SVG (Darkly, on this machine) - confirmed by reading
    // /usr/share/plasma/desktoptheme/darkly/dialogs/background.svg, whose
    // topleft/topright/bottomleft/bottomright corner paths AND its
    // separate mask-topleft/etc. elements (the ones actually driving the
    // window's blur-behind/mask region) draw a much tighter ~6-unit
    // quarter-circle - and independently confirmed live via a standalone
    // QML probe reading `Kirigami.Units.cornerRadius` (the theme-aware API
    // Breeze/Darkly-family styles use for exactly this convention) on this
    // system: 5, not 16. Since this Rectangle is the *only* visible
    // background layer (per the box-in-box fix above, it fully covers the
    // real Dialog background's straight edges already), its corner was the
    // one place left where our own geometry could still diverge from the
    // real window's - a 16px rounded corner cuts further into each corner
    // than the real ~5px window shape does, leaving a thin sliver of the
    // real (Darkly-colored) frame corner visible just outside our arc -
    // exactly the "faint light fringe past the rounded corner" artifact
    // reported. Fixed by reading the same live, theme-aware value instead
    // of a hardcoded design constant - stays correct if the user switches
    // Plasma styles later, not just under Darkly specifically. Only this
    // one outer-edge Rectangle changes; radiusLg/Md/Sm remain as they were
    // for internal content (buttons, chips, etc.), which never touch the
    // real window's own edge and have no such mismatch to fix.
    // Follow-up on the corner-radius fix above: after matching the radius
    // VALUE (Kirigami.Units.cornerRadius), a much fainter, contrast-only
    // seam remained at all four corners against solid dark backgrounds
    // (invisible against light/blurred-wallpaper backgrounds). Root-caused
    // by reading Darkly's actual corner path data, not guessed: the
    // "topleft" corner in dialogs/background.svg is
    // `M 0,6 H 6 V 0 C 2,0 0,2 0,6 Z` - a cubic Bezier from (6,0) to (0,6)
    // with control points (2,0)/(0,2), i.e. control-point offset c=4 from
    // each tangent point on a radius-6 corner (kappa = 4/6 = 0.667). A
    // mathematically true circular arc needs kappa = 0.5523 - Darkly's
    // corner is a deliberately custom, NON-circular curve, not a
    // suboptimal approximation of one. Qt Quick's `Rectangle.radius`, by
    // contrast, always renders a true circular arc - there is no radius
    // value that makes a true circle coincide with a differently-shaped
    // Bezier at every point along the curve, only at its two endpoints.
    // Worked out the resulting gap: at the curve's 45° midpoint the two
    // shapes diverge by ~0.36 of the SVG's own corner units, which -
    // given Kirigami.Units.cornerRadius (5) and this SVG's own corner
    // radius (6) are close enough to imply a roughly 1:1 unit mapping -
    // is sub-device-pixel at this screen's 2x scale (confirmed exactly 2,
    // not fractional, via `kscreen-doctor -o`; ruled out as a contributor
    // separately from the curve-shape finding). That matches what's
    // actually visible: not a rim/wedge any more, just a ~1px seam that
    // only shows up as antialiasing blends our translucent tint (this
    // Rectangle is alpha 0.82, not opaque - see panelGradientTop/Bottom
    // above) against high-contrast solid content behind it.
    //
    // Not fixable by further radius tuning - the mismatch is in the curve
    // family, not the radius number. Could be closed exactly with a
    // QtQuick.Shapes path replicating Darkly's own Bezier control points,
    // but that would be hardcoded to Darkly specifically and go wrong
    // silently under any other Plasma style (whose own frame SVG may use
    // yet another curve) - disproportionate for a sub-pixel artifact
    // that's already invisible against the large majority of real
    // desktop backgrounds. `antialiasing: true` made explicit below
    // (matches Qt Quick's own default for a radius>0 Rectangle, so not a
    // behavior change) so that default isn't left implicit given this is
    // exactly the kind of edge-rendering-sensitive shape where it matters
    // - left here as the deliberate stopping point, not silently dropped.
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

    // ---- Settings trigger ----
    // Opens nothing yet - Phase 4.3.0 builds the actual ConfigDialog. Wired
    // toward the standard Plasma mechanism (Plasmoid.internalAction
    // ("configure")) rather than a bespoke view-toggle, so 4.3.0 can slot
    // a real config UI in without touching this icon's click wiring again -
    // confirmed via real shipped applets (e.g. BasicAppletContainer.qml,
    // BasicPlasmoidHeading.qml in plasma-workspace) that "configure" is a
    // Plasma-internal QAction* auto-registered once metadata.json/config
    // declare a config UI, not something the applet creates itself.
    // internalAction() returns a nullptr QAction* until that exists
    // (confirmed via corebindingsplugin.qmltypes: isPointer: true, no
    // NOTIFY-guaranteed non-null) - null in QML - so `?.trigger()` is
    // required to avoid a "Cannot call method 'trigger' of null" runtime
    // warning; real Plasma code guards the exact same way
    // (BasicPlasmoidHeading.qml: `onClicked: internalAction?.trigger()`).
    // Currently a no-op in practice since no ConfigDialog exists yet.
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

    ColumnLayout {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 0

        // ---- Amp header ----
        // Clickable now (Phase 4.1): toggles root.ampListOpen, which drives
        // the collapsible amp list below. Wrapped in a plain Rectangle
        // (rather than putting a MouseArea directly inside the RowLayout,
        // where it would just occupy one layout cell instead of covering
        // the whole row) so the whole header area - dot, text, caret - is
        // one click target, matching the mockup's .amp-header{cursor:
        // pointer} covering the entire row.
        Rectangle {
            id: ampHeaderBg
            Layout.fillWidth: true
            implicitHeight: ampHeaderRow.implicitHeight + 26
            color: ampHeaderArea.containsMouse ? Qt.rgba(1, 1, 1, 0.02) : "transparent"

            RowLayout {
                id: ampHeaderRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16
                anchors.rightMargin: 40
                spacing: 10

                Rectangle {
                    id: ampDot
                    Layout.alignment: Qt.AlignVCenter
                    width: 8
                    height: 8
                    radius: 4
                    // Three states mirrored from existing D-Bus state, no new
                    // properties: no amp at all (ampIp empty - either
                    // explicitly cleared or the zero/2+-known-amps fallback,
                    // see AmpState::effective_ip) -> dashed ring, matches
                    // ".amp-dot.none"; known/selected but not currently
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
                        text: root.headerName
                        font.family: root.theme.fontDisplay
                        font.weight: Font.DemiBold
                        font.pixelSize: 14
                        color: root.theme.text
                        elide: Text.ElideRight
                    }

                    Label {
                        Layout.fillWidth: true
                        text: root.headerSub
                        font.family: root.theme.fontMono
                        font.pixelSize: 11
                        color: root.theme.textFaint
                        elide: Text.ElideRight
                    }
                }

                Label {
                    id: ampCaret
                    Layout.alignment: Qt.AlignVCenter
                    text: "⌄"
                    font.pixelSize: 11
                    color: root.ampListOpen ? root.theme.copperBright : root.theme.textFaint
                    rotation: root.ampListOpen ? 180 : 0
                    Behavior on rotation { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
            }

            MouseArea {
                id: ampHeaderArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.ampListOpen = !root.ampListOpen
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: root.theme.divider }

        // ---- Amp list (collapsible) ----
        // Bound directly to root.knownAmps - see fetchKnownAmpsFresh() for
        // how that stays fresh. clip:true + animated implicitHeight is this
        // file's equivalent of the mockup's `.amp-list{max-height:0 ->
        // max-height:220px}` transition.
        Item {
            id: ampListContainer
            Layout.fillWidth: true
            clip: true
            implicitHeight: root.ampListOpen ? Math.min(ampListColumn.implicitHeight, 220) : 0
            Behavior on implicitHeight { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            ColumnLayout {
                id: ampListColumn
                width: ampListContainer.width
                spacing: 2

                // ---- "None" row ----
                // Ported from the Android app (devialet-expert-remote,
                // MainActivity.showAmpSheet/sheet_amp_picker.xml), not
                // invented: always sits first, above a divider, above
                // whatever real amps have been heard - same position and
                // wording as noneRow/ampNoneName/ampNoneSub there ("None" /
                // "Don't connect to any amplifier"), italic name text, a
                // dedicated outline-ring dot state (dot_none/
                // dot_none_selected there - a plain, non-dashed ring "since
                // a dashed stroke on an oval shape drawable renders
                // unreliably under hardware acceleration on some API
                // levels", per that file's own comment; this port already
                // uses a plain solid-color border for the equivalent header
                // ampDot "none" state above, so no divergence here either).
                // "Selected" here mirrors Android's `noneSelected =
                // !hasSelectedAmp` - ported as root.ampIp === "" (the
                // effective/primary amp, same basis every ampOption below
                // uses for its own isCurrent), not root.selectedAmpIp
                // directly, so this correctly does NOT show as active during
                // the single-known-amp auto-select case (matching how a real
                // amp row already claims that highlight instead - see its
                // own isCurrent comment).
                Rectangle {
                    id: ampNoneOption
                    readonly property bool isCurrent: root.ampIp === ""

                    Layout.fillWidth: true
                    Layout.leftMargin: 10
                    Layout.rightMargin: 10
                    implicitHeight: ampNoneRow.implicitHeight + 16
                    radius: root.theme.radiusSm
                    color: ampNoneArea.containsMouse ? root.theme.surface2 : "transparent"

                    RowLayout {
                        id: ampNoneRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: 8
                        spacing: 9

                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            width: 7
                            height: 7
                            radius: 3.5
                            color: "transparent"
                            border.width: 1.5
                            border.color: ampNoneOption.isCurrent ? root.theme.copperBright : root.theme.textFaint
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1

                            Label {
                                Layout.fillWidth: true
                                text: "None"
                                font.family: root.theme.fontDisplay
                                font.weight: Font.DemiBold
                                font.italic: true
                                font.pixelSize: 13
                                color: ampNoneOption.isCurrent ? root.theme.copperBright : root.theme.textDim
                                elide: Text.ElideRight
                            }

                            Label {
                                Layout.fillWidth: true
                                text: "Don't connect to any amplifier"
                                font.family: root.theme.fontMono
                                font.pixelSize: 10
                                color: root.theme.textFaint
                                elide: Text.ElideRight
                            }
                        }

                        Label {
                            Layout.alignment: Qt.AlignVCenter
                            text: "✓"
                            font.pixelSize: 11
                            color: root.theme.copperBright
                            visible: ampNoneOption.isCurrent
                        }
                    }

                    MouseArea {
                        id: ampNoneArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectAmpByIp("")
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    Layout.bottomMargin: 4
                    Layout.leftMargin: 4
                    Layout.rightMargin: 4
                    height: 1
                    color: root.theme.divider
                }

                Label {
                    visible: root.knownAmps.length === 0
                    Layout.fillWidth: true
                    Layout.margins: 12
                    horizontalAlignment: Text.AlignHCenter
                    text: "No amps discovered yet"
                    font.family: root.theme.fontMono
                    font.pixelSize: 11
                    color: root.theme.textFaint
                }

                Repeater {
                    model: root.knownAmps

                    delegate: Rectangle {
                        id: ampOption
                        required property var modelData
                        // The currently effective amp (root.ampIp), not
                        // necessarily root.selectedAmpIp directly - the two
                        // diverge exactly when nothing is explicitly
                        // selected but exactly one amp is known (auto-select,
                        // see AmpState::effective_ip). Highlighting off
                        // ampIp matches "the amp actually shown in the
                        // header above", which is what the mockup's
                        // .amp-option.connected state means.
                        readonly property bool isCurrent: root.ampIp !== "" && modelData.ip === root.ampIp

                        // modelName ?: deviceName - same fallback the header
                        // above already uses (root.ampDisplayName, ultimately
                        // fed by the daemon's own `DeviceName` property) and
                        // the same fallback the design mockup's own
                        // `displayName(a){ return a.modelName || a.udpName; }`
                        // uses for BOTH the header and each amp-option row
                        // (devialet_tray_flyout_mockup.html). The daemon's
                        // `KnownAmps` deliberately keeps `deviceName` as the
                        // always-raw UDP name (see interface.rs's doc
                        // comment on `known_amps()`) specifically so a picker
                        // can show both - resolved name as the main label,
                        // raw name available for the "unresolved" subtitle
                        // tag below - which this delegate was not actually
                        // doing until this fix (it read modelData.deviceName
                        // directly as the main label, silently ignoring
                        // modelData.modelName - a regression against Phase
                        // 3.7's mDNS resolution work, since the header already
                        // did this correctly via root.ampDisplayName).
                        readonly property string displayName: modelData.modelName !== "" ? modelData.modelName : modelData.deviceName

                        Layout.fillWidth: true
                        Layout.leftMargin: 10
                        Layout.rightMargin: 10
                        implicitHeight: ampOptionRow.implicitHeight + 16
                        radius: root.theme.radiusSm
                        color: ampOptionArea.containsMouse ? root.theme.surface2 : "transparent"

                        RowLayout {
                            id: ampOptionRow
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.margins: 8
                            spacing: 9

                            Rectangle {
                                Layout.alignment: Qt.AlignVCenter
                                width: 7
                                height: 7
                                radius: 3.5
                                color: ampOption.isCurrent ? root.theme.copperBright : root.theme.textFaint
                                opacity: modelData.online ? 1.0 : 0.5
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1

                                Label {
                                    Layout.fillWidth: true
                                    text: ampOption.displayName !== "" ? ampOption.displayName : modelData.ip
                                    font.family: root.theme.fontDisplay
                                    font.weight: Font.DemiBold
                                    font.pixelSize: 13
                                    color: ampOption.isCurrent ? root.theme.copperBright : root.theme.textDim
                                    elide: Text.ElideRight
                                }

                                // ip, plus " · offline" when not currently
                                // broadcasting and/or " · name unresolved"
                                // when mDNS hasn't resolved a model name yet
                                // - the latter ported verbatim from the
                                // mockup's own amp-option-sub logic
                                // (`${a.ip}${a.modelName ? '' : ' · name
                                // unresolved'}`), which is itself commented
                                // there as mirroring
                                // AmpModelNameResolver/MainActivity.kt.
                                Label {
                                    Layout.fillWidth: true
                                    text: modelData.ip
                                        + (modelData.online ? "" : " · offline")
                                        + (modelData.modelName !== "" ? "" : " · name unresolved")
                                    font.family: root.theme.fontMono
                                    font.pixelSize: 10
                                    color: root.theme.textFaint
                                    elide: Text.ElideRight
                                }
                            }

                            Label {
                                Layout.alignment: Qt.AlignVCenter
                                text: "✓"
                                font.pixelSize: 11
                                color: root.theme.copperBright
                                visible: ampOption.isCurrent
                            }
                        }

                        MouseArea {
                            id: ampOptionArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.selectAmpByIp(ampOption.modelData.ip)
                        }
                    }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; visible: root.ampListOpen; color: root.theme.divider }

        // ---- Volume block ----
        // Ported from the Android app's setGroupEnabled()/disabledAlpha
        // (MainActivity.kt): the whole group's opacity dims to 0.4 as ONE
        // value applied to the container ("not per-child", per that file's
        // own comment on disabledAlpha) when nothing is selected, layered
        // on top of the individual controls' own `enabled: root.ampIp !==
        // ""` bindings (already present below, unchanged - those give the
        // non-interactive/disabled behavior; this opacity gives the visual
        // "nothing to control" look Android's updateConnectionState()
        // produces via the same setGroupEnabled(dialWrap, connected) call).
        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: 16
            Layout.bottomMargin: 6
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            spacing: 10
            opacity: root.ampIp === "" ? 0.4 : 1.0

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
                        // "—" (em dash) when nothing is selected, matching
                        // the Android app's `dial_no_source` string used by
                        // renderVolume()'s `!hasSelectedAmp` branch - not
                        // just the "VolumeDb hasn't arrived yet" case this
                        // condition originally covered alone. Without the
                        // ampIp check, this showed a real-looking number
                        // (e.g. clamped to volumeCeilingDb via the slider's
                        // own from/to bounds) once "None" set VolumeDb to
                        // the daemon's zero-value default - see the
                        // Binding below for the matching fix.
                        text: (root.ampIp !== "" && root.volumeDb !== undefined) ? volumeSlider.value.toFixed(1) : "—"
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
                    // Widens the click/drag hit area to match the sibling
                    // -/+ buttons' 26px row height, independent of the
                    // background delegate's 4px drawn track below - QQC2's
                    // Slider hit-tests presses against its own item bounding
                    // box (implicitHeight), not the background/handle
                    // delegate's drawn geometry. See Phase 4.2.2.
                    implicitHeight: 26
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
                        // root.ampIp === "" added alongside the pre-existing
                        // undefined check: when nothing is selected the
                        // daemon's AmpState::recompute() "None" branch sets
                        // VolumeDb to its zero-value default (0.0, not
                        // undefined - see interface.rs), which is above
                        // this slider's own `to` (volumeCeilingDb, -15) and
                        // was silently clamping the handle/value to the
                        // ceiling - showing a real-looking -15.0dB as if an
                        // amp were connected. Falls to volumeFloorDb here
                        // instead, matching Android's renderVolume()
                        // setting the dial's progress to 0 (its minimum) in
                        // the equivalent !hasSelectedAmp branch.
                        value: (root.ampIp !== "" && root.volumeDb !== undefined) ? root.volumeDb : root.volumeFloorDb
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
        // Same whole-group dim as the volume block above (Android's
        // setGroupEnabled(actionRow, connected)).
        GridLayout {
            Layout.fillWidth: true
            Layout.topMargin: 14
            Layout.bottomMargin: 4
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            columns: 2
            columnSpacing: 8
            rowSpacing: 8
            opacity: root.ampIp === "" ? 0.4 : 1.0

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
        // Same whole-group dim as the blocks above (Android's
        // setGroupEnabled(soundControls, connected) - our equivalent of the
        // "sound tab" here is just this one always-visible source row, not
        // a separate tab, so the dim is applied directly rather than the
        // container-swap Android does for its own Sound tab).
        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: 10
            Layout.bottomMargin: 14
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            spacing: 4
            opacity: root.ampIp === "" ? 0.4 : 1.0

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

                // "No source" when nothing is selected - ported from the
                // Android app's `no_source_label` string, used by
                // updateConnectionState()'s `!connected` branch for both
                // txtDialSource and txtTriggerName.
                displayText: root.ampIp === "" ? "No source" : (root.activeSourceName !== "" ? root.activeSourceName : (currentIndex >= 0 && currentIndex < model.length ? model[currentIndex].name : ""))

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
