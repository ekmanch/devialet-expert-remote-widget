// Phase 4.5.0: custom content for PlasmoidItem.toolTipItem - the shell's
// own native hover-tooltip dialog (same one every panel applet uses,
// confirmed via the real org.kde.plasma.volume applet's main.qml, which
// drives it with plain toolTipMainText/toolTipSubText bindings on its own
// custom MouseArea-based compact representation - the same shape this
// plasmoid's CompactRepresentation.qml already has). toolTipItem hands the
// shell's tooltip dialog a real QQuickItem instead of plain text, so the
// content below can use this plasmoid's own copper/graphite look instead
// of the theme's generic tooltip styling, while still getting the shell's
// already-solved hover positioning/timing/window management for free - no
// custom Popup/Dialog code needed here, avoiding the QQC2-outside-a-
// genuine-Window issues this project hit with popups previously.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.kirigami as Kirigami

RowLayout {
    id: root

    property string iconSource: ""
    property string ampName: ""
    property var volumeDb: undefined
    property bool hasAmp: false

    readonly property Theme theme: Theme {}

    spacing: 10
    Layout.margins: 10

    Kirigami.Icon {
        source: root.iconSource
        isMask: false
        Layout.preferredWidth: 22
        Layout.preferredHeight: 22
    }

    ColumnLayout {
        spacing: 1

        Label {
            text: root.ampName
            font.weight: Font.Medium
            font.pixelSize: 13
            color: root.theme.text
        }

        RowLayout {
            spacing: 3
            Label {
                text: (root.hasAmp && root.volumeDb !== undefined) ? root.volumeDb.toFixed(1) : "—"
                font.family: root.theme.fontMono
                font.weight: Font.Medium
                font.pixelSize: 13
                color: root.theme.copperBright
            }
            Label {
                text: "dB"
                font.pixelSize: 11
                color: root.theme.textDim
            }
        }
    }
}
