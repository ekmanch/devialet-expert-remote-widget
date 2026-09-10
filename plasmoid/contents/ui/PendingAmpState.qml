// Phase 5.0.1: single shared, root-anchored consumer of the daemon's
// resolved VolumeDb/Muted (pending-or-confirmed - see interface.rs's
// NotifyVolumeCommand/NotifyMuteCommand + resolve_pending_commands,
// Phase 5.0.0). Both CompactRepresentation and FullRepresentation read
// volumeDb/muted from ONE instance of this object (handed down from
// main.qml via a `required property`, the same mechanism
// CompactRepresentation's existing `plasmoidItem` already uses) instead
// of each maintaining its own independent optimistic/debounce copy -
// see TODO.md's Phase 5.0.0/5.0.1 entries for the full architecture
// decision and rejected alternatives.
//
// This object owns its own Dbus.Properties subscription to the daemon
// interface. That subscription is interface-level, not per-property, so
// it unavoidably also receives Online/DeviceName/Sources/KnownAmps/etc.
// on every PropertiesChanged emission - deliberately ignored here. Only
// AmpIp/VolumeDb/Muted are ever processed/exposed - plus, since Phase
// 8.0.1, VolumeRaw, read for exactly one purpose (the post-boot hold's
// confirmation check below) and never exposed - except that the volume-
// chime spike (TODO.md, branch spike/volume-audio-feedback) additionally
// exposes that same decoded byte as `confirmedVolumeDb` (the amp's real
// last-broadcast dB, never the daemon's 400 ms pending mask) for the
// chime's gain compensation; still nothing beyond AmpIp/VolumeDb/Muted/
// VolumeRaw is processed here. Do NOT add handling for
// any other property to this file - that boundary is what keeps this
// object out of full-mirror-consolidation territory (a legitimate,
// larger, explicitly separate future phase - see TODO.md).
//
// Phase 8.0.1 - post-boot volume-display hold (`beginBootHold`/
// `endBootHold`, `bootHold*` below). The second instance of the
// optimistic-guard pattern FlyoutContent.qml's 400 ms Power/PowerState
// guard established, scoped to VolumeDb in the window right after a
// widget-initiated power-on confirms. Why it lives here and not in
// FlyoutContent: unlike Power/PowerState, VolumeDb never passes through
// a FlyoutContent mirror - VolumeBlock, CompactRepresentation's scroll/
// fill fraction, the OSD toast and the hover tooltip all read
// `volumeDb` from this one object (Phase 5.0.2 removed every per-view
// copy), so a guard anywhere else could not cover the panel icon/OSD/
// tooltip and would recreate the duplicated optimistic copy this file
// exists to eliminate.
//
// What it masks (measured 2026-09-07 on the real amp with an
// independent raw UDP capture next to the daemon, 21+ boots): the first
// power-on broadcast still carries the pre-shutdown volume byte; ~200 ms
// later the amp switches to its own startup volume but *misreports* it
// by 2 dB (raw 111 = -42.0 while the front panel reads -40; docs/
// known-gotchas.md #8), and it stays there until a volume command is
// sent. FlyoutContent's startup send goes out 500 ms after "On" (gotcha
// #9) and the amp's broadcast confirms it 96-199 ms later - so without
// this hold every surface would show -42 for ~300-500 ms and then jump
// to the configured value.
//
// Mechanism: FlyoutContent arms the hold on Booting→On (`beginBootHold(
// ip, target)`), which shows `target` at once. While held, VolumeDb
// pushes are recorded (`lastRealVolumeDb`) but not applied; any
// `notifyVolume(db)` from any call site (flyout step/slider, panel
// scroll, settings clamp) re-targets the hold to the user's value and
// shows it the same tick - the user always wins, and FlyoutContent's
// deferred send reads `bootHoldDb` so the amp gets the same value
// (verified at the amp level 4/4: the user's change inside the window
// is honored and the later send is idempotent). The hold ends on real
// confirmation - a VolumeRaw push decoding to `bootHoldDb` ((raw - 195)
// / 2, the daemon's deliberately unmasked byte, interface.rs) - not on
// the daemon's 400 ms VolumeDb echo of our own NotifyVolumeCommand,
// which fires at the send before anything is confirmed. Bounded
// fallback `bootHoldTimeoutMs` (1500: 500 send + ~200 confirm + the
// >400 ms late-application allowance from the sweep, rounded) then
// shows the last real value instead. Also ended on AmpIp change and,
// via FlyoutContent, on a power-off click or boot timeout. Outside the
// window nothing here changes; the daemon's own pending mask keeps
// working underneath.
//
// Thin consumer only: the confirmed-vs-expired resolution logic stays
// entirely in the daemon (Phase 5.0.0's resolve_pending_commands). This
// file never tracks a deadline or compares against one itself -
// volumeDb/muted below are already exactly what the daemon currently
// reports, whether still pending or already confirmed.
//
// Plain QtObject root, not `pragma Singleton` - matches Theme.qml's own
// precedent (this KPackage has no qmldir/module registration set up for
// a true singleton). A headless data object; no visual representation
// needed.

