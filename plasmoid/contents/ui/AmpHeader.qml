// Phase 7.3.0 (spike/flyout-appletpopup-rebuild) - the amp header row,
// extracted from FullRepresentation.qml:818-921 into its own in-flow
// component for the FlyoutPopup rebuild. Stays in mainColumn (unlike the
// amp list, which moved into AmpListOverlay.qml per option (b) - see
// TODO.md's Phase 7.3.0 entry and the plan it cites). Visuals unchanged
// from the original header.
//
// Findings applied here (investigation document §4 / the flyout-rebuild
// house rules in CLAUDE.md):
//  - Finding 3: every Label pins `wrapMode: Text.NoWrap` +
//    `maximumLineCount: 1` explicitly, instead of relying on the old
//    implicit "no wrap because nothing wraps yet" safety.
//  - §4 point 2 / the Qt.AlignBaseline house rule: the row's height is a
//    measured literal (not `ampHeaderRow.implicitHeight + <pad>`), and
//    every row child is Qt.AlignVCenter - no Qt.AlignBaseline anywhere -
//    so a font/content change in one label can never move a sibling.
//
// Owns its own 1px bottom divider (the mockup's `.amp-header
// border-bottom`, devialet_tray_boot_state_mockup.html), so mainColumn
// sees a single fixed-height item for the whole header.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

Rectangle {
    id: ampHeaderBg
    objectName: "ampHeader"

    required property Theme theme
    required property string ampIp
    required property string headerName
    required property string headerSub
    required property bool online
    required property bool power
    required property string powerState
    required property bool listOpen

    signal toggleRequested()

    // Measured, not bound: ampHeaderRow's implicit height is a constant 46
    // across every amp state (three single-line labels, tallest run at
    // 14px display + 11px mono + 10px mono eyebrow with 2px spacing;
    // confirmed via the harness dump across amp=0known/1auto/2sel before
    // pinning - see TODO.md's Phase 7.3.0 verification). 46 + 26 padding =
    // 72, matching the original `ampHeaderRow.implicitHeight + 26`. Pinned
    // so no future label font/content change can alter the header's
    // contribution to mainColumn's height.
    readonly property int rowHeight: 46
    Layout.fillWidth: true
    implicitHeight: ampHeaderBg.rowHeight + 26
    color: ampHeaderArea.containsMouse ? Qt.rgba(1, 1, 1, 0.02) : "transparent"

    RowLayout {
        id: ampHeaderRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 16
        anchors.rightMargin: 40
        spacing: 10

        Rectangle {
            id: ampDot
            objectName: "ampDot"
            Layout.alignment: Qt.AlignVCenter
            width: 8
            height: 8
            radius: 4
            color: ampHeaderBg.ampIp === "" ? "transparent" : (ampHeaderBg.powerState === "Booting" ? ampHeaderBg.theme.warningBright : (ampHeaderBg.online ? ampHeaderBg.theme.copperBright : ampHeaderBg.theme.textFaint))
            border.width: ampHeaderBg.ampIp === "" ? 1.5 : 0
            border.color: ampHeaderBg.theme.textFaint
            property real pulseOpacity: 1.0
            opacity: ampHeaderBg.powerState === "Booting" ? ampDot.pulseOpacity : (ampHeaderBg.online && !ampHeaderBg.power ? 0.3 : 1.0)
            SequentialAnimation on pulseOpacity {
                running: ampHeaderBg.powerState === "Booting"
                loops: Animation.Infinite
                NumberAnimation { from: 1.0; to: 0.35; duration: 550; easing.type: Easing.InOutQuad }
                NumberAnimation { from: 0.35; to: 1.0; duration: 550; easing.type: Easing.InOutQuad }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Label {
                objectName: "ampEyebrow"
                Layout.fillWidth: true
                text: "DEVIALET"
                font.family: ampHeaderBg.theme.fontMono
                font.pixelSize: 10
                font.letterSpacing: 1.2
                color: ampHeaderBg.theme.textFaint
                wrapMode: Text.NoWrap
                maximumLineCount: 1
                elide: Text.ElideRight
            }

            Label {
                objectName: "ampName"
                Layout.fillWidth: true
                text: ampHeaderBg.headerName
                font.family: ampHeaderBg.theme.fontDisplay
                font.weight: Font.DemiBold
                font.pixelSize: 14
                color: ampHeaderBg.theme.text
                wrapMode: Text.NoWrap
                maximumLineCount: 1
                elide: Text.ElideRight
            }

            Label {
                objectName: "ampSub"
                Layout.fillWidth: true
                text: ampHeaderBg.headerSub
                font.family: ampHeaderBg.theme.fontMono
                font.pixelSize: 11
                color: ampHeaderBg.theme.textFaint
                wrapMode: Text.NoWrap
                maximumLineCount: 1
                elide: Text.ElideRight
            }
        }

        Label {
            id: ampCaret
            objectName: "ampCaret"
            Layout.alignment: Qt.AlignVCenter
            text: "⌄"
            font.pixelSize: 11
            color: ampHeaderBg.listOpen ? ampHeaderBg.theme.copperBright : ampHeaderBg.theme.textFaint
            rotation: ampHeaderBg.listOpen ? 180 : 0
            Behavior on rotation { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        }
    }

    // The header's own bottom edge (mockup's `.amp-header border-bottom`),
    // always visible - not a mainColumn sibling divider.
    Rectangle {
        objectName: "ampHeaderDivider"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: ampHeaderBg.theme.divider
    }

    MouseArea {
        id: ampHeaderArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ampHeaderBg.toggleRequested()
    }
}
