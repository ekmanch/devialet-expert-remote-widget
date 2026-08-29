// Phase 4.4.1: reusable copper pill switch, matching the mockup's
// .kcm-switch exactly (36x21 pill, surface3/divider when off, copperDim
// when on; 16x16 thumb sliding via translateX(15) and recoloring
// #e8e6e1 -> copperBright). Not a QQC2 Switch - its default style doesn't
// match this custom look, same reasoning as every other custom-drawn
// control in this project (mute/power buttons, volume slider).
//
// No-op this phase: `checked` just toggles on click, nothing is
// persisted or wired to real behavior - each real setting gets its own
// wiring phase later (4.4.2-4.4.7).
import QtQuick
import "../ui" as Ui

Item {
    id: root

    property bool checked: false
    readonly property Ui.Theme theme: Ui.Theme {}

    implicitWidth: 36
    implicitHeight: 21

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
        onClicked: root.checked = !root.checked
    }
}
