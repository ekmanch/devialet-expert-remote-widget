// Phase 7.5.0 (spike/flyout-appletpopup-rebuild) - the action row
// (mute/power buttons), extracted from FullRepresentation.qml's action
// GridLayout (~1483-1662) into its own self-contained component for the
// FlyoutPopup rebuild, following the AmpHeader.qml/AmpListOverlay.qml/
// VolumeBlock.qml precedent set in Phase 7.3.0/7.4.0. Replaces the next
// chunk of FlyoutContent.qml's `sectionsPlaceholder` spacer - see TODO.md's
// Phase 7.5.0 entry and the plan it cites
// (docs/context-on-spike-flyout-dialog-rebuild-b-quirky-wand.md, §4).
//
// §4 point 2 applied here (task item 2): `powerContentRow` (the RowLayout
// swapping a static Kirigami.Icon for an animated spinner depending on
// `powerState`) gets an explicit `Qt.AlignVCenter` on every child +
// a measured `Layout.preferredHeight` - deliberate policy for this
// rebuild, applied even though the investigation doc's own finding 8-
// adjacent read of this row called it "low-risk today" (both the icon and
// the spinner are already fixed 13x13 `implicitWidth`/`implicitHeight`
// literals, and RowLayout's default per-child alignment has no cross-
// sibling baseline-style contamination the way `Qt.AlignBaseline` does -
// see CLAUDE.md's house rule for why that specific mechanism is what
// makes AlignBaseline dangerous and AlignVCenter safe by construction).
// Height measured via the §5 harness dump across off/Booting/on (see
// TODO.md's Phase 7.5.0 entry) rather than assumed equal just because the
// icon/spinner are both 13x13 - the Label's own text also changes
// ("Power On"/"Power Off"/"Powering on…") so the row's implicit height is
// verified, not asserted.
//
// `muteContentRow` (the mute button's icon+label) gets the identical
// treatment for consistency, even though task item 2 named only the power
// button's icon/spinner swap by name - its Label text is the same
// mute-state-dependent-child class §4 point 2 warns about ("Mute" vs
// "Unmute"), and the fix is free to apply everywhere at once rather than
// waiting for a future phase to notice the gap.
//
// Architecture: pure signal-up, no direct D-Bus/exec calls here - matches
// AmpHeader.qml (toggleRequested), AmpListOverlay.qml (ampChosen), and
// VolumeBlock.qml (stepRequested/sliderReleased). FlyoutContent owns the
// actual devialet-ctl invocation, BeginPowerOnBoot call, and
// pendingAmpState.notifyMute() call in response to
// muteToggleRequested/powerToggleRequested below.
//
// `muted` is fed in from FlyoutContent's `root.pendingAmpState.muted`
// (Phase 5's shared, daemon-resolved value, same architecture VolumeBlock
// already established for volumeDb - task item 3) - not a new local
// mirror. `power`/`powerState` are fed from FlyoutContent's own existing
// D-Bus mirror (established in 7.3.0 for the header's dot color/sub-text)
// - PendingAmpState deliberately does not cover Power/PowerState (see its
// own header comment: "only AmpIp/VolumeDb/Muted are ever processed"), so
// FlyoutContent's root gains its own optimistic-set + 400ms debounce
// guard for Power/PowerState this phase, ported from
// FullRepresentation.qml's `lastPowerChangeAtMs`/`within()` - this one
// genuinely still needs client-side debounce, unlike volume/mute, because
// no daemon-owned pending-command state exists for it (Phase 5.0.0 was
// scoped to VolumeDb/Muted only).

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Shapes
import org.kde.kirigami as Kirigami

