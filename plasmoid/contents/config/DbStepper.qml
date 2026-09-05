// Phase 8.0.0: numeric dB +/- stepper for the Volume Limits / startup-volume
// settings rows, matching the mockup's .db-stepper (v13 mockup:
// design/mockups/settings_window/devialet_config_dialog_mockup_v13_single_tab.html).
//
// Hold-to-repeat reuses QtQuick.Controls.Button's own `autoRepeat` (delay/
// interval below) rather than reimplementing hold-to-repeat with JS
// setTimeout/setInterval the way the static mockup's demo script does -
// the mockup is a non-interactive HTML page with no Qt to call into, so it
// had to hand-roll its own timers; this component doesn't need to. Delay/
// interval values (300ms/100ms) and the button's own visual shape
// (26x26, surface/divider, copperDim hover border) are copied from
// VolumeBlock.qml's volumeDownButton/volumeUpButton - the flyout's real
// volume +/- buttons - per CLAUDE.md's ask to match that cadence exactly
// rather than the mockup's own placeholder 400ms/100ms JS constants.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import "../ui" as Ui

RowLayout {
    id: root

    property real value: 0
    property real from: -96
    property real to: 0
    property real stepDb: 1

    // Emitted on every step (button click/autoRepeat tick) with the new,
    // already-clamped value - caller is responsible for storing it (e.g.
    // into a cfg_* property), matching this file's stateless-control shape.
    signal stepped(real value)

    readonly property Ui.Theme theme: Ui.Theme {}

    spacing: 8

    function clamp(v) {
        return Math.max(root.from, Math.min(root.to, v));
    }

    Button {
        text: "−"
        enabled: root.value > root.from
        autoRepeat: true
        autoRepeatDelay: 300
        autoRepeatInterval: 100
        onClicked: root.stepped(root.clamp(root.value - root.stepDb))

        implicitWidth: 26
        implicitHeight: 26
        background: Rectangle {
            radius: root.theme.radiusSm
            color: root.theme.surface
            border.width: 1
            border.color: parent.hovered ? root.theme.copperDim : root.theme.divider
        }
        contentItem: Label {
            text: parent.text
            font.family: root.theme.fontDisplay
            font.weight: Font.DemiBold
            font.pixelSize: 14
            color: parent.hovered ? root.theme.copperBright : root.theme.text
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    Rectangle {
        radius: root.theme.radiusSm
        color: root.theme.surface
        border.width: 1
        border.color: root.theme.divider
        implicitWidth: valueLabel.implicitWidth + 20
        implicitHeight: 26

        Label {
            id: valueLabel
            anchors.centerIn: parent
            text: Math.round(root.value) + " dB"
            font.family: root.theme.fontMono
            font.pixelSize: 12
            color: root.theme.copperBright
            wrapMode: Text.NoWrap
        }
    }

    Button {
        text: "+"
        enabled: root.value < root.to
        autoRepeat: true
        autoRepeatDelay: 300
        autoRepeatInterval: 100
        onClicked: root.stepped(root.clamp(root.value + root.stepDb))

        implicitWidth: 26
        implicitHeight: 26
        background: Rectangle {
            radius: root.theme.radiusSm
            color: root.theme.surface
            border.width: 1
            border.color: parent.hovered ? root.theme.copperDim : root.theme.divider
        }
        contentItem: Label {
            text: parent.text
            font.family: root.theme.fontDisplay
            font.weight: Font.DemiBold
            font.pixelSize: 14
            color: parent.hovered ? root.theme.copperBright : root.theme.text
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }
}
