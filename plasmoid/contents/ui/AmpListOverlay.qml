// Phase 7.3.0 (spike/flyout-appletpopup-rebuild) - the amp picker list,
// pulled OUT of in-flow mainColumn (§4 point 4, option (b)) into a
// self-contained overlay so neither expand/collapse nor amp count can
// ever perturb anything below the amp header (§1 master finding). See
// TODO.md's Phase 7.3.0 entry and the plan it cites.
//
// Implemented as a QtQuick.Controls Popup, not a second PlasmaCore.Dialog:
// PlasmaComponents3.ComboBox drives its own dropdown this exact way inside
// the same AppletPopup window (/usr/lib/qt6/qml/org/kde/plasma/components/
// ComboBox.qml), so the Popup's content is reparented into the flyout
// window's own Overlay - no new native window, and so nothing that could
// trip the flyout's hideOnWindowDeactivate / requestActivate focus relay
// (investigation document §3's named risk). Verified live in Phase 7.3.0
// (window count unchanged on open, flyout stays active, no
// setWindowState warning - see TODO.md).
//
// Self-containment boundary (so reverting option (b) later is a targeted
// change to this file + one line in FlyoutContent.qml): inputs are
// `theme`, `knownAmps`, `ampIp`; outputs are the `closed` signal (Popup's
// own) and `ampChosen(ip)`. The owner never binds this Popup's `visible`
// (a closePolicy dismissal calls close() imperatively and would break
// such a binding) - it drives open()/close() and listens to `closed`,
// see FlyoutContent.qml's "Lifecycle and state sync".
//
// Content (None row, inner divider, "No amps discovered yet" label, the
// Repeater over knownAmps) is ported verbatim from
// FullRepresentation.qml:940-1167 - findings 5 (empty label), 6 (divider,
// see below) and 7 (Repeater height) all now live inside this overlay.
// Finding 4: the old silent clip-at-220 (Item{clip:true} +
// Math.min(...,220)) becomes a real ScrollView + ScrollBar; height changes
// stay inside the overlay by construction.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