GridLayout {
    id: actionRow
    objectName: "actionRow"

    required property Theme theme
    required property string ampIp
    required property bool muted
    required property bool power
    // "Off" | "Booting" | "On"
    required property string powerState

    signal muteToggleRequested()
    signal powerToggleRequested()

    Layout.fillWidth: true
    Layout.topMargin: 14
    Layout.bottomMargin: 4
    Layout.leftMargin: 16
    Layout.rightMargin: 16
    columns: 2
    columnSpacing: 8
    rowSpacing: 8
    // Same whole-group dim as the header/volume block above (Android's
    // setGroupEnabled(actionRow, connected)).
    opacity: actionRow.ampIp === "" ? 0.4 : 1.0

    Button {
        id: muteButton
        objectName: "muteButton"
        Layout.fillWidth: true
        Layout.preferredHeight: 38
        enabled: actionRow.ampIp !== ""
        onClicked: actionRow.muteToggleRequested()

        background: Rectangle {
            radius: actionRow.theme.radiusMd
            color: actionRow.muted ? Qt.rgba(actionRow.theme.copper.r, actionRow.theme.copper.g, actionRow.theme.copper.b, 0.14) : actionRow.theme.surface
            border.width: 1
            border.color: actionRow.muted ? actionRow.theme.copperDim : (parent.hovered ? actionRow.theme.copperDim : actionRow.theme.divider)
        }
        contentItem: RowLayout {
            id: muteContentRow
            objectName: "muteContentRow"
            spacing: 6
            // See this file's header comment - extended §4 point 2
            // treatment, measured via the harness dump across mute
            // on/off: a constant implicitHeight of 14 (see TODO.md's
            // Phase 7.5.0 entry). Note this pin is honestly decorative
            // here, not load-bearing the way VolumeBlock.qml's
            // `dbValueRow` pin is: `contentItem` is sized by the Button
            // control itself (fills the full 38px button height, per
            // QQC2's own contentItem geometry management, confirmed by
            // the harness dump's own h:38 vs ih:14), not read via
            // QtQuick.Layouts' attached properties the way a real nested
            // Layout-in-Layout row is - kept anyway per this rebuild's
            // blanket policy, and harmless.
            Layout.preferredHeight: 14

            Item { Layout.fillWidth: true }
            Kirigami.Icon {
                id: muteIcon
                objectName: "muteIcon"
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 13
                implicitHeight: 13
                source: "audio-volume-muted-symbolic"
                color: actionRow.muted ? actionRow.theme.copperBright : actionRow.theme.text
            }
            Label {
                id: muteLabel
                objectName: "muteLabel"
                Layout.alignment: Qt.AlignVCenter
                text: actionRow.muted ? "Unmute" : "Mute"
                font.pixelSize: 12
                font.weight: Font.DemiBold
                color: actionRow.muted ? actionRow.theme.copperBright : actionRow.theme.text
                wrapMode: Text.NoWrap
            }
            Item { Layout.fillWidth: true }
        }
    }

    Button {
        id: powerButton
        objectName: "powerButton"
        Layout.fillWidth: true
        Layout.preferredHeight: 38
        // Genuinely inert during boot, not just visually dimmed -
        // `enabled: false` on a QQC2 Button blocks mouse/keyboard event
        // delivery outright, matching the mockup's `pointer-events:none`
        // for .state-booting - the primary defense against click-spam
        // (the daemon's own BeginPowerOnBoot no-op guard is
        // defense-in-depth, not a substitute for this).
        enabled: actionRow.ampIp !== "" && actionRow.powerState !== "Booting"
        onClicked: actionRow.powerToggleRequested()

        background: Rectangle {
            radius: actionRow.theme.radiusMd
            color: actionRow.theme.surface
            border.width: 1
            // Booting takes priority over the hover colors below it,
            // which stay completely untouched - the mockup's
            // .state-booting rule isn't a :hover variant, it applies
            // unconditionally while booting.
            border.color: actionRow.powerState === "Booting"
                ? actionRow.theme.warning
                : (powerButton.hovered ? (actionRow.power ? actionRow.theme.danger : actionRow.theme.success) : actionRow.theme.divider)
        }
        contentItem: RowLayout {
            id: powerContentRow
            objectName: "powerContentRow"
            spacing: 6
            // §4 point 2 fix (task item 2) - see this file's header
            // comment. Measured via the harness dump across
            // off/Booting/on: a constant implicitHeight of 14 across all
            // three (see TODO.md's Phase 7.5.0 entry) - both the icon and
            // the spinner are fixed 13x13 literals and the Label's font
            // never swaps, only its text. Same "decorative, not
            // load-bearing" caveat as muteContentRow's own pin above
            // (contentItem is Button-sized, not Layout-sized) - kept per
            // this rebuild's blanket policy regardless.
            Layout.preferredHeight: 14

            Item { Layout.fillWidth: true }

            Kirigami.Icon {
                id: powerIcon
                objectName: "powerIcon"
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 13
                implicitHeight: 13
                source: "system-shutdown-symbolic"
                color: powerButton.hovered ? (actionRow.power ? actionRow.theme.danger : actionRow.theme.successBright) : actionRow.theme.text
                visible: actionRow.powerState !== "Booting"
            }

            // Literal port of the mockup's .spinner (a static dim ring
            // plus a rotating bright ~90° arc, via QtQuick.Shapes'
            // PathAngleArc - not a theme-dependent shape, just self-drawn
            // geometry, so none of the corner-radius Known Issue's
            // Darkly-matching concerns apply here).
            Item {
                id: powerSpinner
                objectName: "powerSpinner"
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 13
                implicitHeight: 13
                visible: actionRow.powerState === "Booting"

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: "transparent"
                    border.width: 2
                    border.color: Qt.rgba(actionRow.theme.warningBright.r, actionRow.theme.warningBright.g, actionRow.theme.warningBright.b, 0.25)
                }

                Shape {
                    anchors.fill: parent
                    rotation: 0
                    RotationAnimation on rotation {
                        running: powerSpinner.visible
                        loops: Animation.Infinite
                        from: 0
                        to: 360
                        duration: 700
                    }
                    ShapePath {
                        strokeWidth: 2
                        strokeColor: actionRow.theme.warningBright
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        PathAngleArc {
                            centerX: powerSpinner.width / 2
                            centerY: powerSpinner.height / 2
                            radiusX: powerSpinner.width / 2 - 1
                            radiusY: powerSpinner.height / 2 - 1
                            startAngle: -90
                            sweepAngle: 90
                        }
                    }
                }
            }

            Label {
                id: powerLabel
                objectName: "powerLabel"
                Layout.alignment: Qt.AlignVCenter
                text: actionRow.powerState === "Booting" ? "Powering on…" : (actionRow.power ? "Power Off" : "Power On")
                font.pixelSize: 12
                font.weight: Font.DemiBold
                color: actionRow.powerState === "Booting"
                    ? actionRow.theme.warningBright
                    : (powerButton.hovered ? (actionRow.power ? actionRow.theme.danger : actionRow.theme.successBright) : actionRow.theme.text)
                wrapMode: Text.NoWrap
            }
            Item { Layout.fillWidth: true }
        }
    }
}
