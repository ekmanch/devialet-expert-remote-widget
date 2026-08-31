// Phase 4.5.0: custom hover indicator for the panel icon, showing this
// plasmoid's own copper/graphite look instead of generic tooltip styling.
//
// Phase 4.5.3 Bug 3 fix: originally implemented via PlasmoidItem.
// toolTipItem, which hands content to the shell's own ToolTipDialog
// (plasma-workspace's CompactApplet.qml -> PlasmaCore.ToolTipArea ->
// internally instantiates ToolTipDialog : PopupPlasmaWindow :
// PlasmaWindow). That class always paints its own background/frame behind
// whatever toolTipItem content is supplied - PlasmaWindow::BackgroundHints
// (confirmed in libplasma's plasmawindow.h) has only StandardBackground/
// SolidBackground, no NoBackground value at all, so the frame could not be
// suppressed. Confirmed by direct comparison against VolumeToast.qml
// (Phase 4.5.0's OSD toast), which achieves a genuinely zero-frame look
// via a DIFFERENT class this file now also uses: PlasmaCore.Dialog, built
// directly by us rather than handed off to the shell, whose
// BackgroundHints enum (confirmed in libplasma's dialog.h) does include a
// real NoBackground value.
//
// This file is its own PlasmaCore.Dialog (type: Tooltip, matching the
// real role_tooltip Wayland role the shell's own tooltip uses - confirmed
// in dialog.cpp's applyType()), driven directly by CompactRepresentation.
// qml's own hover state instead of PlasmoidItem.toolTipItem. main.qml
// additionally sets toolTipMainText/toolTipSubText to explicit empty
// strings (Phase 4.5.3 item 1 fix - see main.qml's own comment for why
// merely leaving them unset wasn't enough) so libplasma's own
// ToolTipArea::isValid() (tooltiparea.cpp: `m_mainItem ||
// !mainText().isEmpty() || !subText().isEmpty()`) returns false and the
// shell's default tooltip machinery cleanly no-ops on hover instead of
// showing metadata.json's Name/Comment alongside our own.
//
// Positioning is NOT hand-computed - Dialog::popupPosition() (confirmed
// in dialog.cpp) automatically places a Dialog with both `visualParent`
// and `location` set on the opposite edge from `location` (e.g.
// location: TopEdge -> appears below visualParent, horizontally centered
// on it) - the same mechanism the flyout's own popup relies on. `location:
// Plasmoid.location` here mirrors exactly what the real ToolTipArea does
// with its own `m_location` for the same purpose (tooltiparea.cpp's
// showToolTip()).
//
// Show/hide timing replicates ToolTipArea/ToolTipDialog's own real
// behavior (confirmed by reading tooltiparea.cpp/tooltipdialog.cpp), not
// invented: a delay before first showing (Kirigami.Units.toolTipDelay -
// the same property real KDE apps bind QQC2 ToolTip.delay to, itself
// backed by the global "PlasmaToolTips/Delay" KConfig entry ToolTipArea
// reads directly, default 700ms - using the Kirigami property instead of
// reading that KConfig group ourselves, since it's the standard QML-
// exposed path to the same value), and a short grace period before
// hiding (200ms, matching ToolTipDialog::dismiss()'s own hardcoded
// `m_hideTimer.start(200)` exactly) rather than an instant hide - both
// timers driven from CompactRepresentation.qml's hover handlers, not
// this file (this file only reacts to its own `visible` property).
// CompactRepresentation.qml also forces this hidden (and refuses to
// re-show it) while the flyout is open (Phase 4.5.3 item 4, then item 2
// of the follow-up round), so it never floats on top of it.
//
// Phase 4.5.3 item 2 (follow-up round): the volume-level icon added in
// the previous round was a mistake - the approved mockup
// (devialet_tray_tooltip_mockup_v4.html) only ever used a small copper
// status dot next to the amp name, never a full icon box. Reverted back
// to the dot; "Muted" still swaps in for the dB reading (that part of
// the earlier fix was correct and is kept), just with no icon
// accompanying it, muted or not. Background gradient/radius/border still
// match VolumeToast.qml's OSD-toast look (theme.osdGradientTop/Bottom,
// radiusLg) - only the icon was reverted, nothing else from that round.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Effects
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid

