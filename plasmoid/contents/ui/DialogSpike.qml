// Phase 7.9.0 spike (spike/flyout-appletpopup-rebuild branch) - THROWAWAY.
// A bare PlasmaCore.Dialog with backgroundHints: NoBackground and
// type: AppletPopup, hosting the one thing Phase 7.0.0's AppletPopup spike
// never had to prove for THIS window class: a real Overlay.overlay-hosted
// popup (a PlasmaComponents3.ComboBox, the exact type SourceSelector.qml
// uses; its popup is a T.Popup reparented into the window's Overlay, same
// as AmpListOverlay.qml's own Popup). See TODO.md's Phase 7.9.0 entry and
// the investigation document (context-an-actual-giggly-prism.md) for why
// this exists - the short version: the whole Phase 7.x rebuild was for
// real transparency, and PlasmaCore.AppletPopup (PlasmaWindow family) has
// no NoBackground value; PlasmaCore.Dialog does.
//
// No real flyout content. Do not port FlyoutContent.qml in here, and do
// not touch FlyoutPopup.qml / any section component for this phase.
//
// Deliberately NOT set: `appletInterface`. Dialog::hideEvent() (dialog.cpp
// 1456-1467) writes popupWidth/popupHeight into the applet's KConfig group
// on every hide whenever appletInterface is set - the same size-key
// collision CLAUDE.md documents for AppletPopup. Leaving it unset means
// this throwaway window can never clobber the real flyout's persisted
// size (verified after the run by comparing the keys before/after).
//
// Deliberately NOT set: `flags`. VolumeHoverTooltip.qml/VolumeToast.qml
// both override flags with Qt.WindowDoesNotAcceptFocus (they are display-
// only); this spike needs keyboard focus, so it keeps Dialog's own
// constructor default (Qt::FramelessWindowHint | Qt::Dialog, dialog.cpp
// 852) and lets applyType() call setTakesFocus(true) from that.
//
// Driven two ways:
//  - main.qml's `dialogSpikeEnabled` flag (default false): when true,
//    CompactRepresentation.qml's left-click toggles this instead of the
//    real flyout, for a human to click/type at it for real.
//  - tools/dialog-spike/spike.py: owns a session-bus name that the Loader
//    below watches; while it is owned, DialogSpikeDriver.qml is loaded and
//    executes commands (open/close/click/key/dump...) sent over D-Bus,
//    logging JSON results to journald. Inert (not even loaded) otherwise.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import org.kde.kquickcontrolsaddons
import org.kde.plasma.workspace.dbus as Dbus