import QtQml
import org.kde.plasma.workspace.dbus as Dbus

QtObject {
    id: root

    readonly property string serviceName: "com.ekmanch.DevialetRemote"
    readonly property string objectPath: "/com/ekmanch/DevialetRemote/Amp"
    readonly property string interfaceName: "com.ekmanch.DevialetRemote.Amp1"

    // Phase 5.0.1 verification aid only - flip to true for a live
    // lifecycle-independence pass (see TODO.md's Phase 5.0.1 entry),
    // false otherwise. Not left permanently on.
    readonly property bool debugLogging: false

    property string ampIp: ""
    property var volumeDb: undefined
    property bool muted: false

    // Phase 8.0.1 post-boot hold state - see the header comment.
    // bootHoldIp "" = not held. bootHoldDb = the value currently asserted
    // (configured startup volume, or the user's latest change inside the
    // window). lastRealVolumeDb = the most recent daemon VolumeDb push
    // seen (kept current whether held or not), the fallback shown if the
    // hold times out unconfirmed - Plasma.DBusProperties has no refresh()
    // to re-read the live value with, hence tracked here.
    property string bootHoldIp: ""
    property var bootHoldDb: undefined
    property var lastRealVolumeDb: undefined
    // Chime spike: (VolumeRaw - 195) / 2, the amp's real last-broadcast
    // dB - deliberately NOT volumeDb (optimistic, then daemon-masked for
    // 400 ms after every command). undefined until an amp is selected and
    // has broadcast. Written only by noteVolumeRaw(); read-only elsewhere.
    property var confirmedVolumeDb: undefined
    readonly property int bootHoldTimeoutMs: 1500

    // Named property, not a bare child - QtObject has no default property
    // (same reason as `ampProps` below).
    readonly property Timer bootHoldTimer: Timer {
        interval: root.bootHoldTimeoutMs
        repeat: false
        onTriggered: {
            if (root.bootHoldIp === "") return;
            if (root.debugLogging) {
                console.log("[PendingAmpState] boot hold timed out unconfirmed; falling back to", root.lastRealVolumeDb);
            }
            const fallback = root.lastRealVolumeDb;
            root.endBootHold();
            if (fallback !== undefined) root.volumeDb = fallback;
        }
    }

    // Arm the hold: show `db` immediately and keep showing it until the
    // amp's broadcast confirms it (VolumeRaw), the user re-targets it
    // (notifyVolume), or bootHoldTimeoutMs elapses. Re-arming while held
    // just re-targets.
    function beginBootHold(ip, db) {
        if (ip === "" || db === undefined) return;
        root.bootHoldIp = ip;
        root.bootHoldDb = db;
        root.volumeDb = db;
        root.bootHoldTimer.restart();
    }

    function endBootHold() {
        root.bootHoldTimer.stop();
        root.bootHoldIp = "";
        root.bootHoldDb = undefined;
    }

    // Confirmation check for the hold - the daemon's VolumeRaw is the
    // amp's real status byte, unmasked by pending commands (interface.rs),
    // decoded with the protocol crate's own formula (status.rs
    // volume_db()). bootHoldDb is a whole-dB config value or a clamp of
    // one, and raw decodes to a multiple of 0.5, so `===` is exact.
    function noteVolumeRaw(raw) {
        // Chime spike: expose the decoded byte first, before the hold's
        // early return. The daemon emits VolumeRaw=0 with AmpIp="" when
        // no amp is selected, which would decode to -97.5 - hence the
        // ampIp guard (noteAmpIp always runs before this in both
        // onRefreshed and onPropertiesChanged below).
        root.confirmedVolumeDb = (raw === undefined || root.ampIp === "") ? undefined : (raw - 195) / 2;
        if (root.bootHoldIp === "" || raw === undefined) return;
        if ((raw - 195) / 2 === root.bootHoldDb) {
            if (root.debugLogging) {
                console.log("[PendingAmpState] boot hold confirmed by VolumeRaw", raw);
            }
            root.endBootHold();
        }
    }

    // VolumeDb push from the daemon: always remembered, applied only when
    // not held (the hold is the whole point - see header).
    function noteVolumeDb(db) {
        root.lastRealVolumeDb = db;
        if (root.bootHoldIp === "") root.volumeDb = db;
    }

    // AmpIp from the daemon: a *change* while held ends the hold (the
    // held value belongs to the amp that booted, not the new one). Every
    // emit_all() re-sends an unchanged AmpIp, so compare, don't just
    // react to the key being present.
    function noteAmpIp(ip) {
        if (root.bootHoldIp !== "" && ip !== root.bootHoldIp) root.endBootHold();
        root.ampIp = ip;
    }

    // Third copy of a helper already duplicated identically in both
    // CompactRepresentation.qml and FullRepresentation.qml - deliberate,
    // not an oversight. Small, stable, no timing/debounce concerns, same
    // category CompactRepresentation's own header comment already
    // carves out as "duplicated in spirit, not by reference", unrelated
    // to the actual debounce/state-machine duplication this phase exists
    // to eliminate.
    function unwrap(prop, fallback) {
        if (prop === undefined || prop === null) return fallback;
        if (typeof prop === "object" && prop.value !== undefined) return prop.value;
        return prop;
    }

    // Phase 5.0.2 Step B: both functions below now write volumeDb/muted
    // synchronously, before firing the async D-Bus call - this is what
    // lets CompactRepresentation.qml's stepVolume()/toggleMute() safely
    // use these properties as their own rapid-repeat accumulation base
    // (reading "the value I just set" needs that value to exist in the
    // same tick, not after a D-Bus round trip). Also what finally makes
    // the FullRepresentation.qml slider holdout liftable in a future
    // step (not done here - the Binding itself still needs switching and
    // re-verifying for the snap-back risk separately).
    //
    // Rollback on failure: verified safe via the actual KDE source
    // (plasma-workspace's components/dbus/dbusconnection.cpp) that the
    // resolve/reject callbacks below are mutually exclusive AND
    // single-shot (Qt::SingleShotConnection guarding a reply->isValid()
    // if/else) - together, at most one of the two ever fires, so a
    // rollback here can't double-fire or race a late success. Without
    // this, a failed call (e.g. daemon down/restarting) would leave an
    // unconfirmed optimistic value asserted indefinitely, correctable
    // only by luck (some unrelated future onRefreshed/onPropertiesChanged
    // happening to overwrite it) rather than promptly and deliberately.
    function notifyVolume(db) {
        if (root.ampIp === "") return;
        // Phase 8.0.1: a user change inside the post-boot window re-targets
        // the hold, so it is shown at once (below) and FlyoutContent's
        // deferred startup send carries it instead of the configured value.
        if (root.bootHoldIp !== "") root.bootHoldDb = db;
        const previous = root.volumeDb;
        root.volumeDb = db;
        Dbus.SessionBus.asyncCall(
            new Dbus.dbusMessage({
                service: root.serviceName,
                path: root.objectPath,
                interface: root.interfaceName,
                member: "NotifyVolumeCommand",
                arguments: [root.ampIp, db]
            }),
            function (reply) {
                if (reply.isError) {
                    root.volumeDb = previous;
                    console.log("[WARN] NotifyVolumeCommand call returned a D-Bus error:", JSON.stringify(reply.error));
                }
            },
            function (reply) {
                root.volumeDb = previous;
                console.log("[WARN] NotifyVolumeCommand call failed:", JSON.stringify(reply.error));
            }
        );
    }

    function notifyMute(muted) {
        if (root.ampIp === "") return;
        const previous = root.muted;
        root.muted = muted;
        Dbus.SessionBus.asyncCall(
            new Dbus.dbusMessage({
                service: root.serviceName,
                path: root.objectPath,
                interface: root.interfaceName,
                member: "NotifyMuteCommand",
                arguments: [root.ampIp, muted]
            }),
            function (reply) {
                if (reply.isError) {
                    root.muted = previous;
                    console.log("[WARN] NotifyMuteCommand call returned a D-Bus error:", JSON.stringify(reply.error));
                }
            },
            function (reply) {
                root.muted = previous;
                console.log("[WARN] NotifyMuteCommand call failed:", JSON.stringify(reply.error));
            }
        );
    }

    // Assigned via a named property, NOT a bare child object - QtObject
    // has no `data` default property in Qt6 (that's an Item/QQuickItem
    // thing, confirmed against this machine's actual installed
    // qmltypes, not assumed - the two existing bare-Dbus.Properties-child
    // precedents in this codebase, CompactRepresentation.qml and
    // FullRepresentation.qml, are both Item-derived roots). This is the
    // same pattern Theme.qml already uses for its own QObject-derived
    // FontLoader children under a QtObject root.
    readonly property Dbus.Properties ampProps: Dbus.Properties {
        busType: Dbus.BusType.Session
        service: root.serviceName
        path: root.objectPath
        iface: root.interfaceName

        onRefreshed: {
            root.noteAmpIp(root.unwrap(properties.AmpIp, ""));
            root.noteVolumeRaw(root.unwrap(properties.VolumeRaw, undefined));
            root.noteVolumeDb(root.unwrap(properties.VolumeDb, undefined));
            root.muted = root.unwrap(properties.Muted, false);
            if (root.debugLogging) {
                console.log("[PendingAmpState] onRefreshed", root.ampIp, root.volumeDb, root.muted);
            }
        }

        // Interface-level subscription - unavoidably also delivers
        // Online/DeviceName/Sources/KnownAmps/etc. on every emission.
        // Deliberately ignored: only AmpIp/VolumeDb/Muted (and VolumeRaw,
        // for the hold's confirmation only - Phase 8.0.1) are ever
        // processed here. Full mirror consolidation is an explicitly
        // separate, larger, deferred future phase - see TODO.md.
        // Order matters and matches the daemon's emit_all(): AmpIp, then
        // VolumeRaw, then VolumeDb - so a confirming raw byte ends the
        // hold before the same emission's VolumeDb is considered.
        onPropertiesChanged: (interfaceName, changed, invalidated) => {
            if ("AmpIp" in changed) root.noteAmpIp(root.unwrap(changed.AmpIp, root.ampIp));
            if ("VolumeRaw" in changed) root.noteVolumeRaw(root.unwrap(changed.VolumeRaw, undefined));
            if ("VolumeDb" in changed) root.noteVolumeDb(root.unwrap(changed.VolumeDb, root.volumeDb));
            if ("Muted" in changed) root.muted = root.unwrap(changed.Muted, root.muted);
            if (root.debugLogging && (("AmpIp" in changed) || ("VolumeDb" in changed) || ("Muted" in changed))) {
                console.log("[PendingAmpState] onPropertiesChanged", root.ampIp, root.volumeDb, root.muted);
            }
        }
    }
}