Popup {
    id: overlay
    objectName: "ampListOverlay"

    required property Theme theme
    required property var knownAmps
    required property string ampIp

    signal ampChosen(string ip)

    // Flush, full-width, directly under the header (parent), exactly where
    // the inline list used to sit - the mockup's look preserved, geometry
    // out of flow.
    x: 0
    y: parent ? parent.height : 0
    width: parent ? parent.width : 0
    // Finding 4: capped height with a real scroll affordance, replacing
    // the old silent clip. 8px top/bottom inner padding (mockup's
    // `.amp-list-inner{padding:8px 10px}`; left/right handled per-row).
    padding: 0
    readonly property int maxListHeight: 220
    height: Math.min(listColumn.implicitHeight + 16, overlay.maxListHeight)

    modal: false
    dim: false
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

    // Opaque surface (the list now floats over the volume block below) with
    // a 1px bottom edge only - finding 6. The mockup's only-when-open
    // divider was `.amp-list.open{border-bottom-color:var(--divider)}`,
    // i.e. the list's own bottom edge, so it belongs here. No top border:
    // the header's own bottom divider sits directly above.
    background: Rectangle {
        color: overlay.theme.surface
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: overlay.theme.divider
        }
    }

    contentItem: ScrollView {
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        ColumnLayout {
            id: listColumn
            width: overlay.width
            spacing: 2

            // ---- "None" row (Android port, verbatim) ----
            Rectangle {
                id: ampNoneOption
                objectName: "ampNoneRow"
                readonly property bool isCurrent: overlay.ampIp === ""

                Layout.fillWidth: true
                Layout.topMargin: 8
                Layout.leftMargin: 10
                Layout.rightMargin: 10
                implicitHeight: ampNoneRow.implicitHeight + 16
                radius: overlay.theme.radiusSm
                color: ampNoneArea.containsMouse ? overlay.theme.surface2 : "transparent"

                RowLayout {
                    id: ampNoneRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: 8
                    spacing: 9

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        width: 7
                        height: 7
                        radius: 3.5
                        color: "transparent"
                        border.width: 1.5
                        border.color: ampNoneOption.isCurrent ? overlay.theme.copperBright : overlay.theme.textFaint
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        Label {
                            Layout.fillWidth: true
                            text: "None"
                            font.family: overlay.theme.fontDisplay
                            font.weight: Font.DemiBold
                            font.italic: true
                            font.pixelSize: 13
                            color: ampNoneOption.isCurrent ? overlay.theme.copperBright : overlay.theme.textDim
                            wrapMode: Text.NoWrap
                            maximumLineCount: 1
                            elide: Text.ElideRight
                        }

                        Label {
                            Layout.fillWidth: true
                            text: "Don't connect to any amplifier"
                            font.family: overlay.theme.fontMono
                            font.pixelSize: 10
                            color: overlay.theme.textFaint
                            wrapMode: Text.NoWrap
                            maximumLineCount: 1
                            elide: Text.ElideRight
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignVCenter
                        text: "✓"
                        font.pixelSize: 11
                        color: overlay.theme.copperBright
                        visible: ampNoneOption.isCurrent
                    }
                }

                MouseArea {
                    id: ampNoneArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: overlay.ampChosen("")
                }
            }

            Rectangle {
                objectName: "ampListDivider"
                Layout.fillWidth: true
                Layout.topMargin: 6
                Layout.bottomMargin: 4
                Layout.leftMargin: 4
                Layout.rightMargin: 4
                height: 1
                color: overlay.theme.divider
            }

            Label {
                objectName: "ampListEmpty"
                visible: overlay.knownAmps.length === 0
                Layout.fillWidth: true
                Layout.margins: 12
                horizontalAlignment: Text.AlignHCenter
                text: "No amps discovered yet"
                font.family: overlay.theme.fontMono
                font.pixelSize: 11
                color: overlay.theme.textFaint
            }

            Repeater {
                model: overlay.knownAmps

                delegate: Rectangle {
                    id: ampOption
                    required property var modelData
                    objectName: "ampOption:" + modelData.ip
                    readonly property bool isCurrent: overlay.ampIp !== "" && modelData.ip === overlay.ampIp
                    readonly property string displayName: modelData.modelName !== "" ? modelData.modelName : modelData.deviceName

                    Layout.fillWidth: true
                    Layout.leftMargin: 10
                    Layout.rightMargin: 10
                    implicitHeight: ampOptionRow.implicitHeight + 16
                    radius: overlay.theme.radiusSm
                    color: ampOptionArea.containsMouse ? overlay.theme.surface2 : "transparent"

                    RowLayout {
                        id: ampOptionRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: 8
                        spacing: 9

                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            width: 7
                            height: 7
                            radius: 3.5
                            color: ampOption.isCurrent ? overlay.theme.copperBright : overlay.theme.textFaint
                            opacity: ampOption.modelData.online ? 1.0 : 0.5
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1

                            Label {
                                Layout.fillWidth: true
                                text: ampOption.displayName !== "" ? ampOption.displayName : ampOption.modelData.ip
                                font.family: overlay.theme.fontDisplay
                                font.weight: Font.DemiBold
                                font.pixelSize: 13
                                color: ampOption.isCurrent ? overlay.theme.copperBright : overlay.theme.textDim
                                wrapMode: Text.NoWrap
                                maximumLineCount: 1
                                elide: Text.ElideRight
                            }

                            Label {
                                Layout.fillWidth: true
                                text: ampOption.modelData.ip
                                    + (ampOption.modelData.online ? "" : " · offline")
                                    + (ampOption.modelData.modelName !== "" ? "" : " · name unresolved")
                                font.family: overlay.theme.fontMono
                                font.pixelSize: 10
                                color: overlay.theme.textFaint
                                wrapMode: Text.NoWrap
                                maximumLineCount: 1
                                elide: Text.ElideRight
                            }
                        }

                        Label {
                            Layout.alignment: Qt.AlignVCenter
                            text: "✓"
                            font.pixelSize: 11
                            color: overlay.theme.copperBright
                            visible: ampOption.isCurrent
                        }
                    }

                    MouseArea {
                        id: ampOptionArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: overlay.ampChosen(ampOption.modelData.ip)
                    }
                }
            }

            // Bottom padding inside the scroll content (matches the
            // mockup's `.amp-list-inner` 8px bottom).
            Item { Layout.preferredHeight: 8; Layout.fillWidth: true }
        }
    }
}