PlasmaCore.Dialog {
    id: spike

    required property Item spikeVisualParent
    // Optional: CompactRepresentation.qml's own VolumeHoverTooltip, so the
    // driver can show the existing NoBackground reference look side by
    // side (and measure its known clip bug) at the same anchor.
    property var tooltipRef: null
    // Optional: the real FlyoutPopup (PlasmaCore.AppletPopup), so the
    // driver can run the identical synthetic-click sequence against the
    // shipped window class as an A/B control (read-only use: it opens the
    // source dropdown and clicks empty space; it never picks a source, so
    // nothing is sent to the amp).
    property var flyoutRef: null

    readonly property string spikeService: "com.ekmanch.DevialetRemote.DialogSpike"

    // KWin-script lookup handle (workspace.windowList() -> caption).
    title: "DialogSpike"

    // Window-derived types default to visible:true in QML (the Phase 7.0.0
    // spike auto-opened on shell start without this).
    visible: false

    type: PlasmaCore.Dialog.AppletPopup
    backgroundHints: PlasmaCore.Dialog.NoBackground
    location: Plasmoid.location
    visualParent: spike.spikeVisualParent
    hideOnWindowDeactivate: true

    onVisibleChanged: {
        console.log("[DialogSpike] visible ->", spike.visible, "geom", spike.x, spike.y, spike.width, spike.height);
        if (spike.visible) {
            spike.requestActivate();
        }
    }
    onActiveChanged: console.log("[DialogSpike] active ->", spike.active)
    onWindowDeactivated: console.log("[DialogSpike] windowDeactivated signal (hideOnWindowDeactivate path fired)")
    onXChanged: console.log("[DialogSpike] x ->", spike.x)
    onYChanged: console.log("[DialogSpike] y ->", spike.y)

    mainItem: MouseEventListener {
        id: spikeMainItem
        focus: true
        // QTBUG-146992 workaround, same as CompactApplet.qml / FlyoutPopup.qml.
        enabled: spike.visible

        // `grow` lets the driver change the content size while open, to
        // check that Dialog re-positions on a mainItem resize (the
        // suspected mechanism behind VolumeHoverTooltip.qml's clip bug).
        property bool grow: false
        // `wide` (driver command wide:true|false): 500px wide - wider than
        // the room to the right of this panel icon (centre x 1718 on a
        // 1920-wide screen), to exercise popupPosition()'s right-edge
        // clamp live rather than only its centred default.
        property bool wide: false
        implicitWidth: wide ? 500 : (grow ? 360 : 300)
        implicitHeight: grow ? 420 : 260

        // Finding from the first run: Dialog sizes its window from
        // mainItem's *actual* width/height at show time and then owns
        // that size (DialogPrivate::updateLayoutParameters() calls
        // mainItem->setSize() from the window's size) - a later change of
        // mainItem's implicit size is ignored, unlike AppletPopup, which
        // reads implicit sizes through LayoutChangedProxy. What Dialog
        // does listen to (dialog.cpp updateMinimumWidth() & friends,
        // getSizeHints()) are the Layout.minimum*/maximum* attached hints
        // - the same four properties FlyoutPopup.qml already pins for
        // Phase 7.7.0's no-resize guarantee. `pin` (driver command
        // pin:true|false) toggles them so both behaviours can be measured.
        // pin:false hung plasmashell (see TODO.md): a Layout max of 0 makes
        // Dialog's getSizeHints() fall back to DIALOGSIZE_MAX while the min
        // is 0 - left permanently pinned; the unpinned behaviour was already
        // measured on the first run (window ignored implicit-size changes).
        property bool pin: true
        Layout.minimumWidth: implicitWidth
        Layout.maximumWidth: implicitWidth
        Layout.minimumHeight: implicitHeight
        Layout.maximumHeight: implicitHeight

        // Workaround under test for the Qt 6.11 QQuickOverlay placement
        // bug found by the first run: QQuickOverlayPrivate::updateGeometry()
        // (qquickoverlay.cpp 340-352) positions the overlay at
        // -(contentItem.size - window.size)/2, and Dialog resizes its
        // contentItem *before* its window (dialog.cpp syncToMainItemSize:
        // contentItem()->setSize(s) then adjustGeometry(geom)), so the
        // overlay is computed against the stale window size (0x0 on first
        // show -> (-150,-130)) and never recomputed - the later window
        // resize leaves the contentItem's size unchanged, so no geometry
        // signal fires. Every Overlay-hosted popup (the ComboBox dropdown)
        // then renders shifted by that offset and press-outside-to-close
        // only works inside the shifted rect. Fix: reset the overlay to
        // (0,0) whenever the window's size lands.
        property bool overlayFix: true
        function fixOverlay(reason) {
            const ov = Overlay.overlay;
            if (!spikeMainItem.overlayFix || !ov) return;
            if (ov.x !== 0 || ov.y !== 0) {
                console.log("[DialogSpike] overlay offset", ov.x, ov.y, "(" + reason + ") -> reset to 0,0");
                ov.x = 0;
                ov.y = 0;
            }
        }
        Connections {
            target: spike
            function onWidthChanged() { spikeMainItem.fixOverlay("width " + spike.width); }
            function onHeightChanged() { spikeMainItem.fixOverlay("height " + spike.height); }
            function onVisibleChanged() { spikeMainItem.fixOverlay("visible " + spike.visible); }
        }

        Keys.onEscapePressed: {
            console.log("[DialogSpike] Keys.onEscapePressed on mainItem");
            spike.visible = false;
        }
        // Phase 7.8.0's window-scoped fallback, carried over as-is.
        Shortcut {
            sequence: "Escape"
            context: Qt.WindowShortcut
            enabled: spike.visible
            onActivated: {
                console.log("[DialogSpike] window Shortcut(Escape) activated");
                spike.visible = false;
            }
        }

        onActiveFocusChanged: {
            console.log("[DialogSpike] mainItem activeFocus:", spikeMainItem.activeFocus);
            if (spikeMainItem.activeFocus) {
                combo.forceActiveFocus();
            }
        }

        // The card. A 12px fully transparent band around it is the
        // transparency probe: with NoBackground those pixels must be the
        // desktop, untouched; the card itself is 55% alpha so what is
        // behind it must show through (blended, not blurred - dialog.cpp
        // disables blur-behind for NoBackground, which this checks).
        Rectangle {
            id: card
            anchors.fill: parent
            anchors.margins: 12
            radius: 12
            color: Qt.rgba(0.12, 0.11, 0.10, 0.55)
            border.width: 1
            border.color: "#b87333"

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 8

                Label {
                    Layout.fillWidth: true
                    text: "Dialog spike (NoBackground)"
                    color: "#f0e6dc"
                }

                PlasmaComponents3.ComboBox {
                    id: combo
                    objectName: "spikeCombo"
                    Layout.fillWidth: true
                    model: ["Optical 1", "Optical 2", "Coaxial 1", "USB", "Phono", "AES/EBU", "Line 1", "Line 2"]
                    onActivated: (idx) => console.log("[DialogSpike] combo activated idx", idx)
                    onActiveFocusChanged: console.log("[DialogSpike] combo activeFocus:", combo.activeFocus)
                    Component.onCompleted: {
                        combo.popup.onOpened.connect(() => console.log("[DialogSpike] combo popup opened"));
                        combo.popup.onClosed.connect(() => console.log("[DialogSpike] combo popup closed"));
                    }
                }

                TextField {
                    id: textField
                    objectName: "spikeTextField"
                    Layout.fillWidth: true
                    placeholderText: "Type here to test keyboard focus"
                    onActiveFocusChanged: console.log("[DialogSpike] textField activeFocus:", textField.activeFocus)
                }

                Label {
                    Layout.fillWidth: true
                    text: combo.activeFocus ? "✓ ComboBox has active focus"
                        : (textField.activeFocus ? "✓ TextField has active focus" : "✗ neither control has active focus")
                    color: (combo.activeFocus || textField.activeFocus) ? "#3fb950" : "#f85149"
                }

                Item { Layout.fillHeight: true }

                Button {
                    Layout.alignment: Qt.AlignRight
                    text: "Close"
                    onClicked: spike.visible = false
                }
            }
        }

        // Driver, loaded only while tools/dialog-spike/spike.py owns the
        // bus name (same DBusServiceWatcher/Loader shape LayoutProbe.qml
        // uses). Its `import QtTest` (synthetic in-process mouse/key
        // events) is therefore only ever loaded into plasmashell while a
        // spike run is in progress.
        Dbus.DBusServiceWatcher {
            id: watcher
            busType: Dbus.BusType.Session
            watchedService: spike.spikeService
        }
        Loader {
            id: driverLoader
            active: watcher.registered
            source: active ? "DialogSpikeDriver.qml" : ""
            onLoaded: {
                item.spike = spike;
                item.mainItem = spikeMainItem;
                item.combo = combo;
                item.textField = textField;
                item.tooltipRef = spike.tooltipRef;
                item.flyoutRef = spike.flyoutRef;
                item.start();
            }
        }
    }
}
