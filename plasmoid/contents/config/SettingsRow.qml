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
    default property alias controlData: controlHolder.data

    readonly property Ui.Theme theme: Ui.Theme {}

    Layout.fillWidth: true
    spacing: 0

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 14
        Layout.bottomMargin: 14
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

    Rectangle {
        Layout.fillWidth: true
        height: 1
        visible: root.showDivider
        color: root.theme.divider
    }
}
