// Phase 4.5.0: copper-styled reskin of Plasma's own native volume OSD
// (org.kde.plasmashell, /org/kde/osdService, org.kde.osdService.showText/
// volumeChanged - see plasma-workspace's shell/osd.cpp and
// org.kde.plasma.workspace.osd's OsdItem.qml, both read directly from
// invent.kde.org during investigation, not guessed). Deliberately a visual
// reskin only - the interaction design (when it shows, how long it stays,
// what happens on rapid repeat) is copied byte-for-byte from that real
// service, not reinvented:
//
// - Timing: 1800ms fixed dismiss, OsdItem.qml's own real default
//   (`property int timeout: 1800`, confirmed by reading the file installed
//   on this system at /usr/lib/qt6/qml/org/kde/plasma/workspace/osd/
//   OsdItem.qml:19) - not a rough "~1s" guess.
// - Rapid-repeat: matches Osd::showOsd() (plasma-workspace's shell/osd.cpp)
//   exactly - every call stops the pending dismiss timer, snaps the
//   content to the new value instantly (no queueing, no fade-in replay),
//   then restarts the same fixed timeout from zero. One reusable instance,
//   one non-repeating Timer, `restart()` on every show() call - same
//   shape as the real showOsd()'s stop/update/start sequence.
// - Placement: PlasmaCore.Dialog's `type: OnScreenDisplay` is the exact
//   mechanism the real OSD's own window uses for automatic screen-relative
//   (bottom-center) placement - confirmed by reading libplasma's
//   dialog.cpp: on Wayland (this session's compositor), setting this type
//   calls the identical `PlasmaShellWaylandIntegration::setRole(
//   role_onscreendisplay)` plasma-workspace's own shell/osdwindow.cpp calls
//   for the real OSD, and dialog.cpp deliberately skips its own manual
//   setPosition() call for this type specifically ("if is a wayland window
//   ... if (type != Dialog::OnScreenDisplay) setPosition(...)) - the
//   compositor places it, not us, same as the real one. Not an icon-
//   anchored popup like the flyout - a faithful reskin means matching
//   where the native OSD already appears, not inventing new placement.
//
// Phase 4.5.3 Part C fix: `flags` deliberately does NOT include Qt.ToolTip
// (an earlier version of this file did, and positioning was inconsistent -
// top-left/top-right depending on what last had focus, not the compositor's
// fixed OSD placement). Root-caused by reading dialog.cpp, not guessed: the
// real OsdWindow (plasma-workspace's shell/osdwindow.cpp) sets only
// Qt::WindowDoesNotAcceptFocus + Qt::WindowTransparentForInput, no
// Qt::ToolTip at all - and Dialog's own applyType() explicitly gates several
// behaviors on `!flags().testFlag(Qt::ToolTip)` (lines 199/297/663), with a
// comment stating "an OSD can't be a Dialog, as qt xcb would attempt to set
// a transient parent for it" - Qt::ToolTip is the same transient-parent-
// seeking category of flag as Qt::Dialog (which that code explicitly strips
// for OnScreenDisplay, but doesn't know to strip Qt::ToolTip too). Matched
// the real window's actual flags instead: WindowDoesNotAcceptFocus directly,
// and `outputOnly: true` for WindowTransparentForInput (Dialog's own
// applyType() ties that flag to `outputOnly` specifically for
// OnScreenDisplay - dialog.cpp:737-744).
//
// NOT the same "no NoBackground exists" dead end CLAUDE.md's real-
// transparency investigation hit - that was about PlasmaWindow (the
// flyout's own popup window class, PlasmaQuick::AppletPopup ->
// PopupPlasmaWindow -> PlasmaWindow). This is a different class,
// PlasmaQuick::Dialog, built directly by this file rather than provided
// implicitly by PlasmoidItem's fullRepresentation machinery - its
// BackgroundHints enum (confirmed in libplasma's dialog.h) does include a
// real NoBackground value, which is what makes the fully custom copper
// pill background below possible at all.
//
// Phase 4.5.3: restyled to match design/mockups/OSD/
// devialet_volume_osd_mockup_v3.html exactly - icon + name + value +
// copper progress bar + source line, with a distinct muted treatment
// (copper border/glow on the icon, dimmed fill, copper "Muted" text at a
// smaller word-sized weight) rather than amber, which stays reserved for
// the existing booting/"Powering on..." state elsewhere in this widget.
//
// Part D icon thresholds: matched against the real Audio Devices applet's
// own breakpoints, not invented - `AudioIcon::forVolume()` (plasma-pa's
// src/audioicon.cpp/.h): muted or percent<=0 -> muted, <=25 -> low,
// <=75 -> medium, <=100 -> high. Icon path map + threshold function now
// live on Theme.qml (theme.volumeIconSources / theme.volumeIconKindFor
// Fraction), shared with VolumeHoverTooltip.qml (Phase 4.5.3 item 2)
// instead of each file keeping its own copy.
//
// Gradient colors also moved to Theme.qml (theme.osdGradientTop/Bottom) -
// shared with VolumeHoverTooltip.qml, which now uses the same translucent
// graphite background/radius/border/glow treatment (Phase 4.5.3 item 2).

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Effects
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

