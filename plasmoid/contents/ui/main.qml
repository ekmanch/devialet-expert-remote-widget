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
    }

    // Phase 7.0.0 spike toggle (spike/flyout-appletpopup-rebuild branch,
    // THROWAWAY - not a real feature, do not wire to config.qml/main.xml).
    // When true, CompactRepresentation.qml's left-click handler opens
    // AppletPopupSpike.qml (a bare PlasmaCore.AppletPopup with placeholder
    // content) instead of toggling `expanded`/the real flyout.
    // fullRepresentation stays bound either way below - the shell's own
    // AppletPopup wrapping it just never becomes visible while this is
    // true, since nothing sets `expanded = true` in that branch. Default
    // false keeps the existing, fully-working compact->full path
    // completely untouched; flip this one line to test the spike instead.
    // See TODO.md's Phase 7.0.0 entry and the investigation document it
    // cites.
    readonly property bool appletPopupSpikeEnabled: false

    compactRepresentation: CompactRepresentation {
        plasmoidItem: root
        pendingAmpState: pendingAmpState
        appletPopupSpikeEnabled: root.appletPopupSpikeEnabled
    }

    fullRepresentation: FullRepresentation {
        plasmoidItem: root
        pendingAmpState: pendingAmpState
    }

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
