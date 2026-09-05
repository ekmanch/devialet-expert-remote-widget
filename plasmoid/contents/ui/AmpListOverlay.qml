// Phase 7.3.0 (spike/flyout-appletpopup-rebuild) - the amp picker list,
// pulled OUT of in-flow mainColumn (§4 point 4, option (b)) into a
// self-contained overlay so neither expand/collapse nor amp count can
// ever perturb anything below the amp header (§1 master finding). See
// TODO.md's Phase 7.3.0 entry and the plan it cites.
//
// Implemented as a QtQuick.Controls Popup, not a second PlasmaCore.Dialog:
// the Popup's content is reparented into the flyout window's own Overlay -
// no new native window, and so nothing that could trip the flyout's
// hideOnWindowDeactivate / requestActivate focus relay (investigation
// document §3's named risk). Verified live in Phase 7.3.0 (window count
// unchanged on open, flyout stays active, no setWindowState warning - see
// TODO.md). Phase 7.14.0: SourceListOverlay.qml is built on exactly this
// same shape (see its header for why the ComboBox went away).
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
//
// Phase 7.14.0 restyle (mockup v2 `.overlay-popup` / `.amp-option`): the
// list is now a floating card inset 16px from the flyout's edges (was
// flush/full-width with a bare bottom line), with the shared
// OverlayCardBackground (13px radius, border, gradient, shadow), 8px
// inner padding (`.amp-list-inner{padding:8px}`, replacing the per-row
// 10px side margins + hand-placed 8px spacers) and 9px row radius. The
// None row / divider / empty label are Android-port behaviour no mockup
// version ever drew - kept as-is (Phase 7.14.0 is visual-only). The
// connected dot's glow (`box-shadow`) is skipped, matching AmpHeader's
// own dot which never drew its glow either.

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

    // Inset card directly under the header (parent): `.overlay-popup
    // {left:16px; right:16px}` + `#ampList{top:64px}` (the header's own
    // bottom edge in the mockup).
    readonly property int inset: 16
    x: overlay.inset
    y: parent ? parent.height : 0
    width: parent ? parent.width - 2 * overlay.inset : 0
    // Finding 4: capped height with a real scroll affordance, replacing
    // the old silent clip. Popup padding is the card's inner padding
    // (`.amp-list-inner{padding:8px}`); height = content + 2*padding.
    padding: 8
    readonly property int maxListHeight: 230
    height: Math.min(listColumn.implicitHeight + 2 * overlay.padding, overlay.maxListHeight)

    modal: false
    dim: false
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

    background: OverlayCardBackground { theme: overlay.theme }

    contentItem: ScrollView {
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        ColumnLayout {
            id: listColumn
            width: overlay.availableWidth
            spacing: 2

            // ---- "None" row (Android port, verbatim) ----
            Rectangle {
                id: ampNoneOption
                objectName: "ampNoneRow"
                readonly property bool isCurrent: overlay.ampIp === ""

                Layout.fillWidth: true
                implicitHeight: ampNoneRow.implicitHeight + 16
                radius: overlay.theme.radiusOverlayRow
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
                Layout.topMargin: 4
                Layout.bottomMargin: 2
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
                    implicitHeight: ampOptionRow.implicitHeight + 16
                    radius: overlay.theme.radiusOverlayRow
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
        }
    }
}
