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
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.workspace.dbus as Dbus
import org.kde.plasma.plasma5support as P5Support

ColumnLayout {
    id: root

    Layout.minimumWidth: 320
    Layout.minimumHeight: 300

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

    Label {
        text: root.online ? "Connected: " + root.deviceName : "Not connected"
    }

    RowLayout {
        Layout.fillWidth: true

        Button {
            text: "−"
            enabled: root.ampIp !== ""
            autoRepeat: true
            autoRepeatDelay: 300
            autoRepeatInterval: 100
            onPressedChanged: root.volumeInteracting = pressed
            onClicked: root.stepVolume(-1)
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
        }

        Button {
            text: "+"
            enabled: root.ampIp !== ""
            autoRepeat: true
            autoRepeatDelay: 300
            autoRepeatInterval: 100
            onPressedChanged: root.volumeInteracting = pressed
            onClicked: root.stepVolume(1)
        }
    }

    Label {
        // Bound to the slider's own live `value`, NOT root.volumeDb
        // directly - `volumeSlider.value` is always the current authoritative
        // displayed number, whether driven by external state (via the
        // Binding, while not pressed) or by the user's own drag (while
        // pressed) - so this updates continuously during a drag with no
        // wait for a D-Bus push, while the actual devialet-ctl send still
        // only happens on release (unchanged, see Slider.onPressedChanged
        // below). root.volumeDb !== undefined only gates the initial
        // "no data yet" placeholder.
        text: "Volume: " + (root.volumeDb !== undefined ? volumeSlider.value.toFixed(1) + " dB" : "—")
    }

    RowLayout {
        Layout.fillWidth: true

        Button {
            Layout.fillWidth: true
            text: root.muted ? "Unmute" : "Mute"
            enabled: root.ampIp !== ""
            onClicked: {
                const newMuted = !root.muted;
                root.muted = newMuted;
                root.lastMuteChangeAtMs = root.now();
                root.runCtl("mute " + (newMuted ? "on" : "off"));
            }
        }

        Button {
            Layout.fillWidth: true
            text: root.power ? "Power Off" : "Power On"
            enabled: root.ampIp !== ""
            onClicked: {
                const newPower = !root.power;
                root.power = newPower;
                root.lastPowerChangeAtMs = root.now();
                root.runCtl("power " + (newPower ? "on" : "off"));
            }
        }
    }

    Label {
        text: "Source:"
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
    }
}