PlasmaCore.Dialog {
    id: toast

    readonly property Theme theme: Theme {}

    // ---- Content state (set via showVolume()/showMute() below) ----
    property string ampName: ""
    property string sourceName: ""
    property bool muted: false
    property bool isWordValue: false
    property string valueText: ""
    property real fraction: 0
    property string iconKind: "high"

    type: PlasmaCore.Dialog.OnScreenDisplay
    flags: Qt.WindowDoesNotAcceptFocus
    outputOnly: true
    backgroundHints: PlasmaCore.Dialog.NoBackground
    hideOnWindowDeactivate: false

    function showVolume(ampName, sourceName, volumeDb, fraction) {
        toast.ampName = ampName;
        toast.sourceName = sourceName;
        toast.muted = false;
        toast.isWordValue = false;
        toast.valueText = volumeDb.toFixed(1);
        toast.fraction = fraction;
        toast.iconKind = toast.theme.volumeIconKindForFraction(fraction);
        dismissTimer.restart();
        toast.visible = true;
    }

    function showMute(ampName, sourceName, muted, fraction) {
        toast.ampName = ampName;
        toast.sourceName = sourceName;
        toast.muted = muted;
        toast.isWordValue = true;
        toast.valueText = muted ? "Muted" : "Unmuted";
        toast.fraction = fraction;
        // Mute state's icon is unconditional per the phase brief; unmuted
        // uses the same threshold as showVolume() above.
        toast.iconKind = muted ? "mute" : toast.theme.volumeIconKindForFraction(fraction);
        dismissTimer.restart();
        toast.visible = true;
    }

    // Nested inside mainItem's Rectangle, not a direct child of the Dialog
    // itself - Dialog's default property (mainItem) is a single QQuickItem*,
    // not a list, so a second bare child here would also be implicitly
    // assigned to it, colliding with the explicit Rectangle below (confirmed
    // live: plasmashell's own error log was explicit about this - "Cannot
    // assign object of type Timer to property of type QQuickItem*" - once
    // the Timer lived at this level instead).
    mainItem: Rectangle {
        id: card
        implicitWidth: Math.max(340, row.implicitWidth + 36)
        implicitHeight: row.implicitHeight + 28
        radius: toast.theme.radiusLg
        border.color: toast.theme.divider
        border.width: 1

        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: toast.theme.osdGradientTop }
            GradientStop { position: 1.0; color: toast.theme.osdGradientBottom }
        }

        Timer {
            id: dismissTimer
            interval: 1800
            onTriggered: toast.visible = false
        }

        // Fixed left/right margins, not centerIn - matches the mockup's own
        // flexbox box model (padding: 14px 20px 14px 16px) exactly. Found
        // live (Bug 2, Phase 4.5.3 fix): centerIn made the icon box's
        // position depend on content width, since card's own implicitWidth
        // floors at 340 (Math.max(340, row.implicitWidth + 36)) - a short
        // "Muted" value made row narrower than 340, so centering it inside
        // the wider card shifted everything inward; a wide numeric dB
        // reading kept row close to 340, looking flush by comparison. Fixed
        // margins keep the icon box's position identical regardless of
        // content width; the body ColumnLayout's existing Layout.fillWidth
        // absorbs any extra space on the right, matching the mockup's own
        // `.osd-body{ flex:1 }`.
        RowLayout {
            id: row
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            spacing: 14

            Rectangle {
                id: iconBox
                Layout.preferredWidth: 34
                Layout.preferredHeight: 34
                radius: 10
                color: toast.theme.surface
                border.width: 1
                border.color: toast.muted ? toast.theme.copperDim : toast.theme.divider

                layer.enabled: toast.muted
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: toast.theme.copperBright
                    shadowBlur: 0.5
                    shadowOpacity: 0.25
                    shadowScale: 1.25
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: 0
                }

                Kirigami.Icon {
                    anchors.centerIn: parent
                    width: 17
                    height: 17
                    source: toast.theme.volumeIconSources[toast.iconKind]
                    isMask: true
                    color: toast.muted ? toast.theme.copperBright : toast.theme.text
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                RowLayout {
                    Layout.bottomMargin: 7
                    Layout.fillWidth: true
                    // Same hazard class as VolumeHoverTooltip.qml's statRow
                    // (Phase 4.5.3 round 5): valueText's font.family/weight/
                    // pixelSize swap between the numeric-dB and "Muted"/
                    // "Unmuted" word forms, which shifts Qt.AlignBaseline's
                    // shared row-internal offset - moving ampName (whose own
                    // font never changes) whenever valueText's content type
                    // changes. Fixed the same way: Qt.AlignVCenter on both
                    // Labels plus a pinned preferredHeight so the row's own
                    // height doesn't fluctuate either.
                    //
                    // 20, not a rounder-looking guess: measured live
                    // (onImplicitHeightChanged logging via a standalone
                    // driver instantiating this component directly, see
                    // this phase's own verification) - valueText's implicit
                    // height is 20 in its numeric-dB form (pixelSize 15
                    // mono) vs 16 in its word form (pixelSize 12 display),
                    // and ampName's is a constant 17. Pinning preferredHeight
                    // to anything other than the true tallest content's own
                    // implicit height (first tried 18, guessed from
                    // pixelSize alone) leaves a residual 1px shift on
                    // ampName even with AlignVCenter: when a sibling's
                    // implicit height exceeds the pinned row height,
                    // RowLayout's internal cross-axis centering still keys
                    // off that overflowing sibling, not just the pinned
                    // height in isolation - so AlignVCenter alone is
                    // necessary but not sufficient; the pinned height must
                    // equal the tallest child's real implicit height, not
                    // an approximation. Confirmed fixed: with 20, ampName's
                    // y no longer changes at all across any mute/volume
                    // transition (with the guessed 18 it still toggled by
                    // 1px between the numeric and word forms).
                    Layout.preferredHeight: 20

                    Label {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        text: toast.ampName
                        font.family: toast.theme.fontDisplay
                        font.weight: Font.DemiBold
                        font.pixelSize: 13
                        color: toast.theme.text
                        elide: Text.ElideRight
                    }

                    Label {
                        Layout.alignment: Qt.AlignVCenter
                        text: toast.valueText + (toast.isWordValue ? "" : " dB")
                        font.family: toast.isWordValue ? toast.theme.fontDisplay : toast.theme.fontMono
                        font.weight: toast.isWordValue ? Font.DemiBold : Font.Medium
                        font.pixelSize: toast.isWordValue ? 12 : 15
                        // Mockup only shows a "Muted" word variant (copper)
                        // and a numeric dB variant (always copper) - there's
                        // no "Unmuted" example. Extrapolated: "Unmuted"
                        // renders plain (theme.text), consistent with "copper
                        // is reserved for signaling an actually-active state"
                        // (the same rule the mockup states for the icon).
                        color: toast.isWordValue ? (toast.muted ? toast.theme.copperBright : toast.theme.text) : toast.theme.copperBright
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 4
                    radius: 999
                    color: toast.theme.surface3
                    clip: true

                    Rectangle {
                        height: parent.height
                        width: parent.width * toast.fraction
                        radius: 999
                        color: toast.muted ? toast.theme.textFaint : toast.theme.copper
                    }
                }

                Label {
                    Layout.topMargin: 6
                    text: toast.sourceName !== "" ? toast.sourceName : "—"
                    font.family: toast.theme.fontMono
                    font.pixelSize: 10
                    color: toast.theme.textFaint
                }
            }
        }
    }
}
