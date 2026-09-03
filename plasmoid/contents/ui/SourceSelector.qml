// Phase 7.6.0 (spike/flyout-appletpopup-rebuild) - the source selector
// (SOURCE eyebrow + ComboBox), extracted from FullRepresentation.qml's
// source ColumnLayout (~1664-1803) into its own self-contained component
// for the FlyoutPopup rebuild, following the AmpHeader.qml/
// AmpListOverlay.qml/VolumeBlock.qml/ActionRow.qml precedent set in
// 7.3.0-7.5.0. Replaces the first half of the remaining chunk of
// FlyoutContent.qml's `sectionsPlaceholder` spacer - see TODO.md's Phase
// 7.6.0 entry and the plan it cites
// (docs/context-on-spike-flyout-dialog-rebuild-b-quirky-wand.md, §4).
//
// Task item 2 (confirmed against the current file, not ported from
// memory): this uses `org.kde.plasma.components.ComboBox`
// (PlasmaComponents3), not `QtQuick.Controls`' base ComboBox - the same
// deliberate choice FullRepresentation.qml documents at length: every
// real installed plasmoid on this machine uses QQC2's base ComboBox only
// inside a separate settings/config dialog, never inside the applet's own
// popup content, and PlasmaComponents3's own ComboBox.qml carries an
// explicit source comment citing QTBUG-66446 (a QQC2 Popup's
// LayoutMirroring doesn't inherit correctly outside a genuine top-level
// Window - exactly this applet's popup content situation) as the reason
// it overrides LayoutMirroring and supplies its own popup/background
// rather than relying on QQC2's default Popup+Overlay machinery. All
// bindings/`onActivated` logic below are ported verbatim from that
// Phase 3 fix - restyled via background/contentItem/indicator only, the
// popup/delegate internals stay whatever PlasmaComponents3.ComboBox
// itself supplies (untouched, exactly as before).
//
// Task item 3 (§4 point 5 - reserve width for a label's fallback/
// placeholder form so a value transitioning to/from it can't nudge
// neighboring layout): investigated rather than assumed. The task's own
// premise ("likely the source name display... using the existing '—'
// placeholder convention") does NOT hold here, checked directly - the
// literal "—" em-dash convention only appears in VolumeBlock.qml (the dB
// value/source chip, already handled there in 7.4.0) and in
// VolumeToast.qml/VolumeHoverTooltip.qml (not part of this rebuild); this
// file's own placeholder-form label is `sourceCombo`'s `displayText`,
// whose disconnected/no-selection fallback is the string `"No source"`,
// ported verbatim from the Android app's `no_source_label`. Confirmed
// this label needs no NEW width-reservation fix: `sourceComboLabel` is
// already `Layout.fillWidth: true` + `elide: Text.ElideRight` inside a
// ComboBox whose own outer width is fixed (`Layout.fillWidth: true`
// spanning the full row, unrelated to displayText's length) - so
// "No source" <-> a real source name (up to the protocol's 16-char slot
// maximum) can never nudge the icon badge (fixed 24x24, positioned
// first) or the indicator caret (absolutely positioned off
// `sourceCombo.width`, itself content-independent) either inside or
// outside this row. This achieves §4 point 5's actual goal (no nudging
// across a placeholder<->real-value transition) via containment
// (fillWidth + elide) rather than literal fixed-width reservation - the
// same technique already proven for VolumeBlock's own dB-value row and
// source chip. Left as confirmed-safe, not modified further.
//
// Architecture: pure signal-up (`sourceChosen(index, name)`), no direct
// D-Bus/exec calls here - matches every prior section this rebuild.
// `sources` is fed in as the raw array-of-struct (mirroring
// FlyoutContent's existing `knownAmps` pattern, Phase 7.3.0's
// `fetchKnownAmpsFresh`/`unwrapKnownAmps` shape) - this component owns
// filtering it down to `enabledSources` and building the ComboBox model
// from it, matching how AmpListOverlay.qml owns its own Repeater over
// the raw `knownAmps` it's handed rather than receiving a pre-filtered
// list.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.plasma.components as PlasmaComponents3

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

    signal sourceChosen(int index, string name)

    readonly property var enabledSources: sourceSelector.sources.filter(function (s) { return s.enabled; })

    Layout.fillWidth: true
    Layout.topMargin: 10
    Layout.bottomMargin: 14
    Layout.leftMargin: 16
    Layout.rightMargin: 16
    spacing: 4
    // Same whole-group dim as every block above (Android's
    // setGroupEnabled(soundControls, connected)).
    opacity: sourceSelector.ampIp === "" ? 0.4 : 1.0

    Label {
        objectName: "sourceEyebrow"
        text: "SOURCE"
        font.family: sourceSelector.theme.fontMono
        font.pixelSize: 10
        font.letterSpacing: 1
        color: sourceSelector.theme.textFaint
        wrapMode: Text.NoWrap
    }

    PlasmaComponents3.ComboBox {
        id: sourceCombo
        objectName: "sourceCombo"
        Layout.fillWidth: true
        enabled: sourceSelector.ampIp !== "" && sourceSelector.enabledSources.length > 0
        textRole: "name"
        model: sourceSelector.enabledSources

        currentIndex: {
            for (var i = 0; i < sourceSelector.enabledSources.length; i++) {
                if (sourceSelector.enabledSources[i].index === sourceSelector.activeSourceIndex) return i;
            }
            return -1;
        }

        // "No source" when nothing is selected - see this file's header
        // comment (task item 3) for why this, not "—", is the actual
        // placeholder form here.
        displayText: sourceSelector.ampIp === "" ? "No source" : (sourceSelector.activeSourceName !== "" ? sourceSelector.activeSourceName : (currentIndex >= 0 && currentIndex < model.length ? model[currentIndex].name : ""))

        // `activated` fires only on genuine user interaction (mouse/
        // keyboard selection), not on the programmatic `currentIndex`
        // binding above - avoids a feedback loop. Bounds-checked here
        // (not in FlyoutContent) since this component owns the model
        // it's validating an index against.
        onActivated: (idx) => {
            if (idx < 0 || idx >= sourceSelector.enabledSources.length) return;
            const chosen = sourceSelector.enabledSources[idx];
            sourceSelector.sourceChosen(chosen.index, chosen.name);
        }

        implicitHeight: 42
        background: Rectangle {
            radius: sourceSelector.theme.radiusMd
            color: sourceSelector.theme.surface
            border.width: 1
            border.color: sourceCombo.hovered ? sourceSelector.theme.copperDim : sourceSelector.theme.divider
        }
        contentItem: RowLayout {
            spacing: 10
            // Matches inset/spacing roughly - ComboBox's own leftPadding
            // still applies around this contentItem.
            Rectangle {
                objectName: "sourceIconBadge"
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                radius: sourceSelector.theme.radiusSm
                color: sourceSelector.theme.surface3
                Label {
                    anchors.centerIn: parent
                    text: "◉"
                    font.pixelSize: 12
                    color: sourceSelector.theme.copperBright
                }
            }
            Label {
                id: sourceComboLabel
                objectName: "sourceComboLabel"
                Layout.fillWidth: true
                text: sourceCombo.displayText
                font.family: sourceSelector.theme.fontDisplay
                font.weight: Font.DemiBold
                font.pixelSize: 13
                color: sourceSelector.theme.text
                wrapMode: Text.NoWrap
                maximumLineCount: 1
                elide: Text.ElideRight
            }
        }
        indicator: Label {
            objectName: "sourceComboIndicator"
            x: sourceCombo.width - width - 10
            y: sourceCombo.topPadding + (sourceCombo.availableHeight - height) / 2
            text: "⌄"
            font.pixelSize: 11
            color: sourceSelector.theme.textFaint
        }
    }
}
