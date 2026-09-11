// Phase 10.1.1: the mockup's `.file-picker-btn` (v16 mockup:
// design/mockups/settings_window/devialet_config_dialog_mockup_v16_chime_source.html,
// CSS lines 230-237) - a 28x28 icon button used four times in the Volume
// Feedback section: three Preview (play) buttons, one per chime-source
// variant, plus the Browse (folder) button in the custom-file variant.
//
// Same hand-drawn Rectangle + MouseArea shape as ConfigGeneral.qml's own
// Forget/Defaults buttons (surface fill, divider border that turns
// copperDim on hover), not a QQC2 Button - the qqc2-desktop-style look
// doesn't match this page, same reasoning as every other custom control
// here. Corner radius: the mockup says 7px; rendered as theme.radiusSm
// (8) following DbStepper.qml's precedent of using radiusSm where its
// mockup also said 7px, rather than adding a one-off constant.
//
// Glyphs are the mockup's own SVG path data, verbatim, drawn with
// QtQuick.Shapes' PathSvg (precedent: ActionRow.qml's power spinner) -
// no icon asset files, no Kirigami.Icon recolor uncertainty. The paths
// are authored in the mockup's 24-unit viewBox and the Shape is scaled to
// the mockup's 14px rendering size (`.file-picker-btn svg{width:14px}`).
//
// `playing` reproduces the mockup's handlePlayChime() pulse (`.playing`
// for 350 ms: copper 0.18 fill + a 3px copperBright 0.18 ring) - purely a
// click acknowledgement; the actual sound is the caller's job (it fires
// `clicked`).
import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import "../ui" as Ui

Item {
    id: root

    // "play" (filled triangle, copper at rest) or "browse" (folder outline,
    // dim at rest, copper on hover) - the mockup's `.play` modifier class.
    property string kind: "play"
    property string tooltip: ""
    property bool playing: false

    signal clicked()

    readonly property Ui.Theme theme: Ui.Theme {}
    readonly property bool isPlay: root.kind === "play"
    readonly property bool hot: root.isPlay || area.containsMouse

    implicitWidth: 28
    implicitHeight: 28
    // Same disabled dim as DbStepper.qml's boundary buttons - the only
    // signal that Preview has nothing to play yet (no file picked, or no
    // theme with an audio-volume-change.oga found).
    opacity: enabled ? 1.0 : 0.4

    // `.playing` box-shadow ring: 3px outside the button's own edge.
    Rectangle {
        anchors.fill: parent
        anchors.margins: -3
        radius: root.theme.radiusSm + 3
        color: Qt.rgba(root.theme.copperBright.r, root.theme.copperBright.g, root.theme.copperBright.b, 0.18)
        visible: root.playing
    }

    Rectangle {
        anchors.fill: parent
        radius: root.theme.radiusSm
        color: root.playing
            ? Qt.rgba(root.theme.copper.r, root.theme.copper.g, root.theme.copper.b, 0.18)
            : root.theme.surface
        border.width: 1
        border.color: root.hot ? root.theme.copperDim : root.theme.divider

        Shape {
            id: glyph
            anchors.centerIn: parent
            width: 24
            height: 24
            scale: 14 / 24
            readonly property color tint: root.hot ? root.theme.copperBright : root.theme.textDim

            // Mockup line 501/522/536: <path d="M8 6.5v11l9-5.5-9-5.5z"/>
            // (fill="currentColor", stroke="none").
            ShapePath {
                strokeWidth: 0
                strokeColor: "transparent"
                fillColor: root.isPlay ? glyph.tint : "transparent"
                PathSvg { path: "M8 6.5v11l9-5.5-9-5.5z" }
            }

            // Mockup line 533: the folder outline (fill="none",
            // stroke="currentColor", stroke-width="2", round cap/join).
            ShapePath {
                strokeWidth: 2
                strokeColor: root.isPlay ? "transparent" : glyph.tint
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z" }
            }
        }
    }

    Timer {
        id: pulse
        interval: 350
        onTriggered: root.playing = false
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (root.isPlay) {
                root.playing = true;
                pulse.restart();
            }
            root.clicked();
        }
    }

    ToolTip.text: root.tooltip
    ToolTip.visible: root.tooltip !== "" && area.containsMouse
    ToolTip.delay: 500
}
