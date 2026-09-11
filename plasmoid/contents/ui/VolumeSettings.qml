// Single shared owner of volume-range configuration (floor/hard-limit/step/
// startup dB), read once from Plasmoid.configuration and forwarded to every
// surface that displays or adjusts volume - the flyout's VolumeBlock, the
// panel icon's own scroll-to-adjust, the OSD toast, and the hover tooltip
// (the latter two indirectly, via CompactRepresentation.qml's volumeFraction).
//
// Same shape as PendingAmpState.qml: a plain QtObject (not `pragma
// Singleton` - no qmldir exists anywhere under contents/ui/, so a true QML
// module singleton isn't set up in this KPackage), instantiated exactly
// once in main.qml and forwarded down via `required property` through
// CompactRepresentation.qml -> FlyoutPopup.qml -> FlyoutContent.qml ->
// VolumeBlock.qml, and directly into CompactRepresentation.qml's own
// stepVolume()/volumeFraction. See CLAUDE.md's "Shared cross-view state"
// note for the general convention this follows.
//
// Deliberately does NOT `import org.kde.plasma.plasmoid` itself - every
// existing file in this codebase that reads Plasmoid.configuration is an
// Item-derived root (main.qml, CompactRepresentation.qml, FlyoutContent.qml,
// FlyoutPopup.qml); the two existing plain QtObjects (Theme.qml,
// PendingAmpState.qml) never do. Rather than be the first to find out
// whether that context property propagates into a bare QtObject file, the
// four properties below are plain `required property real` and get bound
// declaratively from main.qml instead, which is unambiguously proven to
// have Plasmoid.configuration access already.
//
// This replaces two independent hardcoded copies of the same three numbers
// (CompactRepresentation.qml's and FlyoutContent.qml's own local
// volumeCeilingDb/volumeFloorDb/volumeStepDb properties, both -15.0/-60.0
// pre-ConfigDialog literals) with one source of truth, and centralizes the
// actual clamp/step/fraction math too - not just the raw numbers - so the
// three UI surfaces (flyout, OSD, tooltip) can't independently compute
// conflicting results the way the two duplicated copies could have.
import QtQuick

QtObject {
    id: root

    required property real floorDb
    required property real hardLimitDb
    required property real stepDb
    required property real startupVolumeDb
    // Phase 10.1.2: main.xml `chimeEnabled` - the master on/off for the
    // Phase 10.1.0 volume-feedback chime. Carried here rather than in a new
    // settings object because the chime is volume feedback (it fires from
    // the same stepVolume() paths that consume stepDb/clamp() above) and
    // both maybeChime() owners already hold this object; the spike's own
    // deferred-settings note in TODO.md named this file as the forwarding
    // path. Read live by both maybeChime()s - when false they return
    // before building a command, so devialet-chime is never spawned.
    required property bool chimeEnabled

    // Reads floorDb/hardLimitDb live on every call (never a cached local),
    // so any binding that calls this stays a normal reactive QML binding -
    // changing a ConfigDialog value re-evaluates every consumer immediately.
    function clamp(db) {
        return Math.min(root.hardLimitDb, Math.max(root.floorDb, db));
    }

    // currentDb may be undefined (no amp connected yet) - falls back to
    // floorDb, matching the pre-existing behavior in both call sites this
    // replaces.
    function stepped(currentDb, direction) {
        const base = currentDb !== undefined ? currentDb : root.floorDb;
        return root.clamp(base + direction * root.stepDb);
    }

    // Normalized 0..1 position for progress-bar-style displays (OSD/
    // tooltip fill). undefined db (no amp yet) reads as 0, matching the
    // pre-existing behavior in both call sites this replaces.
    function fractionFor(db) {
        if (db === undefined) return 0;
        return Math.min(1, Math.max(0, (db - root.floorDb) / (root.hardLimitDb - root.floorDb)));
    }
}
