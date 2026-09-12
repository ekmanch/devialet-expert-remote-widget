// Phase 4.4.1: reusable settings row, matching the mockup's .kcm-row -
// name+description on the left (max-width 440, matching the mockup),
// an arbitrary control on the right, space-between, with a bottom
// divider. The mockup's DOM is flat (every .kcm-row is a direct sibling
// under one container, not grouped per-section), and its
// `.kcm-row:last-child{border-bottom:none}` rule only strips the divider
// from the literal last row on the whole page - `showDivider` mirrors
// that (default true, set false only on the final row in ConfigGeneral.qml).
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import "../ui" as Ui

ColumnLayout {
    id: root

    property string name: ""
    property string desc: ""
    property bool showDivider: true
    // Phase 10.1.1: the mockup's per-row padding overrides (e.g. the
    // "Chime sound" row's inline `padding-top:0`, v16 mockup line 481).
    // Defaults are the .kcm-row's own 14px, so no existing row moves.
    property int topPadding: 14
    property int bottomPadding: 14
    // Phase 11.0.0: optional one-line message under the row, between the
    // name/control line and the divider - the mockup's .limit-warning
    // (v16 mockup lines 297-301: mono 10px, danger-bright, right-aligned,
    // padding 0 2px 10px, hidden unless shown). "" renders nothing, so
    // no existing row moves. First user: Launch at login's systemd
    // status/error text; Phase 11.1.0's forget-amps row may reuse it.
    property string note: ""
    property color noteColor: theme.dangerBright
    default property alias controlData: controlHolder.data

    readonly property Ui.Theme theme: Ui.Theme {}

    Layout.fillWidth: true
    spacing: 0

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: root.topPadding
        Layout.bottomMargin: root.bottomPadding
        spacing: 20

        ColumnLayout {
            Layout.maximumWidth: 440
            Layout.alignment: Qt.AlignVCenter
            spacing: 2

            Label {
                Layout.fillWidth: true
                text: root.name
                font.pixelSize: 14
                font.weight: Font.Medium
                color: root.theme.text
                wrapMode: Text.WordWrap
            }

            Label {
                Layout.fillWidth: true
                text: root.desc
                visible: root.desc !== ""
                font.pixelSize: 11
                color: root.theme.textFaint
                wrapMode: Text.WordWrap
            }
        }

        Item { Layout.fillWidth: true }

        RowLayout {
            id: controlHolder
            Layout.alignment: Qt.AlignVCenter
        }
    }

    Label {
        Layout.fillWidth: true
        Layout.rightMargin: 2
        Layout.bottomMargin: 10
        visible: root.note !== ""
        text: root.note
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignRight
        wrapMode: Text.WordWrap
        font.family: root.theme.fontMono
        font.pixelSize: 10
        color: root.noteColor
    }

    Rectangle {
        Layout.fillWidth: true
        height: 1
        visible: root.showDivider
        color: root.theme.divider
    }
}
