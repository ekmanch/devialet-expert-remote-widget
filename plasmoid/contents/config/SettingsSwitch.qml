// Phase 4.4.1: reusable copper pill switch, matching the mockup's
// .kcm-switch exactly (36x21 pill, surface3/divider when off, copperDim
// when on; 16x16 thumb sliding via translateX(15) and recoloring
// #e8e6e1 -> copperBright). Not a QQC2 Switch - its default style doesn't
// match this custom look, same reasoning as every other custom-drawn
// control in this project (mute/power buttons, volume slider).
//
// Phase 10.1.2: stateless, like DbStepper.qml - a click emits
// `toggled(newValue)` and the caller stores it (`checked: root.cfg_x;
// onToggled: (c) => root.cfg_x = c`). It used to write `checked =
// !checked` itself, which is an imperative assignment and therefore
// silently *broke* the caller's `checked: root.cfg_x` binding on the
// first click: from then on a write to cfg_x from anywhere else (the
// Defaults button, the shell pushing a stored value in) changed the
// value but not the switch. Found by the Phase 10.1.2 driver run on the
// chime toggle (Defaults reset cfg_chimeEnabled to true, switch stayed
// off); the Transparency toggle had the same latent defect since 9.1.0.
//
// Phase 11.0.0: a disabled look (opacity 0.4, ChimeIconButton.qml's own
// value) for the Launch at login switch while systemd is being queried
// or reports a state the toggle can't act on. Item.enabled already
// propagates to the MouseArea, so a disabled switch ignores clicks
// without any extra guard.
import QtQuick
import "../ui" as Ui

Item {
    id: root

    property bool checked: false
    signal toggled(bool checked)
    readonly property Ui.Theme theme: Ui.Theme {}

    implicitWidth: 36
    implicitHeight: 21
    opacity: enabled ? 1.0 : 0.4

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? root.theme.copperDim : root.theme.surface3
        border.width: 1
        border.color: root.theme.divider
        Behavior on color { ColorAnimation { duration: 180 } }
    }

    Rectangle {
        width: 16
        height: 16
        radius: 8
        y: 1.5
        x: root.checked ? root.width - width - 1.5 : 1.5
        color: root.checked ? root.theme.copperBright : "#e8e6e1"
        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 180 } }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled(!root.checked)
    }
}
