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
// writer. Phase 8.0.1 wires the configured startup volume into both
// selectSource() (same-invocation `--startup-volume-db`) and a deferred
// send after a widget-initiated power-on (`pendingStartupVolumeIp` /
// `startupVolumeTimer` / `sendStartupVolume()`, documented at that
// block), arming PendingAmpState's post-boot display hold on "On".

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
    // Shared, root-anchored volume-range config (floor/hard-limit/step/
    // startup dB) - see VolumeSettings.qml's own header comment. Replaces
    // this file's former local volumeStepDb/volumeCeilingDb/volumeFloorDb
    // properties, which independently duplicated CompactRepresentation.
    // qml's own copy of the same three numbers.
    required property VolumeSettings volumeSettings
    // Shared, root-anchored transparency alpha (Phase 9.1.0) - see
    // TransparencySettings.qml's own header comment. Drives the panel
    // tint gradient below.
    required property TransparencySettings transparencySettings
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

    // Called from SourceListOverlay's sourceChosen signal - index/name are
    // already validated against the overlay's own model (see
    // SourceListOverlay.qml's onClicked), so no bounds check needed here,
    // matching FullRepresentation.qml's original onActivated body.
    function selectSource(index, name) {
        // Power gate (2026-09-08 follow-up) - the row is already inert
        // unless "On" (SourceSelector.interactive); repeated here for the
        // overlay's own click path.
        if (root.ampIp === "" || root.powerState !== "On") return;
        root.activeSourceIndex = index;
        root.activeSourceName = name;
        root.lastSourceChangeAtMs = root.now();
        // Phase 8.0.1: the configured startup volume replaces the CLI's
        // hardcoded -40 as the forced post-switch volume (known-gotchas
        // #5). Pre-clamped here to [floor, hardLimit] like every other
        // volume-set path (Phase 8.4.0's invariant; nothing downstream
        // would re-apply the floor), and the CLI applies the ceiling again
        // itself - the same defense-in-depth as Phase 8.1.0. Sent in the
        // same invocation as the switch: Gate #1 (2026-09-07) honored the
        // zero-delay source+volume pair 6/6 on the real amp. Then the same
        // notifyVolume() step every other volume-set call site does, so
        // the flyout/OSD/tooltip show the post-switch volume at once.
        const target = root.volumeSettings.clamp(root.volumeSettings.startupVolumeDb);
        root.runCtl("source " + index + " --hard-limit-db " + root.volumeSettings.hardLimitDb
                    + " --startup-volume-db " + target);
        root.pendingAmpState.notifyVolume(target);
    }

    readonly property string devialetCtlCommand: "devialet-ctl"

    // ---- Chime spike (branch spike/volume-audio-feedback, see TODO.md) ----
    // One gain-compensated chime per discrete step, only while the PC is
    // the amp's source (Optical 1 - the PC -> HDMI -> TV -> optical path).
    // The binary does the math; QML supplies the two dB values it already
    // holds: the optimistic target (the OSD's own number) and the amp's
    // real last-broadcast dB (pendingAmpState.confirmedVolumeDb, decoded
    // from the daemon's unmasked VolumeRaw).
    readonly property string chimeCommand: "devialet-chime"
    // Round-robin pool of DataSources, not one reused id (owner decision):
    // KDE's Audio Devices tone plays via libcanberra, which spawns a fresh
    // stream per trigger so rapid triggers overlap and mix instead of
    // interrupting each other. Tick N uses chimePool[N % length]. Four
    // slots: the chime is 0.30 s and even ~10 ticks/s leaves at most 3 in
    // flight. The `--tick` argument makes every command string unique -
    // Plasma's executable engine is shared process-wide and keys running
    // jobs by command string, so two ticks with identical dB arguments
    // would otherwise collapse into one process regardless of the pool.
    readonly property var chimePool: [chimeExec0, chimeExec1, chimeExec2, chimeExec3]
    property int chimeTick: 0

    // Gate on the amp's live broadcast name, trimmed + lowercased (Theme.qml
    // sourceGlyph() keyword-match precedent; never by index - see
    // crates/protocol command.rs). Any other source: no chime at all.
    function isPcSourceActive() {
        return String(root.activeSourceName || "").trim().toLowerCase() === "optical 1";
    }

    function maybeChime(targetDb) {
        // Phase 10.1.2: the ConfigDialog's master toggle (main.xml
        // chimeEnabled, forwarded via VolumeSettings). Checked first so an
        // off toggle never spawns devialet-chime at all - not a silenced
        // or gained-down run, no process.
        if (!root.volumeSettings.chimeEnabled) return;
        if (!root.isPcSourceActive()) return;
        const confirmed = root.pendingAmpState.confirmedVolumeDb;
        if (typeof confirmed !== "number" || typeof targetDb !== "number") return;
        const slot = root.chimeTick % root.chimePool.length;
        const cmd = root.chimeCommand + " --target-db " + targetDb.toFixed(1)
            + " --confirmed-db " + confirmed.toFixed(1) + " --tick " + root.chimeTick;
        root.chimeTick += 1;
        console.log("devialet-chime[" + slot + "] running:", cmd);
        root.chimePool[slot].connectSource(cmd);
    }

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
        // Power gate (2026-09-08 follow-up): VolumeBlock already disables
        // its inputs unless powerState === "On" (see its `interactive`);
        // this repeats the check for autoRepeat ticks already queued when
        // the state flips, and mirrors CompactRepresentation.stepVolume().
        if (root.ampIp === "" || root.powerState !== "On") return;
        // Step/clamp math now lives in VolumeSettings.stepped() - see that
        // file's header comment.
        const clamped = root.volumeSettings.stepped(root.pendingAmpState.volumeDb, direction);
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
        root.runCtl("volume " + clamped + " --hard-limit-db " + root.volumeSettings.hardLimitDb);
        root.pendingAmpState.notifyVolume(clamped);
        // Chime spike: one attempted chime per discrete step, no debounce
        // (Phase 10.0.0 Finding 3). Reached by the flyout slider's wheel
        // notches AND the +/- buttons (both emit VolumeBlock.stepRequested);
        // releaseVolume() below deliberately does not chime.
        root.maybeChime(clamped);
    }

    // Slider release - the value is the drag result computed inside
    // VolumeBlock from its own live value (bounded by the Slider's own
    // from/to already), but now also passed through the same shared
    // clamp() every other volume-adjusting path uses - defense-in-depth so
    // no dB value this widget sends ever depends solely on the Slider's
    // own bounds being correct, matching the Rust protocol crate's own
    // "clamp internally, don't trust the caller" convention.
    function releaseVolume(value) {
        if (root.ampIp === "" || root.powerState !== "On") return;
        const clamped = root.volumeSettings.clamp(value);
        // Same auto-unmute-on-volume-change as stepVolume() above - a
        // slider drag counts as a volume-adjusting input too.
        if (root.pendingAmpState.muted) {
            root.runCtl("mute off");
            root.pendingAmpState.notifyMute(false);
        }
        root.runCtl("volume " + clamped + " --hard-limit-db " + root.volumeSettings.hardLimitDb);
        root.pendingAmpState.notifyVolume(clamped);
    }

    // Mirrors CompactRepresentation.qml's toggleMute() exactly (Phase
    // 5.0.2 Step B shape) - reads pendingAmpState.muted directly, no local
    // mirror, no debounce (see this file's header comment).
    function toggleMute() {
        // Power gate (2026-09-08 follow-up) - see ActionRow.muteInteractive.
        if (root.ampIp === "" || root.powerState !== "On") return;
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
        // Phase 8.0.1: arm (or, on a power-off click, disarm) the
        // post-boot startup volume - see the block after this function.
        // After the optimistic assignments: the "Booting" they trigger in
        // onPowerStateChanged is a no-op there anyway.
        if (newPower) {
            root.pendingStartupVolumeIp = root.ampIp;
        } else {
            root.pendingStartupVolumeIp = "";
            startupVolumeTimer.stop();
            root.pendingAmpState.endBootHold();
        }
        if (newPower) {
            // Told the daemon first, then the real command - see
            // beginPowerOnBoot()'s own doc for why this ordering leaves no
            // gap. Power-off stays exactly as before: immediate, no
            // daemon notification.
            root.beginPowerOnBoot();
        }
        root.runCtl("power " + (newPower ? "on" : "off"));
    }

    // ---- Phase 8.0.1: startup volume after a widget-initiated power-on ----
    // Owner decision (TODO.md Phase 8.0.1): widget-initiated power-on only;
    // an external power-on (remote, front panel) is deliberately not
    // covered. Entirely in QML, no daemon/D-Bus change: the daemon's
    // existing PowerState ("Off"/"Booting"/"On", Phase 4.3.0's boot
    // tracking) is the boot-confirmation signal, observed here because
    // this file owns the codebase's only PowerState mirror and the only
    // `power on` call site. Power-on and the volume cannot share one
    // devialet-ctl invocation - the CLI is fire-and-exit and cannot wait
    // for the boot (measured 15.0-18.6 s across 21 boots) - so the
    // follow-up is a plain `volume` invocation once "On" is observed.
    //
    // Why 500 ms after "On" (startupVolumeAfterBootMs) and not 0: a volume
    // command that reaches the amp before its own post-boot startup-volume
    // application is dropped outright (docs/known-gotchas.md #9; raw UDP
    // capture, never applied-then-overwritten). That application's latency
    // after the first power-on broadcast is not fixed - observed at or
    // before the first "On" (3 boots), ~+200 ms (9), +394 ms (1) and
    // >+400 ms (3). Early-exit sweep, delay measured from the first raw
    // power-on packet (1-40 ms *before* the daemon's "On", so every figure
    // is conservative here): +2 ms 0/1, +100 ms 1/2 (the failure had the
    // application at +394 ms), +200 ms 9/9 (every pass had it at
    // <= +202 ms, i.e. inside the observed spread), +500 ms 3/3 (packets at
    // +200/+400 still pre-application; it surfaced with the send), +1018
    // and +2030 ms 1/1 each. 500 is the smallest round value above the
    // latest observed amp-side application, and imperceptible after a
    // 15 s boot.
    //
    // State: one string, the IP captured at click time ("" = not armed),
    // so a multi-amp switch mid-boot can't misfire on the wrong amp (Phase
    // 8.4.0's "only the currently-connected amp" scoping). Lives here, not
    // in PendingAmpState (which owns only AmpIp/VolumeDb/Muted by its own
    // header rule) and not at main.qml's root: FlyoutPopup is a plain
    // Dialog child of CompactRepresentation with no Loader, so this item
    // stays resident while the flyout is hidden during the boot.
    //
    // Ordering (Phase 8.4.0's observe-then-react check): onPowerStateChanged
    // fires synchronously at the guarded assignment in ampProps.
    // onPropertiesChanged below; it reads only root.powerState and the
    // local flag, and the deferred send reads root.ampIp (assigned before
    // PowerState in that handler, and ~16 s stale anyway) plus config -
    // nothing reads pendingAmpState.volumeDb, so the AmpIp-before-VolumeDb
    // ordering that forced Qt.callLater in 8.4.0 doesn't apply, and the
    // Timer defers the send past the whole handler regardless. Every armed
    // state resolves: the daemon guarantees Booting -> On or Off within
    // BOOT_TIMEOUT, and "Off" (timeout or a power-off click) disarms.
    //
    // Display: on "On" the hold in PendingAmpState.qml is armed with the
    // target so no surface shows the amp's pre-shutdown or misreported
    // post-boot value (gotcha #8) in the ~700 ms before the send lands;
    // the send itself reads the hold's current target, so a user volume
    // change inside that window wins on the amp too (see that file's
    // header for the measurements).
    property string pendingStartupVolumeIp: ""
    readonly property int startupVolumeAfterBootMs: 500

    Timer {
        id: startupVolumeTimer
        interval: root.startupVolumeAfterBootMs
        repeat: false
        onTriggered: root.sendStartupVolume()
    }

    onPowerStateChanged: {
        // A source list left open when the amp goes off/booting closes -
        // its row is no longer interactive (2026-09-08 follow-up).
        if (root.powerState !== "On") root.sourceListOpen = false;
        if (root.pendingStartupVolumeIp === "") return;
        if (root.powerState === "On") {
            if (root.ampIp !== root.pendingStartupVolumeIp) {
                // The selected amp changed mid-boot - this "On" is not the
                // amp we powered on. Disarm; never fire at the wrong amp.
                root.pendingStartupVolumeIp = "";
                startupVolumeTimer.stop();
                return;
            }
            root.pendingAmpState.beginBootHold(root.pendingStartupVolumeIp, root.startupVolumeTarget());
            startupVolumeTimer.restart();
        } else if (root.powerState === "Off") {
            root.pendingStartupVolumeIp = "";
            startupVolumeTimer.stop();
            root.pendingAmpState.endBootHold();
        }
        // "Booting": nothing to do yet.
    }

    // Configured startup volume, pre-clamped to [floor, hardLimit] - see
    // selectSource() for why both ends are applied here.
    function startupVolumeTarget() {
        return root.volumeSettings.clamp(root.volumeSettings.startupVolumeDb);
    }

    function sendStartupVolume() {
        const ip = root.pendingStartupVolumeIp;
        root.pendingStartupVolumeIp = "";
        if (ip === "" || ip !== root.ampIp) return;
        // Latest intended value: the hold's target if a user change inside
        // the window re-targeted it, else the configured startup volume.
        const held = root.pendingAmpState.bootHoldIp !== "";
        const target = held ? root.pendingAmpState.bootHoldDb : root.startupVolumeTarget();
        // No `mute off` here - volume and mute are independent opcodes
        // (Phase 8.4.0's rule); a startup volume is not a user's
        // volume-adjusting gesture.
        root.runCtl("volume " + target + " --hard-limit-db " + root.volumeSettings.hardLimitDb);
        root.pendingAmpState.notifyVolume(target);
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

    // Chime spike: the four-slot round-robin pool maybeChime() cycles
    // through - see the chimePool comment above. Same shape as `exec`,
    // distinct log prefix so the journal trail can be grepped per slot.
    P5Support.DataSource {
        id: chimeExec0
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            console.log("devialet-chime[0] finished - exit code:", data["exit code"], "stderr:", data["stderr"]);
            disconnectSource(source);
        }
    }

    P5Support.DataSource {
        id: chimeExec1
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            console.log("devialet-chime[1] finished - exit code:", data["exit code"], "stderr:", data["stderr"]);
            disconnectSource(source);
        }
    }

    P5Support.DataSource {
        id: chimeExec2
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            console.log("devialet-chime[2] finished - exit code:", data["exit code"], "stderr:", data["stderr"]);
            disconnectSource(source);
        }
    }

    P5Support.DataSource {
        id: chimeExec3
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            console.log("devialet-chime[3] finished - exit code:", data["exit code"], "stderr:", data["stderr"]);
            disconnectSource(source);
        }
    }

    // The UI-state hooks (harness `uiTarget` points here). Writers are all
    // imperative - see the header of this file's plan; no binding touches
    // them, so the trigger->overlay->Popup chains can't loop.
    property bool ampListOpen: false
    // Phase 7.14.0: the source list is a second owner-driven Popup
    // (SourceListOverlay.qml) with the identical contract.
    property bool sourceListOpen: false

    // Reset both lists when the flyout hides, so neither is already
    // expanded on the next open (neither the old flyout nor a QtQuick
    // Popup resets on window hide on its own).
    onPopupVisibleChanged: {
        if (!root.popupVisible) {
            root.ampListOpen = false;
            root.sourceListOpen = false;
        }
    }

    // Drive each overlay Popup imperatively off its own flag. close() on
    // an already-closed Popup is a no-op emitting nothing, so the
    // re-entrant path (overlay dismiss -> onClosed sets false -> here
    // calls close()) terminates safely. Mutual exclusion (mockup v2's
    // toggleAmpList()/toggleSourceList(): opening one closes the other)
    // is enforced here explicitly rather than left to the two Popups'
    // press-outside close policies happening to fire: clearing the other
    // flag when it's already false emits nothing, so no ping-pong.
    onAmpListOpenChanged: {
        if (root.ampListOpen) root.sourceListOpen = false;
        root.ampListOpen ? ampListOverlay.open() : ampListOverlay.close();
    }
    onSourceListOpenChanged: {
        if (root.sourceListOpen) root.ampListOpen = false;
        root.sourceListOpen ? sourceListOverlay.open() : sourceListOverlay.close();
    }

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
    // them square. Edge to edge.
    //
    // Radius (Phase 7.14.0 follow-up, owner request): the mockup's
    // `.flyout{border-radius:16px}` (theme.radiusLg), not
    // Kirigami.Units.cornerRadius any more. That value (5 on this system)
    // only ever existed to line up with Darkly's dialog frame SVG drawn
    // underneath the old AppletPopup-hosted flyout (CLAUDE.md "sub-pixel
    // corner seam"); with NoBackground there is no frame under this
    // Rectangle, so nothing constrains the radius and the mockup's own
    // value applies. AmpHeader's hover fill rounds its top corners to the
    // same radius so it can't paint square corners over these.
    //
    // Phase 9.1.0: the gradient's alpha is now the user-configured
    // transparency setting, not a hardcoded value baked into Theme.qml -
    // theme.panelTintTop/Bottom are the opaque base colours only (see
    // Theme.qml's own comment), and transparencySettings.withAlpha()
    // reads the live alpha on every call, so a ConfigDialog Apply/OK
    // re-paints this immediately (no reload), per TransparencySettings.
    // qml's own header comment.
    Rectangle {
        anchors.fill: parent
        radius: root.theme.radiusLg
        antialiasing: true
        border.width: 1
        border.color: root.theme.divider
        gradient: Gradient {
            GradientStop { position: 0.0; color: root.transparencySettings.withAlpha(root.theme.panelTintTop) }
            GradientStop { position: 1.0; color: root.transparencySettings.withAlpha(root.theme.panelTintBottom) }
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
            volumeSettings: root.volumeSettings
            transparencySettings: root.transparencySettings
            activeSourceName: root.activeSourceName
            // Same guarded mirror that arms the boot hold (see
            // onPowerStateChanged above) - slider and hold flip together.
            powerState: root.powerState
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
            transparencySettings: root.transparencySettings
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
            powerState: root.powerState
            transparencySettings: root.transparencySettings
            listOpen: root.sourceListOpen
            onToggleRequested: root.sourceListOpen = !root.sourceListOpen
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
        transparencySettings: root.transparencySettings
        onClosed: root.ampListOpen = false
        onAmpChosen: ip => root.selectAmpByIp(ip)
    }

    // Source list overlay (Phase 7.14.0) - parented to SourceSelector's
    // row so it opens upward from it (Popup positions relative to
    // `parent`); same owner-driven contract as AmpListOverlay above.
    // Index/name arrive already validated against the overlay's own model
    // (SourceListOverlay's onClicked), matching selectSource()'s existing
    // "no bounds check here" doc.
    SourceListOverlay {
        id: sourceListOverlay
        parent: sourceSelector.rowItem
        theme: root.theme
        enabledSources: sourceSelector.enabledSources
        activeSourceIndex: root.activeSourceIndex
        transparencySettings: root.transparencySettings
        onClosed: root.sourceListOpen = false
        onSourceChosen: (index, name) => {
            root.sourceListOpen = false;
            root.selectSource(index, name);
        }
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
