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
    // Phase 5.0.1: shared, root-anchored VolumeDb/Muted consumer - not
    // used by anything in this file yet (additive-only this phase, see
    // PendingAmpState.qml's own header comment). Cutover is Phase 5.0.2.
    required property PendingAmpState pendingAmpState
    // Phase 7.0.0 spike toggle, forwarded from main.qml - see that
    // file's own comment on this property. Not `required`: defaults to
    // false so nothing else instantiating this file needs to know about
    // a throwaway spike.
    property bool appletPopupSpikeEnabled: false

    // ---- Local mirror of just the D-Bus state this icon needs (see
    // header comment for why this isn't shared with FullRepresentation) ----
    property string ampIp: ""
    property string deviceName: ""
    // Phase 5.0.2 Step B: volumeDb/muted removed from this mirror -
    // Step A already redirected every display read in this file to
    // pendingAmpState.volumeDb/.muted, and pendingAmpState now also
    // covers the one remaining job these local copies had (stepVolume()/
    // toggleMute()'s own rapid-repeat accumulation base, since
    // PendingAmpState.notifyVolume()/notifyMute() write synchronously
    // before firing their D-Bus call - see that file's own comment).
    // Nothing left anywhere in this file reads either property.
    // Phase 4.5.3: source name for the tooltip/toast mockups' stat/source
    // rows - a plain string scalar like AmpIp/DeviceName (no unwrap
    // ambiguity, confirmed the same way in FullRepresentation.qml's own
    // header comment: "DeviceName/AmpIp/ActiveSourceName are s"), so no
    // debounce guard is needed - matches deviceName/ampIp above, which
    // don't have one either.
    property string activeSourceName: ""

    readonly property real volumeStepDb: Plasmoid.configuration.volumeStepDb
    readonly property real volumeCeilingDb: -15.0
    readonly property real volumeFloorDb: -60.0
    readonly property string devialetCtlCommand: "devialet-ctl"

    // Exposed for hoverTooltip's bindings below.
    readonly property string ampDisplayName: root.deviceName !== "" ? root.deviceName : "Devialet"
    readonly property string tooltipAmpName: root.ampIp === "" ? "No Amplifier" : root.ampDisplayName
    readonly property string iconSource: Plasmoid.icon

    // Phase 4.5.3: normalized 0..1 position between the same floor/ceiling
    // FullRepresentation's own volumeSlider uses (from/to), for the
    // tooltip/toast progress bars - matches that slider's own math
    // ((value - from) / (to - from)) rather than inventing new bounds.
    // Phase 5.0.2 Step A: rebased on pendingAmpState.volumeDb (the shared,
    // daemon-resolved value) instead of this file's own local optimistic
    // root.volumeDb - see PendingAmpState.qml/TODO.md for why. No
    // suppress/reactivate mechanic reads this (unlike FullRepresentation's
    // slider Binding), so the only visible effect is the intended one: the
    // toast/tooltip progress bar now catches up via the shared object like
    // everything else, instead of via this file's own local optimism.
    readonly property real volumeFraction: root.pendingAmpState.volumeDb !== undefined
        ? Math.min(1, Math.max(0, (root.pendingAmpState.volumeDb - root.volumeFloorDb) / (root.volumeCeilingDb - root.volumeFloorDb)))
        : 0

    function unwrap(prop, fallback) {
        if (prop === undefined || prop === null) return fallback;
        if (typeof prop === "object" && prop.value !== undefined) return prop.value;
        return prop;
    }

    function stepVolume(direction) {
        if (root.ampIp === "") return;
        // Phase 5.0.2 Step B: base now reads pendingAmpState.volumeDb,
        // not a local copy - safe because PendingAmpState.notifyVolume()
        // writes it synchronously before its D-Bus call, so a rapid
        // second step still reads the value this call is about to set,
        // not something stale.
        const base = root.pendingAmpState.volumeDb !== undefined ? root.pendingAmpState.volumeDb : root.volumeFloorDb;
        const stepped = base + direction * root.volumeStepDb;
        const clamped = Math.min(root.volumeCeilingDb, Math.max(root.volumeFloorDb, stepped));
        exec.connectSource(root.devialetCtlCommand + " --ip " + root.ampIp + " volume " + clamped);
        // Tells the daemon directly, so FullRepresentation (and anything
        // else reading pendingAmpState) sees this as authoritative
        // without waiting for the real amp broadcast - see
        // PendingAmpState.qml/TODO.md.
        root.pendingAmpState.notifyVolume(clamped);
        volumeToast.showVolume(root.tooltipAmpName, root.activeSourceName, clamped, root.volumeFraction);
    }

    // Phase 4.5.2: same mute-toggle logic as the flyout's own Mute button
    // (FullRepresentation.qml's onClicked, ~line 1451) - not a shared call
    // (that button's logic is inline, not an extracted function, and its
    // `root` is a different file's root - see this file's header comment
    // on why state here is an independent mirror, not shared, matching the
    // same precedent stepVolume() above already established).
    function toggleMute() {
        if (root.ampIp === "") return;
        // Phase 5.0.2 Step B: see the matching comment in stepVolume() -
        // same reasoning, reads pendingAmpState.muted instead of a local
        // copy.
        const newMuted = !root.pendingAmpState.muted;
        exec.connectSource(root.devialetCtlCommand + " --ip " + root.ampIp + " mute " + (newMuted ? "on" : "off"));
        root.pendingAmpState.notifyMute(newMuted);
        volumeToast.showMute(root.tooltipAmpName, root.activeSourceName, newMuted, root.volumeFraction);
    }

    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onClicked: mouse => {
        if (mouse.button === Qt.LeftButton) {
            // Phase 7.0.0 spike branch - see main.qml's
            // appletPopupSpikeEnabled comment. Left completely
            // unreachable, with the exact prior behavior below fully
            // intact, when the flag is false (the default).
            if (root.appletPopupSpikeEnabled) {
                flyoutPopup.visible = !flyoutPopup.visible;
            } else {
                root.plasmoidItem.expanded = !root.plasmoidItem.expanded;
            }
        } else if (mouse.button === Qt.MiddleButton) {
            root.toggleMute();
        }
    }

    // Hover show/hide timing replicates libplasma's own ToolTipArea/
    // ToolTipDialog exactly (read their source, not guessed - see
    // VolumeHoverTooltip.qml's header comment for the full citation):
    // ToolTipArea::hoverEnterEvent starts a single-shot show timer
    // (m_showTimer.start(m_interval)) rather than showing immediately;
    // ToolTipDialog::dismiss() starts a 200ms hide timer rather than
    // hiding immediately. hoverEnterEvent's "already visible -> show
    // immediately, no delay" branch (avoids flicker when quickly moving
    // between tooltip areas) has no equivalent here since there's only
    // one hover target - re-entering before hoverHideTimer fires just
    // cancels it below, which is the same practical effect for a single
    // icon.
    //
    // Phase 4.5.3 item 2 fix (follow-up round): the earlier fix only
    // reacted to the expanded->true *transition* (the Connections block
    // below), which left a gap - leaving and re-entering the icon while
    // already expanded restarted hoverShowTimer with nothing to stop it,
    // so the tooltip could reappear on top of an already-open flyout.
    // Guarding the trigger itself (both here and in hoverShowTimer's own
    // onTriggered, in case expanded flips true during the pending delay)
    // means it never shows at all while expanded, regardless of how many
    // times the mouse re-enters - not just once at the moment it opens.
    onEntered: {
        hoverHideTimer.stop();
        if (!hoverTooltip.visible && !root.plasmoidItem.expanded) {
            hoverShowTimer.restart();
        }
    }
    onExited: {
        hoverShowTimer.stop();
        if (hoverTooltip.visible) {
            hoverHideTimer.restart();
        }
    }

    Timer {
        id: hoverShowTimer
        // Kirigami.Units.toolTipDelay - the same QML-exposed value real
        // KDE apps bind QQC2 ToolTip.delay to, itself backed by the
        // global "PlasmaToolTips/Delay" KConfig entry ToolTipArea reads
        // directly (tooltiparea.cpp: cfg.readEntry("Delay", 700)) - using
        // the Kirigami property rather than reading that KConfig group
        // ourselves, since it's the standard path to the same value.
        interval: Kirigami.Units.toolTipDelay
        // Re-checked here too, not just in onEntered - expanded could
        // flip true during the pending delay itself (flyout opened via
        // some other path while the timer was already running).
        onTriggered: {
            if (!root.plasmoidItem.expanded) {
                hoverTooltip.visible = true;
            }
        }
    }
    Timer {
        id: hoverHideTimer
        interval: 200
        onTriggered: hoverTooltip.visible = false
    }

    // Phase 7.1.0: promoted from the Phase 7.0.0 spike
    // (AppletPopupSpike.qml, now removed) into the real flyout popup
    // shell - see FlyoutPopup.qml's own header comment for the real-build
    // deltas (appletInterface, hideOnWindowDeactivate) applied this
    // phase. Still only ever shown when root.appletPopupSpikeEnabled is
    // true (main.qml). Always instantiated (cheap, matches how
    // hoverTooltip/volumeToast below are always-instantiated-but-usually-
    // hidden too), but never made visible unless the flag flips it via
    // onClicked above.
    FlyoutPopup {
        id: flyoutPopup
        flyoutVisualParent: root
        plasmoidItem: root.plasmoidItem
    }

    VolumeHoverTooltip {
        id: hoverTooltip
        visualParent: root
        ampName: root.tooltipAmpName
        sourceName: root.activeSourceName
        // Phase 5.0.2 Step A: sourced from the shared pendingAmpState
        // object rather than this file's own local root.volumeDb/muted -
        // see PendingAmpState.qml/TODO.md. Safe here (unlike
        // FullRepresentation's slider): the tooltip has no suppress/
        // reactivate binding mechanic, so this is a plain, always-correct
        // reactive read with no glitch risk.
        volumeDb: root.pendingAmpState.volumeDb
        volumeFraction: root.volumeFraction
        hasAmp: root.ampIp !== ""
        // Phase 4.5.3 item 3 fix: was missing entirely, so the tooltip
        // kept showing the last dB reading instead of "Muted" - the same
        // Muted D-Bus mirror VolumeToast.showMute() already reacts to
        // (see the Dbus.Properties block below), just never wired here.
        muted: root.pendingAmpState.muted
    }

    // Phase 4.5.3 item 4 fix: the tooltip stayed open over the flyout if
    // the mouse was still hovering the icon when it opened, since nothing
    // ever told it to hide on expand - only real mouse-leave (onExited)
    // did. Target is root.plasmoidItem (a direct PlasmoidItem reference),
    // not the `Plasmoid` attached property - tried that first, matching
    // FullRepresentation.qml's own existing `Connections { target:
    // Plasmoid; function onExpandedChanged() {...} }`, but that produced
    // the exact same "no signal of the target matches the name" warning
    // already present (and apparently never fixed) at FullRepresentation.
    // qml:216 - the attached-property wrapper doesn't forward
    // expandedChanged the same way the real PlasmoidItem instance does.
    // root.plasmoidItem is that real instance (already used directly for
    // reads/writes elsewhere in this file, e.g. onClicked's
    // `root.plasmoidItem.expanded = ...`), and connecting to it directly
    // resolves the signal correctly - confirmed live, no warning.
    Connections {
        target: root.plasmoidItem
        function onExpandedChanged() {
            if (root.plasmoidItem.expanded) {
                hoverShowTimer.stop();
                hoverHideTimer.stop();
                hoverTooltip.visible = false;
            }
        }
    }

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
            root.activeSourceName = root.unwrap(properties.ActiveSourceName, "");
        }

        // Phase 5.0.2 Step B: VolumeDb/Muted branches removed - this
        // interface-level subscription still receives them on every
        // emission (unavoidable, same as PendingAmpState's own
        // subscription), just no longer processed here. Both are read
        // exclusively via root.pendingAmpState.volumeDb/.muted now.
        onPropertiesChanged: (interfaceName, changed, invalidated) => {
            if ("AmpIp" in changed) root.ampIp = root.unwrap(changed.AmpIp, root.ampIp);
            if ("DeviceName" in changed) root.deviceName = root.unwrap(changed.DeviceName, root.deviceName);
            if ("ActiveSourceName" in changed) root.activeSourceName = root.unwrap(changed.ActiveSourceName, root.activeSourceName);
        }
    }
}
