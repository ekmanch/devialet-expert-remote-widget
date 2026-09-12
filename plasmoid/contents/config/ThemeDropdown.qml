// Phase 10.1.1: the mockup's `.theme-dropdown` (v16 mockup:
// design/mockups/settings_window/devialet_config_dialog_mockup_v16_chime_source.html,
// DOM lines 509-520, CSS lines 259-283) - the "Choose theme" variant's
// picker of installed sound themes.
//
// Built on QtQuick.Controls.Popup, the settled overlay-list pattern
// (CLAUDE.md "Flyout overlay lists are QtQuick.Controls.Popup, not
// ComboBox"; SourceListOverlay.qml / AmpListOverlay.qml): the list is a
// Popup parented to this field, content a synchronous ColumnLayout +
// Repeater so its size is known before open(), opened/closed
// imperatively (`visible` is never bound), dismissed by Escape or a press
// outside the field via closePolicy. Not a QQC2 ComboBox - its
// qqc2-desktop-style popup is a QStyle-drawn Menu that cannot be restyled
// to this look (the same reason the flyout's source picker left ComboBox
// in Phase 7.14.0).
//
// Inputs: `themes` ([{id, name, path}] - the caller's enumeration, id =
// the sound-theme directory name, name = its display name) and
// `currentId`. Output: `themeChosen(id)` - the caller stores it, this
// component holds no selection state of its own (same stateless shape as
// DbStepper.qml). The visible label is the display name of `currentId`,
// falling back to the raw id when it isn't in `themes` - the same
// fallback KDE's own Sound Theme KCM applies in KCMSoundTheme::nameFor()
// (plasma-workspace kcms/soundtheme/kcm_soundtheme.cpp:113-120).
//
// Approximation, flagged: the mockup's `.theme-dropdown-list` box-shadow
// is not drawn (same call AmpListOverlay.qml made for its dot glow).
// Corner radii: field 7px -> theme.radiusSm (DbStepper.qml precedent),
// list 8px = radiusSm exactly, rows 6px as in the mockup.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Shapes
import "../ui" as Ui

Rectangle {
    id: root

    property var themes: []
    property string currentId: ""

    signal themeChosen(string id)

    readonly property Ui.Theme theme: Ui.Theme {}
    readonly property bool open: list.opened

    function nameFor(id) {
        for (let i = 0; i < root.themes.length; i++) {
            if (root.themes[i].id === id) return root.themes[i].name;
        }
        return id;
    }

    function close() {
        list.close();
    }

    // `.theme-dropdown-field`: min-width 150, padding 6px 8px 6px 12px.
    implicitWidth: Math.max(150, fieldRow.implicitWidth + 12 + 8)
    implicitHeight: fieldRow.implicitHeight + 12
    radius: root.theme.radiusSm
    color: root.theme.surface
    border.width: 1
    border.color: fieldArea.containsMouse ? root.theme.copperDim : root.theme.divider

    RowLayout {
        id: fieldRow
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 8
        spacing: 8

        Label {
            Layout.fillWidth: true
            text: root.nameFor(root.currentId)
            font.family: root.theme.fontMono
            font.pixelSize: 11
            color: root.theme.text
            elide: Text.ElideRight
        }

        // `.chev`: 12px chevron, textFaint, rotates 180deg and turns
        // copperBright while open (mockup line 512: stroke-width 2.4,
        // path "M6 9l6 6 6-6").
        Shape {
            id: chev
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 24
            Layout.preferredHeight: 24
            scale: 12 / 24
            rotation: root.open ? 180 : 0
            Behavior on rotation { NumberAnimation { duration: 150 } }
            ShapePath {
                strokeWidth: 2.4
                strokeColor: root.open ? root.theme.copperBright : root.theme.textFaint
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M6 9l6 6 6-6" }
            }
        }
    }

    MouseArea {
        id: fieldArea
        anchors.fill: parent
        hoverEnabled: true
        // Mockup toggleThemeDropdown(): a click on the field toggles.
        onClicked: {
            if (list.opened) list.close();
            else list.open();
        }
    }

    // `.theme-dropdown-list`: top: calc(100% + 4px); right: 0;
    // min-width: 100%; surface-2, divider border, radius 8, padding 4.
    Popup {
        id: list
        parent: root
        y: root.height + 4
        x: root.width - width
        width: Math.max(root.width, listColumn.implicitWidth + leftPadding + rightPadding)
        padding: 4
        // focus:true is what makes CloseOnEscape actually work - a Popup
        // only receives the key if it took focus on open (same as
        // AmpListOverlay/SourceListOverlay; found by the Phase 10.1.1
        // driver run, where Escape left the list open without it).
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

        background: Rectangle {
            radius: root.theme.radiusSm
            color: root.theme.surface2
            border.width: 1
            border.color: root.theme.divider
        }

        contentItem: ColumnLayout {
            id: listColumn
            spacing: 0

            Repeater {
                model: root.themes

                // `.theme-dropdown-item`: padding 6px 8px, radius 6, mono
                // 11px textDim, hover surface3, selected copperBright with
                // a 12px-wide check that is otherwise invisible.
                Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool selected: row.modelData.id === root.currentId

                    Layout.fillWidth: true
                    implicitWidth: rowContent.implicitWidth + 16
                    implicitHeight: rowContent.implicitHeight + 12
                    radius: 6
                    color: rowArea.containsMouse ? root.theme.surface3 : "transparent"

                    RowLayout {
                        id: rowContent
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        spacing: 8

                        Label {
                            Layout.preferredWidth: 12
                            text: "✓"
                            font.pixelSize: 10
                            color: root.theme.copperBright
                            opacity: row.selected ? 1.0 : 0.0
                        }

                        Label {
                            Layout.fillWidth: true
                            text: row.modelData.name
                            font.family: root.theme.fontMono
                            font.pixelSize: 11
                            color: row.selected ? root.theme.copperBright : root.theme.textDim
                            wrapMode: Text.NoWrap
                        }
                    }

                    MouseArea {
                        id: rowArea
                        anchors.fill: parent
                        hoverEnabled: true
                        // Mockup selectTheme(): report, then close.
                        onClicked: {
                            root.themeChosen(row.modelData.id);
                            list.close();
                        }
                    }
                }
            }
        }
    }
}
