// Phase 4.5.0: copper-styled reskin of Plasma's own native volume OSD
// (org.kde.plasmashell, /org/kde/osdService, org.kde.osdService.showText/
// volumeChanged - see plasma-workspace's shell/osd.cpp and
// org.kde.plasma.workspace.osd's OsdItem.qml, both read directly from
// invent.kde.org during investigation, not guessed). Deliberately a visual
// reskin only - the interaction design (when it shows, how long it stays,
// what happens on rapid repeat) is copied byte-for-byte from that real
// service, not reinvented:
//
// - Timing: 1800ms fixed dismiss, OsdItem.qml's own real default
//   (`property int timeout: 1800`, confirmed by reading the file installed
//   on this system at /usr/lib/qt6/qml/org/kde/plasma/workspace/osd/
//   OsdItem.qml:19) - not a rough "~1s" guess.
// - Rapid-repeat: matches Osd::showOsd() (plasma-workspace's shell/osd.cpp)
//   exactly - every call stops the pending dismiss timer, snaps the
//   content to the new value instantly (no queueing, no fade-in replay),
//   then restarts the same fixed timeout from zero. One reusable instance,
//   one non-repeating Timer, `restart()` on every show() call - same
//   shape as the real showOsd()'s stop/update/start sequence.
// - Placement: PlasmaCore.Dialog's `type: OnScreenDisplay` is the exact
//   mechanism the real OSD's own window uses for automatic screen-relative
//   (bottom-center) placement - confirmed by reading libplasma's
//   dialog.cpp: on Wayland (this session's compositor), setting this type
//   calls the identical `PlasmaShellWaylandIntegration::setRole(
//   role_onscreendisplay)` plasma-workspace's own shell/osdwindow.cpp calls
//   for the real OSD, and dialog.cpp deliberately skips its own manual
//   setPosition() call for this type specifically ("if is a wayland window
//   ... if (type != Dialog::OnScreenDisplay) setPosition(...)) - the
//   compositor places it, not us, same as the real one. Not an icon-
//   anchored popup like the flyout - a faithful reskin means matching
//   where the native OSD already appears, not inventing new placement.
//
// NOT the same "no NoBackground exists" dead end CLAUDE.md's real-
// transparency investigation hit - that was about PlasmaWindow (the
// flyout's own popup window class, PlasmaQuick::AppletPopup ->
// PopupPlasmaWindow -> PlasmaWindow). This is a different class,
// PlasmaQuick::Dialog, built directly by this file rather than provided
// implicitly by PlasmoidItem's fullRepresentation machinery - its
// BackgroundHints enum (confirmed in libplasma's dialog.h) does include a
// real NoBackground value, which is what makes the fully custom copper
// pill background below possible at all.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

PlasmaCore.Dialog {
    id: toast

    readonly property Theme theme: Theme {}
    property string iconSource: ""

    type: PlasmaCore.Dialog.OnScreenDisplay
    flags: Qt.ToolTip
    backgroundHints: PlasmaCore.Dialog.NoBackground
    hideOnWindowDeactivate: false

    function show(text) {
        label.text = text;
        dismissTimer.restart();
        toast.visible = true;
    }

    // Nested inside mainItem's Rectangle, not a direct child of the Dialog
    // itself - Dialog's default property (mainItem) is a single QQuickItem*,
    // not a list, so a second bare child here would also be implicitly
    // assigned to it, colliding with the explicit Rectangle below (confirmed
    // live: plasmashell's own error log was explicit about this - "Cannot
    // assign object of type Timer to property of type QQuickItem*" - once
    // the Timer lived at this level instead).
    mainItem: Rectangle {
        implicitWidth: row.implicitWidth + 28
        implicitHeight: row.implicitHeight + 18
        radius: toast.theme.radiusMd
        color: toast.theme.surface
        border.color: toast.theme.copperDim
        border.width: 1

        Timer {
            id: dismissTimer
            interval: 1800
            onTriggered: toast.visible = false
        }

        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: 10

            Kirigami.Icon {
                source: toast.iconSource
                isMask: false
                Layout.preferredWidth: 22
                Layout.preferredHeight: 22
            }

            Label {
                id: label
                font.family: toast.theme.fontMono
                font.weight: Font.Medium
                font.pixelSize: 16
                color: toast.theme.copperBright
            }
        }
    }
}
