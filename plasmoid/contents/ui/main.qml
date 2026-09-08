// Phase 2: minimal working skeleton, proving the plasmoid loads as a
// panel-pinned applet and the D-Bus/executable-engine plumbing works
// end-to-end. No visual design from the mockup yet - see CLAUDE.md's
// phased roadmap.
//
// Panel-pinned, not tray-hosted (see CLAUDE.md's "why not a system tray
// plasmoid" note) - PlasmoidItem + compactRepresentation/fullRepresentation
// is the same standard structure either way (confirmed against
// com.github.tilorenz.compact_pager, a real panel-pinnable applet), so
// nothing here needed to change for that switch.

pragma ComponentBehavior: Bound

import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.workspace.dbus as Dbus

PlasmoidItem {
    id: root

    // Phase 4.11: custom panel icon, replacing the Phase 2 Breeze
    // placeholder. `Plasmoid.icon` accepts an arbitrary resolvable path,
    // not just an icon-theme name - confirmed via a real precedent
    // (org.kde.desktopcontainment's ConfigIcons.qml binds a user-browsed
    // KIconThemes.IconDialog file path straight to Plasmoid.icon/
    // Plasmoid.configuration.icon), not assumed. Bundled the same way
    // Phase 4.0 bundled its fonts (contents/icons/, Qt.resolvedUrl,
    // matching the real luisbocanegra.panel.colorizer precedent of a
    // plasmoid shipping its own contents/icons/ directory) rather than
    // requiring a system/user icon-theme install step.
    //
    // This is the asset CompactRepresentation.qml's Kirigami.Icon actually
    // renders on the panel - the *other* icon reference in this package,
    // metadata.json's KPlugin.Icon (used by the "Add Widgets" list), is a
    // separate, more limited mechanism: KPluginMetaData::iconName()'s own
    // header doc says "\sa QIcon::fromTheme()" - a system icon-theme name
    // only, confirmed by checking a real KPackage precedent
    // (org.kde.plasma.folder's "Icon": "org.kde.plasma.folder" resolves to
    // an actual Breeze-shipped .../breeze/applets/256/org.kde.plasma.
    // folder.svg, not a bundled package file). Getting our own SVG into
    // that list too would mean installing it into the system/user
    // hicolor icon theme - real packaging work that belongs with Phase
    // 4.5's install script, not this self-contained visual change -
    // metadata.json's Icon is left as a real Breeze name (unchanged) so
    // the "Add Widgets" entry stays a valid, if generic, icon rather than
    // silently breaking.
    // Phase 4.2.5: switched to the "Glow Dot" variant
    // (design/icon/A - Glow Dot/devialet_icon_A_filled.svg). Its artwork's
    // own bounding box (outer ring at r=11, stroke-width=2, centered in a
    // 34x34 viewBox) sits 5 units in from each edge - a 14.7% inset,
    // matching the Breeze symbolic-icon convention (~13-14%) measured
    // during Phase 4.1's triangle-icon fix, so no scale/margin correction
    // was needed here. Unlike devialet_icon_currentColor_tray.svg, this
    // artwork uses hardcoded copper fill/stroke (not currentColor) by
    // design - see CompactRepresentation.qml for why isMask is off for
    // this icon.
    Plasmoid.icon: Qt.resolvedUrl("../icons/devialet_icon_glow_dot.svg")

    // Phase 8.4.0: same devialet-ctl invocation string CompactRepresentation.qml
    // and FlyoutContent.qml each already define locally (their own
    // devialetCtlCommand) - duplicated here for the identical reason
    // VolumeSettings/PendingAmpState are duplicated-as-forwarded rather than
    // reached-into: applyImmediateClamp() below must fire regardless of
    // which representation (if any) is currently resident.
    readonly property string devialetCtlCommand: "devialet-ctl"

    // Phase 5.0.1: single shared, root-anchored consumer of the daemon's
    // resolved VolumeDb/Muted - see PendingAmpState.qml's own header
    // comment for the full reasoning. Anchored here (main.qml's root
    // PlasmoidItem) rather than inside either representation because
    // root is what creates/loads both of them and so strictly outlives
    // either - CompactRepresentation and FullRepresentation are not
    // guaranteed co-resident (see CompactRepresentation.qml's own header
    // comment), so anything meant to be shared between them can't live
    // inside either one.
    PendingAmpState {
        id: pendingAmpState

        // Phase 8.4.0 follow-up: catches the case where applyImmediateClamp()
        // ran once already (from a floorDb/hardLimitDb change) while no amp
        // was connected yet (ampIp === "" at the time) and so no-op'd -
        // confirmed live: Phase 8.3.0's self-heal fires synchronously during
        // Component.onCompleted, and Qt.callLater's deferred callback
        // reliably beats the daemon's async D-Bus reply that populates
        // ampIp, so the self-heal-triggered check was consistently no-op'ing
        // even once the amp connected moments later - floorDb/hardLimitDb
        // don't change again on their own, so nothing retried the check.
        // Re-running the check when ampIp itself transitions (including
        // "" -> a real IP) closes that gap, and also covers the general
        // "widget starts up with an already-out-of-range stored volume"
        // case, not just the self-heal one specifically.
        //
        // Deferred via Qt.callLater for a different, concrete reason than
        // the floorDb/hardLimitDb coalescing above (not just consistency):
        // onRefreshed/onPropertiesChanged above both assign root.ampIp
        // BEFORE root.volumeDb in the same synchronous handler call - a
        // synchronous (non-deferred) handler here would run in between
        // those two assignments and read a stale/not-yet-updated volumeDb
        // from the very refresh that just delivered the fresh one.
        // Qt.callLater defers past both assignments, so volumeDb is
        // guaranteed current by the time applyImmediateClamp() runs.
        //
        // No interaction with the floorDb/hardLimitDb coalescing above:
        // ampIp changes come only from the daemon's async D-Bus signal
        // delivery (onRefreshed/onPropertiesChanged in this file), entirely
        // independent of the local Plasmoid.configuration writes that drive
        // floorDb/hardLimitDb - these two trigger sources can't fire within
        // the same synchronous tick. Even if they somehow did, all three
        // handlers target the same root.applyImmediateClamp reference, so
        // Qt.callLater's identity-based dedup would still collapse them to
        // one call with no special-casing needed.
        onAmpIpChanged: Qt.callLater(root.applyImmediateClamp)
    }

    // Same root-anchored-and-forwarded pattern as PendingAmpState above,
    // extended to volume-range configuration (floor/hard-limit/step/startup
    // dB) - see VolumeSettings.qml's own header comment and CLAUDE.md's
    // "Shared cross-view state" note. Anchored here for the identical
    // reason: CompactRepresentation and the flyout are not guaranteed
    // co-resident, so anything meant to be shared between them can't live
    // inside either one - it must live where both are forwarded from.
    VolumeSettings {
        id: volumeSettings
        floorDb: Plasmoid.configuration.volumeFloorDb
        hardLimitDb: Plasmoid.configuration.hardLimitDb
        stepDb: Plasmoid.configuration.volumeStepDb
        startupVolumeDb: Plasmoid.configuration.startupVolumeDb

        // Phase 8.4.0: floorDb/hardLimitDb above are ordinary live bindings
        // to Plasmoid.configuration.* - a single ConfigDialog Apply/OK click
        // can change BOTH in the same tick (two separate, non-batched
        // property-change signals fired back to back), and each would
        // independently trigger applyImmediateClamp() if called directly -
        // the first firing could see one new value paired with the other
        // property's still-stale value, computing a transiently-wrong clamp
        // target and sending a spurious/incorrect devialet-ctl command
        // before the second, correct call. Qt.callLater dedupes repeated
        // calls to the SAME function value within one event-loop turn, so
        // passing the bare function (root.applyImmediateClamp, not a
        // wrapping lambda - a lambda would be a fresh closure each call and
        // would NOT dedupe) coalesces both signals into exactly one, fully-
        // settled check per Apply/OK. Also composes for free with the
        // Phase 8.3.0 self-heal below: Component.onCompleted runs
        // synchronously, before any D-Bus reply (including
        // pendingAmpState's own subscription) could plausibly have
        // arrived, and Qt.callLater always defers to the next event-loop
        // turn rather than running inline - so applyImmediateClamp() never
        // executes mid-construction; by the time it runs, ampIp is either
        // still "" (guard no-ops) or a real amp has connected in the
        // meantime, in which case clamping against the now-healed range is
        // correct, not a race.
        onFloorDbChanged: Qt.callLater(root.applyImmediateClamp)
        onHardLimitDbChanged: Qt.callLater(root.applyImmediateClamp)

        // Phase 8.3.0 self-heal: ConfigGeneral.qml's steppers can only
        // prevent a NEW invalid floor/hard-limit pair from being created
        // through the dialog - they can't fix one that already exists on
        // disk (e.g. the KConfig INI edited directly while the widget
        // wasn't running). Not something the owner is defending against
        // maliciously, but this construction point already exists and is
        // the natural place to catch it before anything reads floorDb/
        // hardLimitDb for real. Runs once, synchronously, before
        // compactRepresentation/fullRepresentation below ever bind to
        // this object, so no invalid slider/OSD/tooltip math is ever
        // visible - both KConfig writes land in the same tick, and
        // floorDb/hardLimitDb above (already-live bindings to
        // Plasmoid.configuration) pick up the corrected values
        // automatically, no extra plumbing needed.
        //
        // This is the ONLY point that reliably catches external file
        // corruption - `Plasmoid.configuration` is one KConfigPropertyMap
        // per plasmashell process, read from disk exactly once at this
        // Component.onCompleted's own moment (confirmed live, Phase
        // 8.3.0: fresh restart -> correct read -> correct heal,
        // reproduced cleanly twice). It never re-reads the file again for
        // the rest of that process's life, for ANY external write
        // (kwriteconfig6 or a raw editor save alike) - a corruption
        // introduced while already running is invisible to this check
        // and to the live widget itself until the next restart.
        // ConfigGeneral.qml's own onCfg_volumeFloorDbChanged/
        // onCfg_hardLimitDbChanged handlers do NOT cover that
        // already-running case either, despite originally being added
        // for exactly that - see their own comment for the full
        // investigation. They still guard every in-process write to
        // cfg_* (e.g. the Defaults button), which is a real, reachable
        // case on its own.
        //
        // Floor gets the more negative (quieter) of the pair, hard limit
        // the less negative one - matching every other floor/hardLimit
        // pair in this codebase (shipped defaults: floor -45.0 < hardLimit
        // -10.0).
        Component.onCompleted: {
            if (Plasmoid.configuration.volumeFloorDb >= Plasmoid.configuration.hardLimitDb) {
                console.log("[VolumeSettings] floor/hardLimit invalid on load (" +
                            Plasmoid.configuration.volumeFloorDb + " >= " +
                            Plasmoid.configuration.hardLimitDb + ") - self-healing to -40.0/-39.0");
                Plasmoid.configuration.volumeFloorDb = -40.0;
                Plasmoid.configuration.hardLimitDb = -39.0;
            }
        }
    }

    // Phase 8.4.0: dedicated executable-engine DataSource for
    // applyImmediateClamp() below - NOT shared with CompactRepresentation
    // .qml's or FlyoutContent.qml's own `exec` (those are per-representation
    // -file locals, and this must fire independent of which representation
    // is resident - same reasoning as VolumeSettings/PendingAmpState living
    // here). Same shape as both of those DataSources.
    P5Support.DataSource {
        id: clampExec
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            console.log("devialet-ctl finished - exit code:", data["exit code"], "stderr:", data["stderr"]);
            disconnectSource(source);
        }
    }

    // Phase 8.4.0: immediate clamp when a settings change (ConfigDialog
    // Apply/OK, or Phase 8.3.0's self-heal) moves the connected amp's live
    // volume outside the new [floorDb, hardLimitDb] range. Owner decision
    // (TODO.md's Phase 8.4.0 entry): both directions are required and
    // symmetric (a lowered hard limit pulls volume down; a raised floor
    // pulls volume up), firing immediately, not deferred to the next
    // user-initiated volume change. Only the currently-connected amp
    // (pendingAmpState.ampIp, mirroring the daemon's real AmpIp property -
    // NOT SelectedAmpIp, which is UI-picker bookkeeping) is touched; other
    // KnownAmps entries have no live volume to compare against and aren't
    // reachable, matching every other volume call site's own
    // `if (ampIp === "") return` guard.
    //
    // Fires the same two-step pattern as every other volume-change call
    // site (CompactRepresentation.qml's stepVolume(), FlyoutContent.qml's
    // stepVolume()/releaseVolume()): a devialet-ctl invocation via a
    // Plasma5Support.DataSource, then pendingAmpState.notifyVolume() for
    // the optimistic UI mirror - NOT a daemon-sent command (the daemon's
    // NotifyVolumeCommand only ever records an optimistic mirror, it never
    // sends UDP - see crates/devialet-remote-daemon/src/interface.rs and
    // Phase 8.0.1's rejection of an autonomous second sender).
    //
    // Deliberately does NOT send "mute off" or call notifyMute(), unlike
    // stepVolume()'s own muted-unmute-on-scroll behavior - the amp must
    // stay muted through a settings-triggered correction (owner decision).
    // Safe to omit: volume and mute are independent protocol commands with
    // separate opcodes (docs/protocol.md's Mute on/off vs. Volume rows;
    // devialet_protocol::volume_packet carries no mute bit, only the
    // 0x8000 negative-dB sign bit), so a bare volume command doesn't
    // unmute the amp at the protocol level - stepVolume()'s "mute off" is
    // an added UX behavior for direct user interaction, not a side effect
    // of the volume command itself.
    //
    // Power gate (2026-09-08 follow-up): no command while the amp is off or
    // booting - the amp drops it and the daemon's 400 ms pending mask
    // reverts the optimistic value, so the clamp would only flash. The
    // next ampIp/setting change re-runs the check; a stored out-of-range
    // volume on a powered-off amp is corrected at the first user volume
    // action after boot (every input is gated the same way), not silently
    // during boot.
    function applyImmediateClamp() {
        if (pendingAmpState.ampIp === "" || pendingAmpState.volumeDb === undefined) return;
        if (root.ampPowerState !== "On") return;
        const clamped = volumeSettings.clamp(pendingAmpState.volumeDb);
        if (clamped === pendingAmpState.volumeDb) return;
        clampExec.connectSource(root.devialetCtlCommand + " --ip " + pendingAmpState.ampIp +
            " volume " + clamped + " --hard-limit-db " + volumeSettings.hardLimitDb);
        pendingAmpState.notifyVolume(clamped);
    }

    // 2026-09-08 follow-up: the amp's PowerState ("Off"/"Booting"/"On"),
    // read once here at the root and forwarded down (CompactRepresentation
    // below; applyImmediateClamp() above) - the same root-anchored pattern
    // as PendingAmpState/VolumeSettings, chosen over giving each consumer
    // its own subscription or reaching into FlyoutContent's mirror.
    // FlyoutContent keeps its own copy on purpose: that one carries the
    // 400 ms optimistic guard for its power button and arms the boot hold;
    // this one is a plain, unguarded read used only to gate inputs, so it
    // lags the flyout's optimistic "Booting" by at most one broadcast
    // (~200 ms) after a power click. Not added to PendingAmpState (its
    // header rule restricts it to the volume/mute domain).
    property string ampPowerState: "Off"
    // Re-run the clamp check when the amp comes on. Needed for ordering,
    // not just completeness: the daemon emits one PropertiesChanged
    // message per property, so PendingAmpState's onAmpIpChanged ->
    // Qt.callLater fires between the AmpIp and PowerState messages of the
    // same burst and reads a stale "Off" (seen with the fake daemon: a
    // selection change to an already-on amp with an out-of-range volume
    // sent nothing). Same Qt.callLater target, so the two triggers
    // collapse to one call. Caveat, documented rather than solved: a
    // command fired at the first "On" can fall inside the amp's post-boot
    // acceptance window (docs/known-gotchas.md #9) and be dropped; the
    // daemon then reverts and the next ampIp/setting change or user
    // volume action re-checks. That only matters when the amp's own
    // startup volume is outside the widget's [floor, hardLimit], so it
    // is not given its own delay here.
    onAmpPowerStateChanged: if (root.ampPowerState === "On") Qt.callLater(root.applyImmediateClamp)

    Dbus.Properties {
        id: powerProps
        busType: Dbus.BusType.Session
        service: pendingAmpState.serviceName
        path: pendingAmpState.objectPath
        iface: pendingAmpState.interfaceName
        onRefreshed: root.ampPowerState = pendingAmpState.unwrap(properties.PowerState, "Off")
        onPropertiesChanged: (interfaceName, changed, invalidated) => {
            if ("PowerState" in changed) root.ampPowerState = pendingAmpState.unwrap(changed.PowerState, root.ampPowerState);
        }
    }

    compactRepresentation: CompactRepresentation {
        plasmoidItem: root
        pendingAmpState: pendingAmpState
        volumeSettings: volumeSettings
        powerState: root.ampPowerState
    }

    // Phase 7.13.0 cleanup: FullRepresentation.qml itself is deleted, but
    // `fullRepresentation:` cannot simply be omitted - tried that first,
    // and it silently removed the panel icon entirely (compactRepresentation
    // never rendered at all, confirmed live: reinstalled, restarted
    // plasmashell, no QML errors anywhere in the journal, yet the icon
    // was gone from the panel). Reading `CompactApplet.qml`'s own QML
    // (its popup Dialog and Layout hints all null-check `root.
    // fullRepresentation` gracefully) suggested this should be safe, but
    // that reasoning was wrong - something requires a full representation
    // to exist for the compact one to show at all. A trivial placeholder
    // restores the icon and the flyout both (confirmed live), without
    // reintroducing any of the deleted file's actual content.
    fullRepresentation: Item {}

    // CompactRepresentation.qml's left-click unconditionally opens
    // FlyoutPopup.qml itself; nothing in this package sets `expanded`.
    // The shell still auto-generates a per-applet "Activate Devialet
    // Remote Widget" global shortcut (confirmed in libplasma's
    // plasmoiditem.cpp: PlasmoidItem unconditionally connects `Applet::
    // activated` to `setExpanded(true)` on first activation - there is no
    // property that suppresses this, `activationTogglesExpanded` only
    // changes whether a *second* activation closes it again), so
    // `expanded` can still flip to `true` via that shortcut/Enter/Space/
    // accessibility activation on the panel icon. With a real (if empty)
    // `fullRepresentation` now present, this *can* make the shell's own
    // popup Dialog (`CompactApplet.qml`: `visible: root.plasmoidItem.
    // expanded && root.fullRepresentation`) become visible - an empty box
    // sized by its generic Kirigami fallback, not the real flyout. Left
    // unhandled deliberately: this requires deliberately configuring and
    // pressing a shortcut nobody binds by default, it auto-dismisses on
    // any click elsewhere or Escape (`hideOnWindowDeactivate`'s own
    // default, plus `CompactApplet.qml`'s `Keys.onEscapePressed`), and it
    // never conflicts with FlyoutPopup/the hover tooltip (that's driven
    // entirely by `flyoutPopup.visible` in CompactRepresentation.qml, not
    // `expanded`). An inherent constraint of the compact/full
    // representation model for any applet with no meaningful full
    // representation, not a regression introduced by this cleanup.

    // No toolTipItem binding here (Phase 4.5.3 Bug 3 fix, later revision):
    // CompactRepresentation.qml now owns its own hover-triggered
    // PlasmaCore.Dialog (VolumeHoverTooltip.qml) directly, instead of
    // handing content to the shell's own ToolTipDialog - see that file's
    // header comment for why.
    //
    // Phase 4.5.3 item 1 fix: merely leaving toolTipMainText/
    // toolTipSubText *unset* was NOT enough to make ToolTipArea::isValid()
    // return false - the native tooltip kept appearing alongside ours,
    // showing metadata.json's Name/Comment ("Devialet Remote" / "Control a
    // Devialet Expert Pro amplifier..."). Root-caused by reading
    // libplasma's plasmoiditem.cpp: PlasmoidItem::toolTipMainText()/
    // toolTipSubText() fall back to `applet()->title()`/`pluginMetaData().
    // description()` whenever the backing string is *null* - which is the
    // default, unset state - not merely empty. The setter's own comment
    // spells out the fix: "we are abusing the difference between a null
    // and an empty string... the first time it gets set, an empty
    // non-null one is set, and won't fall back anymore." Explicitly
    // assigning "" here (not omitting the binding) runs that setter once,
    // making the getter return "" instead of the metadata fallback - only
    // then does ToolTipArea::isValid() (`m_mainItem ||
    // !mainText().isEmpty() || !subText().isEmpty()`) genuinely evaluate
    // to false, letting the shell's default tooltip cleanly no-op.
    toolTipMainText: ""
    toolTipSubText: ""
}
