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
// AmpIp/VolumeDb/Muted are ever processed/exposed. Do NOT add handling
// for any other property to this file - that boundary is what keeps
// this object out of full-mirror-consolidation territory (a legitimate,
// larger, explicitly separate future phase - see TODO.md).
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
            root.ampIp = root.unwrap(properties.AmpIp, "");
            root.volumeDb = root.unwrap(properties.VolumeDb, undefined);
            root.muted = root.unwrap(properties.Muted, false);
            if (root.debugLogging) {
                console.log("[PendingAmpState] onRefreshed", root.ampIp, root.volumeDb, root.muted);
            }
        }

        // Interface-level subscription - unavoidably also delivers
        // Online/DeviceName/Sources/KnownAmps/etc. on every emission.
        // Deliberately ignored: only AmpIp/VolumeDb/Muted are ever
        // processed here. Full mirror consolidation is an explicitly
        // separate, larger, deferred future phase - see TODO.md.
        onPropertiesChanged: (interfaceName, changed, invalidated) => {
            if ("AmpIp" in changed) root.ampIp = root.unwrap(changed.AmpIp, root.ampIp);
            if ("VolumeDb" in changed) root.volumeDb = root.unwrap(changed.VolumeDb, root.volumeDb);
            if ("Muted" in changed) root.muted = root.unwrap(changed.Muted, root.muted);
            if (root.debugLogging && (("AmpIp" in changed) || ("VolumeDb" in changed) || ("Muted" in changed))) {
                console.log("[PendingAmpState] onPropertiesChanged", root.ampIp, root.volumeDb, root.muted);
            }
        }
    }
}
