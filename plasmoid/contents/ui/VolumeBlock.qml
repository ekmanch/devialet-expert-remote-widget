// Phase 7.4.0 (spike/flyout-appletpopup-rebuild) - the volume block (dB/
// unit readout, source chip, -/slider/+, scroll hint), extracted from
// FullRepresentation.qml's volume ColumnLayout (~1173-1480) into its own
// self-contained component for the FlyoutPopup rebuild, following the
// AmpHeader.qml/AmpListOverlay.qml precedent set in Phase 7.3.0. Replaces
// part of FlyoutContent.qml's `sectionsPlaceholder` spacer - see TODO.md's
// Phase 7.4.0 entry and the plan it cites
// (docs/context-on-spike-flyout-dialog-rebuild-b-quirky-wand.md, §4).
//
// Findings applied here:
//  - Finding 1 (dormant Qt.AlignBaseline on the dB-value/unit RowLayout,
//    investigation doc line 55): converted to Qt.AlignVCenter + a measured
//    Layout.preferredHeight on `dbValueRow`, per CLAUDE.md's house rule.
//    Neither Label's font swaps state here (unlike VolumeToast.qml's
//    valueText, which swaps between numeric-dB and "Muted"/"Unmuted"
//    forms) - only dbValueLabel's text *length* varies (numeric vs the
//    "—" placeholder) - so the row's implicit height is already constant
//    across every content state today; pinned explicitly anyway per the
//    house rule ("even though nothing currently activates it"). Value
//    measured via the §5 harness dump across the vol dimension before
//    pinning - see TODO.md's Phase 7.4.0 entry.
//  - Finding 2 (source chip, doc line 64): `sourceChip`/`sourceChipLabel`
//    gain `elide: Text.ElideRight` + `Layout.maximumWidth`, matching
//    VolumeToast.qml's own fix for the identical unbounded-width gap -
//    a long source name can no longer grow the chip past the fillWidth
//    spacer bottoming out at 0.
//  - Finding 8 (the slider, doc line 111): shape unchanged - width fully
//    determined by the two fixed 26x26 sibling buttons, implicitHeight a
//    hardcoded 26 literal, background/handle sized purely from the
//    Slider's own availableWidth/visualPosition. Re-verified clean after
//    being rebuilt alongside the rest of this file.
//  - Finding 3's convention (every dynamic Label pinned `wrapMode:
//    Text.NoWrap`, matching AmpHeader.qml) applied to every Label here too,
//    not just the ones getting `elide`.
//
// Architecture: pure signal-up, no direct D-Bus/exec calls here - matches
// AmpHeader.qml (toggleRequested) and AmpListOverlay.qml (ampChosen).
// FlyoutContent owns the actual devialet-ctl invocation and
// pendingAmpState.notifyVolume() call in response to stepRequested/
// sliderReleased below.
//
// `volumeDb` is fed in from FlyoutContent's `root.pendingAmpState.volumeDb`
// (Phase 5's shared, daemon-resolved pending-or-confirmed value) - not a
// new local mirror. This also means FullRepresentation.qml's
// lastVolumeButtonStepAtMs/lastVolumeSliderReleaseAtMs/volumeInteracting
// debounce machinery is deliberately NOT ported into this rebuild: Phase
// 5.0.2 Step B already made PendingAmpState.notifyVolume() write
// synchronously, same-tick, before firing its D-Bus call, and the daemon's
// own resolve_pending_commands() (Phase 5.0.0) already owns confirmed-vs-
// expired resolution - CompactRepresentation.qml's stepVolume()/
// toggleMute() already rely on exactly this and carry no such bookkeeping
// either. FullRepresentation.qml still carries the old machinery only
// because it's being replaced by this rebuild, not patched in place.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

