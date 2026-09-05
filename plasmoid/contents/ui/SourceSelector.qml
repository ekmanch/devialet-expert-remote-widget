// Phase 7.6.0 (spike/flyout-appletpopup-rebuild) - the source selector,
// extracted from FullRepresentation.qml into its own self-contained
// component for the FlyoutPopup rebuild, following the AmpHeader.qml/
// AmpListOverlay.qml/VolumeBlock.qml/ActionRow.qml precedent.
//
// Phase 7.14.0 rebuild (mockup v2 `.source-row`): this is now the CLOSED
// row only - a clickable card (icon chip, "Source" eyebrow + current
// source name stacked, caret) shaped exactly like AmpHeader.qml
// (`listOpen` in, `toggleRequested()` out). The dropdown itself lives in
// SourceListOverlay.qml, a QtQuick.Controls Popup that FlyoutContent
// parents to this row via `rowItem` - the same owner-driven
// open()/close() contract AmpHeader + AmpListOverlay use. The
// PlasmaComponents3.ComboBox this file was built on through 7.13.0 is
// gone; see SourceListOverlay.qml's header for why (and for what the
// old QTBUG-66446 justification actually covered).
//
// The "SOURCE" eyebrow that used to sit above the ComboBox as its own
// Label now sits inside the row next to the chip (mockup `.source-label`
// > `.source-eyebrow`), so this component's contribution to mainColumn
// is one pinned-height row plus its margins.
//
// Placeholder form: "No source" (ported verbatim from the Android app's
// `no_source_label`), shown when no amp is connected. The name label is
// fillWidth + ElideRight inside a row whose width is fixed by
// Layout.fillWidth, so "No source" <-> a real name (up to the protocol's
// 16-char slot maximum) can't nudge the chip (fixed 24x24, first) or the
// caret (last, AlignVCenter) - Phase 7.6.0's containment argument,
// unchanged in substance.
//
// House rule (CLAUDE.md, Qt.AlignBaseline): every row child is
// AlignVCenter and the row's height is a pinned literal measured live
// across every name state - see `rowHeight` below.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

ColumnLayout {
    id: sourceSelector
    objectName: "sourceSelector"

    required property Theme theme
    required property string ampIp
    // Raw array of {name, index, enabled, selected} objects - see
    // FlyoutContent's `unwrapSources()`/`fetchSourcesFresh()` for how
    // this stays fresh (Sources is array-of-struct, same "don't trust the
    // PropertiesChanged delta, re-fetch on signal" treatment as
    // KnownAmps).
    required property var sources
    required property int activeSourceIndex
    required property string activeSourceName
    // Owner-driven open state (FlyoutContent.sourceListOpen) - drives the
    // caret only; the Popup itself is opened/closed by the owner.
    required property bool listOpen

    signal toggleRequested()

    // Filtered here (this component owns the source model), handed to
    // SourceListOverlay by the owner.
    readonly property var enabledSources: sourceSelector.sources.filter(function (s) { return s.enabled; })
    // The Popup's positioning parent - FlyoutContent sets
    // `SourceListOverlay.parent` to this.
    readonly property alias rowItem: sourceRow

    readonly property bool interactive: sourceSelector.ampIp !== "" && sourceSelector.enabledSources.length > 0

    // "No source" when nothing is selected - see header.
    readonly property string displayName: {
        if (sourceSelector.ampIp === "") return "No source";
        if (sourceSelector.activeSourceName !== "") return sourceSelector.activeSourceName;
        for (var i = 0; i < sourceSelector.enabledSources.length; i++) {
            if (sourceSelector.enabledSources[i].index === sourceSelector.activeSourceIndex) return sourceSelector.enabledSources[i].name;
        }
        return "";
    }

    Layout.fillWidth: true
    Layout.topMargin: 10
    Layout.bottomMargin: 14
    Layout.leftMargin: 16
    Layout.rightMargin: 16
    spacing: 0
    // Same whole-group dim as every block above (Android's
    // setGroupEnabled(soundControls, connected)).
    opacity: sourceSelector.ampIp === "" ? 0.4 : 1.0

    // `.source-row`: surface bg, 1px divider border (copper-dim on hover),
    // 11px radius, padding 9px 10px, gap 10.
    Rectangle {
        id: sourceRow
        objectName: "sourceRow"

        // Measured, not bound (house rule): the tallest child across
        // every name state is the two-line label stack - 14 (eyebrow) +
        // 1 spacing + 17 (name) = 32, identical for "Optical 1", the
        // 16-char "Chromecast Audio" and "No source" (harness coords
        // dump, Phase 7.14.0 smoke run 20260905-182810). 32 + 2*9 padding
        // = 50 (mockup `.source-row{padding:9px 10px}`).
        readonly property int rowHeight: 32
        Layout.fillWidth: true
        implicitHeight: sourceRow.rowHeight + 18
        radius: sourceSelector.theme.radiusMd
        color: sourceSelector.theme.surface
        border.width: 1
        border.color: sourceRowArea.containsMouse && sourceSelector.interactive ? sourceSelector.theme.copperDim : sourceSelector.theme.divider

        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 10

            // `.source-icon-sm`: 24x24, radius 7, surface-3, copper glyph.
            // Follows the ACTIVE source's glyph (owner decision - the
            // mockup's static ◉ was a JS shortcut).
            Rectangle {
                objectName: "sourceIconBadge"
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                radius: 7
                color: sourceSelector.theme.surface3
                Label {
                    anchors.centerIn: parent
                    text: sourceSelector.ampIp === "" ? "◉" : sourceSelector.theme.sourceGlyph(sourceSelector.displayName)
                    font.pixelSize: 12
                    color: sourceSelector.theme.copperBright
                }
            }

            ColumnLayout {
                id: sourceLabelStack
                Layout.alignment: Qt.AlignVCenter
                Layout.fillWidth: true
                spacing: 1

                Label {
                    objectName: "sourceEyebrow"
                    Layout.fillWidth: true
                    text: "SOURCE"
                    font.family: sourceSelector.theme.fontMono
                    font.pixelSize: 10
                    font.letterSpacing: 1
                    color: sourceSelector.theme.textFaint
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    elide: Text.ElideRight
                }

                Label {
                    objectName: "sourceRowName"
                    Layout.fillWidth: true
                    text: sourceSelector.displayName
                    font.family: sourceSelector.theme.fontDisplay
                    font.weight: Font.DemiBold
                    font.pixelSize: 13
                    color: sourceSelector.theme.text
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    elide: Text.ElideRight
                }
            }

            // `.source-caret` - rotates 180° and turns copper while open,
            // same as AmpHeader.qml's ampCaret.
            Label {
                objectName: "sourceCaret"
                Layout.alignment: Qt.AlignVCenter
                text: "⌄"
                font.pixelSize: 11
                color: sourceSelector.listOpen ? sourceSelector.theme.copperBright : sourceSelector.theme.textFaint
                rotation: sourceSelector.listOpen ? 180 : 0
                Behavior on rotation { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            }
        }

        MouseArea {
            id: sourceRowArea
            anchors.fill: parent
            hoverEnabled: true
            enabled: sourceSelector.interactive
            cursorShape: sourceSelector.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: sourceSelector.toggleRequested()
        }
    }
}
