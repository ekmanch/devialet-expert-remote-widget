// Phase 7.10.0 (spike/flyout-appletpopup-rebuild branch) - the real flyout
// shell, rebuilt on PlasmaCore.Dialog. Phases 7.1.0-7.8.0 built this same
// file on PlasmaCore.AppletPopup (PlasmaWindow family), which was the
// wrong class for the rebuild's actual goal - real desktop transparency,
// matching VolumeHoverTooltip.qml/VolumeToast.qml: PlasmaWindow's
// BackgroundHints has no NoBackground value at all, so the shell frame
// (opaque under Darkly) could never be removed. PlasmaCore.Dialog has a
// real, code-enforced NoBackground (dialog.cpp updateTheme(): empty frame
// image path, blur-behind off, no shadow). See TODO.md's Phase 7.0.0
// correction and the Phase 7.9.0 spike entry, whose findings this file
// implements one by one below.
//
// What carries over from the AppletPopup version unchanged: mainItem's
// MouseEventListener{focus:true} wrapper and its focus relay into
// FlyoutContent, the QTBUG-146992 `enabled: visible` workaround, the
// requestActivate() call on open, the Phase 7.7.0 Layout min/max pin, the
// Keys.onEscapePressed + Phase 7.8.0 window-scoped Escape Shortcut pair,
// the Phase 7.2.0 LayoutProbe, and every property CompactRepresentation.
// qml touches (`visible`, `flyoutVisualParent`, `plasmoidItem`,
// `pendingAmpState`) - CompactRepresentation.qml itself is unchanged.
//
// What changed, and why (each one a Phase 7.9.0 finding or a class API
// difference, none of them guesses):
//
// - `type: AppletPopup`, `backgroundHints: NoBackground`, `location:
//   Plasmoid.location` replace AppletPopup's popupDirection/
//   removeBorderStrategy/floating. Dialog has no popupDirection (it
//   positions from `location` + `visualParent`, dialog.cpp
//   popupPosition()), no removeBorderStrategy (nothing to remove: with
//   NoBackground there is no frame), and its `floating` is an int inset
//   we don't need (it was never set here either).
//
// - `appletInterface` is deliberately NOT set (the AppletPopup version set
//   it to plasmoidItem for popupWidth/popupHeight persistence). Read from
//   dialog.cpp 6.7.4: with appletInterface set, Dialog::hideEvent() writes
//   popupWidth/popupHeight into the applet's KConfig group on EVERY hide,
//   and the only reader, updateSizeFromAppletInterface(), returns early
//   when the Layout min/max hints are equal - which they always are here
//   (the 7.7.0 pin). So on this window the property would buy a KConfig
//   write per close and nothing else, while keeping alive exactly the
//   size-key collision CLAUDE.md documents. Leaving it unset means this
//   window never touches those keys. (Dialog's other appletInterface use,
//   updateResizableEdges(), also collapses to "no resizable edges" when
//   min == max.)
//
// - `visualParent` is `panelSpan` below, not the icon item directly.
//   Finding 7.9.0 (4): Dialog anchors the popup to the visualParent
//   item's own bounds (popupPosition(): bottomPoint = the item's
//   mapRectToScene().bottom()), while AppletPopup anchored to the panel
//   window's edge - a 4px difference on this panel (icon bottom y=32,
//   panel bottom y=36), i.e. the flyout would overlap the panel's bottom
//   4px. Rather than a transparent strip inside mainItem (which would
//   also change the pinned window size), panelSpan is a zero-cost
//   invisible Item reparented into the panel's own scene that covers the
//   icon's extent along the panel and the panel window's FULL thickness
//   across it, so Dialog's own bottomPoint/topPoint/leftPoint/rightPoint
//   lands exactly on the panel edge - the same place AppletPopup put it.
//   Its geometry is a live binding (ancestor x/y walk, see the comment on
//   it), not a one-shot measurement.
//
// - Overlay.overlay reset (finding 7.9.0 (1), a real Qt 6.11 bug):
//   QQuickOverlayPrivate::updateGeometry() (qquickoverlay.cpp) places the
//   window's overlay at -(contentItem.size - window.size)/2 and only
//   recomputes on contentItem geometry changes; Dialog resizes its
//   contentItem BEFORE its window (dialog.cpp syncToMainItemSize():
//   contentItem()->setSize(s) then adjustGeometry(geom)), so the overlay
//   is computed against the stale window size and never fixed up.
//   Symptom, measured live in the spike: every Overlay-hosted popup (the
//   source ComboBox dropdown, AmpListOverlay) renders shifted by that
//   offset and press-outside-to-close is dead outside the shifted rect.
//   AppletPopup (7.1.0-7.8.0) never hit this. fixOverlay() below resets
//   the overlay to (0,0) whenever the window's size or visibility lands;
//   verified in the spike to make the dropdown render in place and
//   press-outside close it again.
//
// - Sizing (finding 7.9.0 (2)): Dialog takes its window size from
//   mainItem's actual size at show and thereafter follows ONLY the
//   Layout.minimum*/maximum* attached hints (dialog.cpp getSizeHints() /
//   updateMinimumWidth() & co), not mainItem's implicit size. The four
//   hints below are therefore the sizing mechanism as well as the 7.7.0
//   no-resize pin. HARD RULE: never bind them to 0, unset them, or
//   otherwise zero them while the Dialog is shown - Phase 7.9.0 did that
//   once (a `pin` toggle) and plasmashell died with a Wayland protocol
//   error ("The Wayland connection experienced a fatal error"), taking
//   the whole shell down. They are bound permanently to the content's
//   implicit size, which is never 0 once FlyoutContent has loaded.
//
// - Positioning against the screen edge, blur, dismiss, Escape, focus:
//   all verified on the spike (TODO.md 7.9.0); no KWin blur is expected
//   or wanted - NoBackground is plain alpha over the desktop, exactly
//   like the tooltip/toast.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import org.kde.kquickcontrolsaddons