ColumnLayout {
    id: volumeBlock
    objectName: "volumeBlock"

    required property Theme theme
    required property string ampIp
    // undefined | number - see header comment, fed from
    // FlyoutContent's root.pendingAmpState.volumeDb.
    required property var volumeDb
    required property real volumeFloorDb
    required property real volumeCeilingDb
    required property real volumeStepDb
    required property string activeSourceName

    // -1 / +1, one per button click/autoRepeat tick or wheel notch.
    signal stepRequested(int direction)
    // Final value on slider release - FlyoutContent sends it and calls
    // pendingAmpState.notifyVolume().
    signal sliderReleased(real value)

    Layout.fillWidth: true
    Layout.topMargin: 16
    Layout.bottomMargin: 6
    Layout.leftMargin: 16
    Layout.rightMargin: 16
    spacing: 10
    // Same whole-group dim Android's setGroupEnabled()/disabledAlpha uses
    // when nothing is selected - ported 1:1 from FullRepresentation.qml.
    opacity: volumeBlock.ampIp === "" ? 0.4 : 1.0

    RowLayout {
        id: dbSourceRow
        objectName: "dbSourceRow"
        Layout.fillWidth: true

        RowLayout {
            id: dbValueRow
            objectName: "dbValueRow"
            spacing: 0
            // Finding 1 fix - see this file's header comment. Measured
            // tallest implicit height across "0.0"/"-40.0"/"-60.0"/"—"
            // (the font never swaps in this row, only text length does) -
            // a constant 35 in every state per the §5 harness dump (see
            // TODO.md's Phase 7.4.0 entry), confirming the "already
            // constant, pin it anyway" premise this finding was flagged
            // under.
            Layout.preferredHeight: 35

            Label {
                id: dbValueLabel
                objectName: "dbValueLabel"
                Layout.alignment: Qt.AlignVCenter
                // Bound to the slider's own live value (tracks a drag
                // continuously), not volumeBlock.volumeDb directly -
                // matches FullRepresentation.qml's original Phase 3 fix
                // for the same reason (the label used to stay static
                // during a drag when bound to the external property).
                text: (volumeBlock.ampIp !== "" && volumeBlock.volumeDb !== undefined) ? volumeSlider.value.toFixed(1) : "—"
                font.family: volumeBlock.theme.fontMono
                font.weight: Font.Medium
                font.pixelSize: 26
                color: volumeBlock.theme.copperBright
                wrapMode: Text.NoWrap
            }
            Label {
                id: dbUnitLabel
                objectName: "dbUnitLabel"
                Layout.alignment: Qt.AlignVCenter
                text: "dB"
                font.pixelSize: 12
                color: volumeBlock.theme.textDim
                Layout.leftMargin: 3
                wrapMode: Text.NoWrap
            }
        }

        Item { Layout.fillWidth: true }

        Rectangle {
            id: sourceChip
            objectName: "sourceChip"
            Layout.alignment: Qt.AlignVCenter
            // Finding 2 fix: cap the chip's own width so a long source
            // name can't grow it past the fillWidth spacer above bottoming
            // out at 0 - see this file's header comment.
            Layout.maximumWidth: 140
            radius: 999
            color: volumeBlock.theme.surface
            border.width: 1
            border.color: volumeBlock.theme.divider
            implicitWidth: sourceChipLabel.implicitWidth + 18
            implicitHeight: sourceChipLabel.implicitHeight + 6

            Label {
                id: sourceChipLabel
                objectName: "sourceChipLabel"
                anchors.centerIn: parent
                width: parent.width - 18
                horizontalAlignment: Text.AlignHCenter
                text: volumeBlock.activeSourceName !== "" ? volumeBlock.activeSourceName : "—"
                font.family: volumeBlock.theme.fontMono
                font.pixelSize: 11
                color: volumeBlock.theme.textFaint
                wrapMode: Text.NoWrap
                maximumLineCount: 1
                elide: Text.ElideRight
            }
        }
    }

    RowLayout {
        id: sliderRow
        objectName: "sliderRow"
        Layout.fillWidth: true
        spacing: 10

        Button {
            id: volumeDownButton
            objectName: "volumeDownButton"
            text: "−"
            enabled: volumeBlock.ampIp !== ""
            autoRepeat: true
            autoRepeatDelay: 300
            autoRepeatInterval: 100
            onClicked: volumeBlock.stepRequested(-1)

            implicitWidth: 26
            implicitHeight: 26
            background: Rectangle {
                radius: volumeBlock.theme.radiusSm
                color: volumeBlock.theme.surface
                border.width: 1
                border.color: parent.hovered ? volumeBlock.theme.copperDim : volumeBlock.theme.divider
            }
            contentItem: Label {
                text: parent.text
                font.family: volumeBlock.theme.fontDisplay
                font.weight: Font.DemiBold
                font.pixelSize: 14
                color: parent.hovered ? volumeBlock.theme.copperBright : volumeBlock.theme.text
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }

        Slider {
            id: volumeSlider
            objectName: "volumeSlider"
            Layout.fillWidth: true
            // Widens the click/drag hit area to match the sibling -/+
            // buttons' 26px row height - see Phase 4.2.2 (finding 8 is
            // this same, already-clean shape, re-verified here).
            implicitHeight: 26
            from: volumeBlock.volumeFloorDb
            to: volumeBlock.volumeCeilingDb
            stepSize: volumeBlock.volumeStepDb
            enabled: volumeBlock.ampIp !== ""

            // External state (the daemon-resolved pending-or-confirmed
            // value) drives `value` except while actively dragging - see
            // this file's header comment for why no snap-back-risk holdout
            // is needed here (unlike FullRepresentation.qml's own Binding).
            Binding {
                target: volumeSlider
                property: "value"
                value: (volumeBlock.ampIp !== "" && volumeBlock.volumeDb !== undefined) ? volumeBlock.volumeDb : volumeBlock.volumeFloorDb
                when: !volumeSlider.pressed
            }

            onPressedChanged: {
                if (!volumeSlider.pressed) {
                    volumeBlock.sliderReleased(volumeSlider.value);
                }
            }

            background: Rectangle {
                x: volumeSlider.leftPadding
                y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                implicitHeight: 4
                width: volumeSlider.availableWidth
                height: 4
                radius: 999
                color: volumeBlock.theme.surface3

                Rectangle {
                    width: volumeSlider.visualPosition * parent.width
                    height: parent.height
                    radius: 999
                    color: volumeBlock.theme.copper
                }
            }

            handle: Rectangle {
                x: volumeSlider.leftPadding + volumeSlider.visualPosition * (volumeSlider.availableWidth - width)
                y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                width: 15
                height: 15
                radius: 999
                color: volumeBlock.theme.copperBright
            }

            // Phase 4.5.1: scroll-to-adjust-volume - see FullRepresentation
            // .qml's original for the acceptedButtons: Qt.NoButton
            // reasoning (lets press/drag pass through to the Slider
            // underneath, matches org.kde.desktop's own style technique).
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton

                // Accumulates sub-notch wheel deltas into whole 120-unit
                // "notches" before stepping - one stepRequested() call per
                // physical notch, matching org.kde.desktop's own
                // Slider.qml convention.
                property int wheelDelta: 0

                onWheel: (wheel) => {
                    // Blocked while actively dragging - the Slider's
                    // `value` binding above is suppressed until release,
                    // and release unconditionally sends the drag position.
                    if (volumeSlider.pressed) return;

                    const delta = (wheel.angleDelta.y || -wheel.angleDelta.x) * (wheel.inverted ? -1 : 1);
                    wheelDelta += delta;
                    while (wheelDelta >= 120) {
                        wheelDelta -= 120;
                        volumeBlock.stepRequested(1);
                    }
                    while (wheelDelta <= -120) {
                        wheelDelta += 120;
                        volumeBlock.stepRequested(-1);
                    }
                }
            }
        }

        Button {
            id: volumeUpButton
            objectName: "volumeUpButton"
            text: "+"
            enabled: volumeBlock.ampIp !== ""
            autoRepeat: true
            autoRepeatDelay: 300
            autoRepeatInterval: 100
            onClicked: volumeBlock.stepRequested(1)

            implicitWidth: 26
            implicitHeight: 26
            background: Rectangle {
                radius: volumeBlock.theme.radiusSm
                color: volumeBlock.theme.surface
                border.width: 1
                border.color: parent.hovered ? volumeBlock.theme.copperDim : volumeBlock.theme.divider
            }
            contentItem: Label {
                text: parent.text
                font.family: volumeBlock.theme.fontDisplay
                font.weight: Font.DemiBold
                font.pixelSize: 14
                color: parent.hovered ? volumeBlock.theme.copperBright : volumeBlock.theme.text
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
    }

    Label {
        id: scrollHint
        objectName: "scrollHint"
        Layout.fillWidth: true
        Layout.topMargin: 9
        horizontalAlignment: Text.AlignHCenter
        // Decorative only - matches FullRepresentation.qml's own text
        // (scroll-over-icon volume control is Phase 4.4's job, not this
        // file's).
        text: "Scroll over the panel icon to adjust"
        font.family: volumeBlock.theme.fontMono
        font.pixelSize: 10
        color: volumeBlock.theme.textFaint
        wrapMode: Text.NoWrap
    }
}
