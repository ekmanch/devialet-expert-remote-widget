// Phase 7.0.0 spike (spike/flyout-appletpopup-rebuild branch) - THROWAWAY,
// infrastructure-only test of PlasmaCore.AppletPopup, driven directly by
// this plasmoid instead of going through the shell's own
// CompactApplet.qml-managed fullRepresentation popup. See TODO.md's
// Phase 7.0.0 entry and the investigation document it cites
// (context-on-spike-flyout-dialog-rebuild-b-quirky-wand.md, §3 and §6
// step 2) for why this exists. Gated behind main.qml's
// appletPopupSpikeEnabled flag (default false) - CompactRepresentation.qml
// only opens THIS popup instead of the real flyout when that flag is
// true; with it false, this file is loaded but never shown, and the
// existing shell-managed flyout is completely unaffected.
//
// No real flyout content - do not port FullRepresentation.qml UI in here.
// A placeholder Label plus one interactive TextField (to make focus
// observable/testable) is all this needs.
//
// Every dismiss/positioning/focus binding below is copied deliberately
// from the real
// /usr/share/plasma/shells/org.kde.plasma.desktop/contents/applet/
// CompactApplet.qml (read directly this session via the Read tool, not
// from memory of the investigation doc's summary) - popupDirection,
// floating, removeBorderStrategy, visualParent, backgroundHints, the
// requestActivate() call (including its known
// "QWindow::setWindowState does not accept Qt::WindowActive" warning
// site), the QTBUG-146992 `enabled: dialog.visible` workaround, and the
// MouseEventListener{focus:true}/onActiveFocusChanged focus-relay
// wrapper - so this spike genuinely exercises the same wiring the
// shell's own popup depends on, not a simplified stand-in that wouldn't
// actually answer the open question.
//
// Deliberately NOT set: `appletInterface`. The real CompactApplet.qml
// binds it so AppletPopup can persist popupWidth/popupHeight into the
// applet's own KConfig group (confirmed in appletpopup.cpp's
// setAppletInterface()/hideEvent()). The shell's real AppletPopup
// (wrapping FullRepresentation) already reads/writes those same two
// keys for this same applet - setting appletInterface here too would
// mean this throwaway popup silently overwrites the real flyout's
// persisted size. Sizing this spike relies purely on mainItem's own
// Layout hints (LayoutChangedProxy in appletpopup.cpp connects to those
// regardless of appletInterface), so omitting it costs nothing for what
// this spike actually needs to test.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import org.kde.kquickcontrolsaddons

PlasmaCore.AppletPopup {
    id: spikePopup

    required property Item spikeVisualParent

    // Window-derived types default to visible:true in QML - CompactApplet.
    // qml overrides this with an explicit binding
    // (`visible: root.plasmoidItem.expanded && root.fullRepresentation`);
    // without an equivalent explicit initial value here, this spike popup
    // auto-opened on plasmashell startup, before any click - confirmed
    // live via journald ("[AppletPopupSpike] opening..." ~5s after
    // process start, no click made). This assignment is only the initial
    // value, not a binding - CompactRepresentation.qml's onClicked handler
    // still freely reassigns spikePopup.visible afterward.
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

    // Hardcoded true, not mirrored from a settings toggle - this spike
    // exists specifically to answer "does click-outside dismiss work",
    // so it needs to always be on to test that.
    hideOnWindowDeactivate: true
    visualParent: spikePopup.spikeVisualParent
    backgroundHints: PlasmaCore.AppletPopup.StandardBackground

    onVisibleChanged: {
        if (spikePopup.visible) {
            console.log("[AppletPopupSpike] opening - about to call requestActivate()");
            // Same call site, same known warning, as CompactApplet.qml's
            // own dialog.requestActivate() - see this file's header.
            spikePopup.requestActivate();
        } else {
            console.log("[AppletPopupSpike] closed");
        }
    }

    // It's a MouseEventListener to get all the events, matching
    // CompactApplet.qml's own comment on why (so the eventfilter can
    // catch them).
    mainItem: MouseEventListener {
        id: spikeMainItem
        focus: true

        // QTBUG-146992 workaround, same as CompactApplet.qml's mainItem.
        enabled: spikePopup.visible

        implicitWidth: Kirigami.Units.gridUnit * 18
        implicitHeight: Kirigami.Units.gridUnit * 10

        Keys.onEscapePressed: spikePopup.visible = false

        onActiveFocusChanged: {
            console.log("[AppletPopupSpike] mainItem activeFocus:", spikeMainItem.activeFocus);
            if (spikeMainItem.activeFocus) {
                focusTestField.forceActiveFocus();
            }
        }

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
                onActiveFocusChanged: console.log("[AppletPopupSpike] focusTestField activeFocus:", focusTestField.activeFocus)
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
                onClicked: spikePopup.visible = false
            }
        }
    }
}