PlasmaCore.Dialog {
    id: flyoutPopup

    // Named `flyoutVisualParent`, not `visualParent`, to avoid shadowing
    // this component's own inherited `visualParent` property (which is
    // bound to panelSpan below, not to this item directly - see header).
    required property Item flyoutVisualParent
    required property PlasmoidItem plasmoidItem
    // Forwarded through to FlyoutContent (Phase 5's shared pending-state
    // consumer).
    required property PendingAmpState pendingAmpState

    // Window-derived types default to visible:true in QML; without an
    // explicit initial value this popup auto-opens on plasmashell startup
    // (found the hard way in the Phase 7.0.0 spike). Initial value only,
    // not a binding - CompactRepresentation.qml's onClicked reassigns it.
    visible: false

    type: PlasmaCore.Dialog.AppletPopup
    backgroundHints: PlasmaCore.Dialog.NoBackground
    location: Plasmoid.location
    hideOnWindowDeactivate: flyoutPopup.plasmoidItem.hideOnWindowDeactivate
    visualParent: panelSpan

    onVisibleChanged: {
        if (flyoutPopup.visible) {
            console.log("[FlyoutPopup] opening - about to call requestActivate()");
            // Same call site as CompactApplet.qml's own dialog.
            // requestActivate() (its known "QWindow::setWindowState does
            // not accept Qt::WindowActive" warning did not reproduce on
            // this system, Phase 7.0.0/7.9.0).
            flyoutPopup.requestActivate();
        } else {
            console.log("[FlyoutPopup] closed");
        }
    }

    // Panel-edge anchor for Dialog::popupPosition() - see header. Declared
    // here (so this file owns the whole positioning story) but reparented
    // into the panel scene, as a child of the icon item, so that
    // mapRectToScene()/window() inside popupPosition() resolve against the
    // panel window. Invisible and never painted or hit-tested; geometry is
    // all it contributes.
    Item {
        id: panelSpan
        objectName: "flyoutPanelSpan"
        parent: flyoutPopup.flyoutVisualParent
        visible: false
        enabled: false

        // Which axis runs along the panel. Floating/Desktop (no edge) is
        // treated as horizontal, matching popupPosition()'s own default
        // branch (topPoint, i.e. bottom-edge behaviour).
        readonly property bool alongX: Plasmoid.location !== PlasmaCore.Types.LeftEdge
                                    && Plasmoid.location !== PlasmaCore.Types.RightEdge

        // The icon item's origin in its window, as a live binding: QML
        // tracks every `x`, `y` and `parent` read inside this loop, so a
        // panel re-layout that moves the applet re-evaluates it. (Item.
        // mapToItem() would give the same number but is not reactive.)
        readonly property point iconOrigin: {
            let x = 0, y = 0;
            for (let i = flyoutPopup.flyoutVisualParent; i; i = i.parent) {
                x += i.x;
                y += i.y;
            }
            return Qt.point(x, y);
        }

        // +1 on the far side only: popupPosition() reads the anchor's
        // far edge through QRect::bottom()/right(), which are inclusive
        // (top + height - 1), so an exact span lands the popup 1px inside
        // the panel (measured: y=35 on a 36px panel, and the icon-anchored
        // spike's y=32 for a 3..33 icon). The near edges use top()/left()
        // and need no correction. Window.* is the panel window's size -
        // the attached property follows this item's real window after the
        // reparent.
        x: alongX ? 0 : -iconOrigin.x
        y: alongX ? -iconOrigin.y : 0
        width: alongX ? (parent ? parent.width : 0) : Window.width + 1
        height: alongX ? Window.height + 1 : (parent ? parent.height : 0)
    }

    // It's a MouseEventListener to get all the events, matching
    // CompactApplet.qml's own comment on why (so the eventfilter can
    // catch them).
    mainItem: MouseEventListener {
        id: flyoutMainItem
        focus: true

        // QTBUG-146992 workaround, same as CompactApplet.qml's mainItem.
        enabled: flyoutPopup.visible

        // Content-driven size. No binding loop: FlyoutContent's implicit
        // sizes (theme.panelWidth, mainColumn.implicitHeight) don't depend
        // on its own width/height.
        implicitWidth: flyoutContent.implicitWidth
        implicitHeight: flyoutContent.implicitHeight

        // Phase 7.7.0 pin, now also Dialog's sizing mechanism - see header
        // ("Sizing"). Never zero these while shown: it crashes plasmashell.
        Layout.minimumWidth: flyoutContent.implicitWidth
        Layout.maximumWidth: flyoutContent.implicitWidth
        Layout.minimumHeight: flyoutContent.implicitHeight
        Layout.maximumHeight: flyoutContent.implicitHeight

        // Qt 6.11 QQuickOverlay placement bug workaround - see header
        // ("Overlay.overlay reset"). Overlay.overlay here is this window's
        // overlay (mainItem lives in the Dialog window).
        function fixOverlay(reason) {
            const ov = Overlay.overlay;
            if (!ov) {
                return;
            }
            if (ov.x !== 0 || ov.y !== 0) {
                console.log("[FlyoutPopup] overlay offset", ov.x, ov.y, "(" + reason + ") -> reset to 0,0");
                ov.x = 0;
                ov.y = 0;
            }
        }
        Connections {
            target: flyoutPopup
            function onWidthChanged() { flyoutMainItem.fixOverlay("width " + flyoutPopup.width); }
            function onHeightChanged() { flyoutMainItem.fixOverlay("height " + flyoutPopup.height); }
            function onVisibleChanged() { flyoutMainItem.fixOverlay("visible " + flyoutPopup.visible); }
        }

        Keys.onEscapePressed: flyoutPopup.visible = false

        // Phase 7.8.0 Step A fix, kept: a QtQuick.Controls Popup
        // (AmpListOverlay, SourceSelector's ComboBox dropdown) reparents
        // its content into the window's Overlay.overlay, a SIBLING of
        // mainItem, so Keys.onEscapePressed's parent-chain bubbling never
        // reaches flyoutMainItem once focus has been there - confirmed
        // outright in the 7.9.0 spike (the Keys handler never fired with
        // focus on the ComboBox; this window-scoped Shortcut did, closing
        // the dropdown first and the window on the second press).
        Shortcut {
            sequence: "Escape"
            context: Qt.WindowShortcut
            enabled: flyoutPopup.visible
            onActivated: flyoutPopup.visible = false
        }

        // Relay focus into the real flyout content - the same
        // MouseEventListener -> content relay CompactApplet.qml uses to
        // hand focus to fullRepresentation.
        onActiveFocusChanged: {
            console.log("[FlyoutPopup] mainItem activeFocus:", flyoutMainItem.activeFocus);
            if (flyoutMainItem.activeFocus) {
                flyoutContent.forceActiveFocus();
            }
        }

        // Phase 7.2.0 harness probe - non-visual, drives popup visibility
        // and logs every item's coordinates only while
        // tools/flyout-harness/ is running. `popup` is a var on the probe
        // side, so the Dialog fits the same slot AppletPopup did (it reads
        // x/y/width/height/visible/active, all present on both).
        LayoutProbe {
            popup: flyoutPopup
            root: flyoutMainItem
            uiTarget: flyoutContent
        }

        // The real flyout content - see FlyoutContent.qml. With
        // NoBackground, its own tint Rectangle is now the flyout's entire
        // visible surface, edge to edge (its old frame-inset bleed went
        // with the frame - see the 7.10.0 note there).
        FlyoutContent {
            id: flyoutContent
            anchors.fill: parent
            plasmoidItem: flyoutPopup.plasmoidItem
            pendingAmpState: flyoutPopup.pendingAmpState
            popupVisible: flyoutPopup.visible
        }
    }
}