PlasmaCore.Dialog {
    id: tooltip

    property string ampName: ""
    property string sourceName: ""
    property var volumeDb: undefined
    property real volumeFraction: 0
    property bool hasAmp: false
    property bool muted: false

    readonly property Theme theme: Theme {}
    readonly property bool isWordValue: tooltip.hasAmp && tooltip.muted

    type: PlasmaCore.Dialog.Tooltip
    flags: Qt.WindowDoesNotAcceptFocus
    backgroundHints: PlasmaCore.Dialog.NoBackground
    location: Plasmoid.location
    hideOnWindowDeactivate: false

    mainItem: Rectangle {
        id: card
        implicitWidth: 172
        implicitHeight: column.implicitHeight + 18
        radius: tooltip.theme.radiusLg
        border.color: tooltip.theme.divider
        border.width: 1

        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: tooltip.theme.osdGradientTop }
            GradientStop { position: 1.0; color: tooltip.theme.osdGradientBottom }
        }

        ColumnLayout {
            id: column
            anchors.fill: parent
            anchors.topMargin: 9
            anchors.bottomMargin: 9
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 0

            RowLayout {
                id: nameRow
                spacing: 6
                // NOT the mockup's literal margin-bottom:5px - re-measured
                // after fixing the real statRow baseline bug below (a
                // nested RowLayout doesn't get a usable Qt.AlignBaseline,
                // which is what caused the "Optical 1 sitting over the
                // value" bug, not a margin issue) and confirmed the
                // literal 5/6 values still render gap-above/gap-below at
                // roughly 19.75px/19.25px - nearly equal, not the
                // mockup's own ~70:100 (stat-row-hugs-the-bar) rhythm.
                // Confirmed the mockup's own rendering only produces that
                // ratio via font-metric/line-height differences (likely
                // Google Fonts not resolving from a bare file:// page)
                // that don't carry over to QML's real bundled fonts, so
                // matching the actual visual rhythm needs different
                // numbers here, not the literal CSS ones.
                Layout.bottomMargin: 7

                Rectangle {
                    id: dot
                    width: 5; height: 5
                    radius: 2.5
                    color: tooltip.theme.copperBright

                    layer.enabled: true
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        shadowColor: tooltip.theme.copperBright
                        shadowBlur: 0.6
                        shadowOpacity: 0.5
                        shadowScale: 1.6
                        shadowHorizontalOffset: 0
                        shadowVerticalOffset: 0
                    }
                }

                Label {
                    Layout.fillWidth: true
                    text: tooltip.ampName
                    font.family: tooltip.theme.fontDisplay
                    font.weight: Font.DemiBold
                    font.pixelSize: 11
                    color: tooltip.theme.text
                    elide: Text.ElideRight
                }
            }

            // Flat children, not a nested RowLayout for the value+unit pair -
            // found the real bug (not a margin issue): Qt.AlignBaseline on a
            // *nested* RowLayout doesn't work, since a generic layout
            // container has no real font-metric baselineOffset the way a
            // Label does - the outer statRow was aligning "Optical 1" to an
            // actual text baseline while aligning the value+unit pair to
            // effectively nothing, visibly offsetting them onto different
            // lines instead of sharing one (confirmed live: a screenshot
            // showed "Optical 1" and "Muted" sitting at different heights,
            // not just spaced differently - reported directly, not
            // self-diagnosed). Every prior margin-tuning pass in this same
            // investigation was chasing a symptom of this bug, not a real
            // spacing question, and produced unreliable measurements (the
            // baseline-broken value+unit pair was splitting into a second
            // detected "band" that got mistaken for real row content).
            // bottomMargin below is retuned from a clean, bug-fixed
            // measurement instead of trusted at face value - see nameRow's
            // own comment for why the literal CSS number alone (6px here)
            // still doesn't reproduce the mockup's own visual rhythm even
            // once the real bug was out of the way.
            RowLayout {
                id: statRow
                spacing: 1
                Layout.bottomMargin: 4
                // Pinned rather than left implicit: statRow's natural
                // implicitHeight differs by 2px between states (16 muted /
                // 18 unmuted), since the "dB" unit Label is excluded from
                // layout entirely via visible:false when muted (QtQuick
                // Layouts drops invisible children from sizing, not just
                // rendering). Confirmed via live onHeightChanged/onYChanged
                // logging (journalctl) that this 2px implicitHeight swing -
                // despite statRow being AFTER nameRow in the column - was
                // perturbing ColumnLayout's positioning of nameRow itself
                // (nameRow.y measured at 0 unmuted vs 1 muted, in logical
                // px - exactly the +2 physical-px shift reported against
                // "Devialet Expert 140 Pro"), a QtQuick Layouts stacking
                // artifact, not a structural bug in nameRow (which has no
                // nested layout or baseline alignment at all - confirmed by
                // reading it directly). Pinning statRow's own height to a
                // constant removes the trigger at its source rather than
                // trying to patch nameRow for a problem that isn't really
                // there. 18 matches the taller (unmuted, numeric+"dB")
                // natural height.
                //
                // Round 5: pinning this height did NOT fully fix
                // mute-dependent shifting - "Optical 1" (a direct sibling
                // here) kept moving a couple px between states even after
                // this pin and the flattening above. Root cause: this row's
                // children used Qt.AlignBaseline, which computes a shared
                // baseline offset *within* this fixed height from the font
                // metrics of whichever children currently participate - and
                // that set/those metrics still varied by mute state (the
                // value Label swaps font.family/pixelSize/weight between
                // the numeric and "Muted" forms; the "dB" Label drops out of
                // the row's sizing/baseline computation entirely via
                // visible:false when muted). So even with a pinned outer
                // height and flat siblings, every AlignBaseline child -
                // including "Optical 1", whose own font never changes - got
                // repositioned along with the shifting computed baseline.
                // Fixed by switching every child below to Qt.AlignVCenter:
                // centering is computed from each Label's own height only,
                // with no dependency on sibling content/fonts/visibility, so
                // no element's position can be perturbed by another
                // element's mute-driven content change again.
                Layout.preferredHeight: 18

                Label {
                    Layout.alignment: Qt.AlignVCenter
                    text: tooltip.hasAmp && tooltip.sourceName !== "" ? tooltip.sourceName : "—"
                    font.family: tooltip.theme.fontMono
                    font.pixelSize: 10
                    color: tooltip.theme.textFaint
                }

                Item { Layout.fillWidth: true }

                Label {
                    Layout.alignment: Qt.AlignVCenter
                    text: {
                        if (!tooltip.hasAmp) return "—";
                        if (tooltip.muted) return "Muted";
                        return tooltip.volumeDb !== undefined ? tooltip.volumeDb.toFixed(1) : "—";
                    }
                    font.family: tooltip.isWordValue ? tooltip.theme.fontDisplay : tooltip.theme.fontMono
                    font.weight: tooltip.isWordValue ? Font.DemiBold : Font.Medium
                    font.pixelSize: tooltip.isWordValue ? 12 : 13
                    color: tooltip.theme.copperBright
                }
                Label {
                    Layout.alignment: Qt.AlignVCenter
                    visible: !tooltip.isWordValue
                    text: "dB"
                    font.pixelSize: 9
                    color: tooltip.theme.textDim
                }
            }

            Rectangle {
                id: barTrack
                Layout.fillWidth: true
                Layout.bottomMargin: 7
                height: 2.5
                radius: 999
                color: tooltip.theme.surface3
                clip: true

                Rectangle {
                    height: parent.height
                    width: parent.width * tooltip.volumeFraction
                    radius: 999
                    color: tooltip.muted ? tooltip.theme.textFaint : tooltip.theme.copper
                }
            }

            ColumnLayout {
                spacing: 2

                RowLayout {
                    spacing: 3
                    Label { text: "Scroll"; font.family: tooltip.theme.fontMono; font.weight: Font.Medium; font.pixelSize: 9; color: tooltip.theme.textDim }
                    Label { text: "to adjust"; font.family: tooltip.theme.fontMono; font.pixelSize: 9; color: tooltip.theme.textFaint }
                }
                RowLayout {
                    spacing: 3
                    Label { text: "Middle-click"; font.family: tooltip.theme.fontMono; font.weight: Font.Medium; font.pixelSize: 9; color: tooltip.theme.textDim }
                    Label { text: "to mute"; font.family: tooltip.theme.fontMono; font.pixelSize: 9; color: tooltip.theme.textFaint }
                }
            }
        }
    }
}
