// Phase 7.1.0 (spike/flyout-appletpopup-rebuild branch) - the real
// PlasmaCore.AppletPopup flyout shell, promoted from the Phase 7.0.0
// spike (AppletPopupSpike.qml, now removed - see TODO.md's Phase 7.0.0
// entry and the investigation document it cites,
// context-on-spike-flyout-dialog-rebuild-b-quirky-wand.md, for that
// spike's own verification history). Still gated behind main.qml's
// appletPopupSpikeEnabled flag (default false) and still infrastructure
// only - real content starts at Phase 7.3.0, not here. See TODO.md's
// Phase 7.1.0 entry.
//
// Every dismiss/positioning/focus binding below is unchanged from the
// spike, which itself copied them deliberately from the real
// /usr/share/plasma/shells/org.kde.plasma.desktop/contents/applet/
// CompactApplet.qml (re-confirmed directly against that source again
// this phase, not from memory) - popupDirection, floating,
// removeBorderStrategy, visualParent, backgroundHints, the
// requestActivate() call (including its known
// "QWindow::setWindowState does not accept Qt::WindowActive" warning
// site - confirmed in 7.0.0 not to reproduce on this system), the
// QTBUG-146992 `enabled: dialog.visible` workaround, and the
// MouseEventListener{focus:true}/onActiveFocusChanged focus-relay
// wrapper.
//
// Two deliberate real-build deltas from the spike (this phase's task):
//
// - appletInterface is now set, to `plasmoidItem` (forwarded in via the
//   new required property below, same as CompactRepresentation.qml
//   already forwards `plasmoidItem` for other uses). The spike
//   deliberately left this unset - appletpopup.h documents it as a
//   QQuickItem* (internally stored as QPointer<AppletQuickItem>), and
//   CompactApplet.qml's own real popup sets it to `root.plasmoidItem`
//   (PlasmoidItem IS-A AppletQuickItem, confirmed directly against both
//   headers again this phase) specifically so AppletPopup can persist
//   popupWidth/popupHeight into the applet's own KConfig group
//   (appletpopup.h's m_sizeExplicitlySetFromConfig / hideEvent()
//   override). Leaving it unset in the spike avoided a throwaway popup
//   silently overwriting the real flyout's persisted size while both
//   coexisted; now that this component IS the real flyout, it should own
//   that persistence the same way CompactApplet.qml's own popup did.
// - hideOnWindowDeactivate now mirrors `plasmoidItem.
//   hideOnWindowDeactivate` (the real per-applet property
//   CompactApplet.qml itself reads, confirmed at its dialog's own
//   `hideOnWindowDeactivate: root.plasmoidItem.hideOnWindowDeactivate`
//   binding), not the spike's hardcoded `true`.
//
// Phase 7.2.0: a LayoutProbe (see LayoutProbe.qml) is instantiated inside
// mainItem below - the QML half of tools/flyout-harness/. Inert unless the
// harness's own bus name is registered; safe to ship permanently (see that
// file's header). Placeholder content is unchanged by that phase.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import org.kde.kquickcontrolsaddons

PlasmaCore.AppletPopup {
    id: flyoutPopup

    // Named `flyoutVisualParent`, not `visualParent`, to avoid shadowing
    // this component's own inherited `visualParent` property below -
    // same reasoning the spike's `spikeVisualParent` used.
    required property Item flyoutVisualParent
    required property PlasmoidItem plasmoidItem

    // Window-derived types default to visible:true in QML - CompactApplet.
    // qml overrides this with an explicit binding
    // (`visible: root.plasmoidItem.expanded && root.fullRepresentation`);
    // without an equivalent explicit initial value here, this popup
    // auto-opens on plasmashell startup, before any click (found the hard
    // way in the Phase 7.0.0 spike - see TODO.md). This assignment is
    // only the initial value, not a binding - CompactRepresentation.qml's
    // onClicked handler still freely reassigns flyoutPopup.visible
    // afterward.
    visible: false

    popupDirection: {
        switch (Plasmoid.location) {
        case PlasmaCore.Types.TopEdge: return Qt.BottomEdge;
        case PlasmaCore.Types.LeftEdge: return Qt.RightEdge;
        case PlasmaCore.Types.RightEdge: return Qt.LeftEdge;
        default: return Qt.TopEdge;
        }
    }

    floating: Plasmoid.location === PlasmaCore.Types.Floating
    removeBorderStrategy: Plasmoid.location === PlasmaCore.Types.Floating
        ? PlasmaCore.AppletPopup.AtScreenEdges
        : PlasmaCore.AppletPopup.AtScreenEdges | PlasmaCore.AppletPopup.AtPanelEdges

    hideOnWindowDeactivate: flyoutPopup.plasmoidItem.hideOnWindowDeactivate
    visualParent: flyoutPopup.flyoutVisualParent
    backgroundHints: PlasmaCore.AppletPopup.StandardBackground
    appletInterface: flyoutPopup.plasmoidItem

    onVisibleChanged: {
        if (flyoutPopup.visible) {
            console.log("[FlyoutPopup] opening - about to call requestActivate()");
            // Same call site, same known warning, as CompactApplet.qml's
            // own dialog.requestActivate() - see this file's header.
            flyoutPopup.requestActivate();
        } else {
            console.log("[FlyoutPopup] closed");
        }
    }

    // It's a MouseEventListener to get all the events, matching
    // CompactApplet.qml's own comment on why (so the eventfilter can
    // catch them).
    mainItem: MouseEventListener {
        id: flyoutMainItem
        focus: true

        // QTBUG-146992 workaround, same as CompactApplet.qml's mainItem.
        enabled: flyoutPopup.visible

        implicitWidth: Kirigami.Units.gridUnit * 18
        implicitHeight: Kirigami.Units.gridUnit * 10

        Keys.onEscapePressed: flyoutPopup.visible = false

        onActiveFocusChanged: {
            console.log("[FlyoutPopup] mainItem activeFocus:", flyoutMainItem.activeFocus);
            if (flyoutMainItem.activeFocus) {
                focusTestField.forceActiveFocus();
            }
        }

        // Phase 7.2.0 harness probe - non-visual, drives popup visibility
        // and logs every item's coordinates only while
        // tools/flyout-harness/ is running. Content phases (7.3.0+) point
        // `uiTarget` at the item owning QML-internal UI state such as
        // ampListOpen; for the placeholder there is none yet.
        LayoutProbe {
            popup: flyoutPopup
            root: flyoutMainItem
        }

        // Placeholder content only - real flyout content starts at Phase
        // 7.3.0 (see TODO.md). Do not port FullRepresentation.qml UI in
        // here as part of this phase.
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "AppletPopup spike — no real content yet"
            }

            TextField {
                id: focusTestField
                Layout.fillWidth: true
                placeholderText: "Type here to test keyboard focus"
                onActiveFocusChanged: console.log("[FlyoutPopup] focusTestField activeFocus:", focusTestField.activeFocus)
            }

            Label {
                Layout.fillWidth: true
                text: focusTestField.activeFocus
                    ? "✓ TextField has active focus"
                    : "✗ TextField does NOT have active focus"
                color: focusTestField.activeFocus ? "#3fb950" : "#f85149"
            }

            Button {
                Layout.alignment: Qt.AlignRight
                text: "Close"
                onClicked: flyoutPopup.visible = false
            }
        }
    }
}
