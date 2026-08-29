// Phase 4.4.0: our "General" ConfigDialog page - started as just the
// brand header (icon mark + "Devialet Expert Remote" / "Widget
// Settings"), per design/mockups/devialet_config_dialog_mockup_v3.html's
// .brand-header.
//
// Root is KCM.SimpleKCM, matching the real convention confirmed against
// two shipped Plasma 6 applets (luisbocanegra.panel.colorizer,
// org.kde.desktopcontainment) - checked its own source
// (org.kde.kcmutils/SimpleKCM.qml) rather than assumed: it's plain
// Kirigami.ScrollablePage underneath, documented as "intended to be used
// as root item for KCMs with arbitrary content" - no forced Breeze-form
// styling that would fight this page's fully custom copper/graphite
// look, unlike a plain Kirigami.FormLayout-only page would suggest.
//
// Reuses ../ui/Theme.qml for palette/fonts, same as every other custom-
// styled QML in this package - during debugging this file's real bug
// (see config.qml's ROOT CAUSE comment: ConfigCategory.source resolves
// relative to contents/ui/, not contents/config/, so this page was never
// actually loading at all), the Theme.qml import and `import
// org.kde.plasma.plasmoid` were both tried as suspected fixes and ruled
// out live - neither was the cause. The plasmoid import is kept anyway
// since every real working precedent checked includes it.
//
// Phase 4.4.1: adds the full Appearance/Volume/Amplifiers/Startup layout
// from the same mockup, matching its flat DOM structure - one outer
// ColumnLayout holding the brand header followed by SectionLabel/
// SettingsRow items in sequence (not Kirigami.FormLayout, whose label-
// column convention doesn't match this page's custom row shape at all).
// Every control is purely visual and no-op this phase - no KConfig
// writes, no D-Bus calls other than the read-only KnownAmps count below.
// Real wiring is Phases 4.4.2-4.4.7, one control at a time.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.workspace.dbus as Dbus
import "../ui" as Ui

KCM.SimpleKCM {
    id: root

    readonly property Ui.Theme theme: Ui.Theme {}

    // Phase 4.4.2: cfg_<entryName> is the standard Plasma ConfigModule
    // convention - the shell's own AppletConfiguration.qml (open()/
    // saveConfig()) pushes the live KConfig value in here on dialog open
    // and reads it back only when Apply/OK is clicked, also using
    // cfg_volumeStepDbChanged to drive the Apply button's dirty state.
    // Confirmed by reading that shell source directly, not assumed - see
    // a real precedent doing the same (luisbocanegra.panel.colorizer's
    // configWidgetIslands.qml, property alias cfg_*).
    property real cfg_volumeStepDb: 1.0
    readonly property var stepValues: [0.5, 1, 2]

    // Read-only live count for the "Forget All (N)" button's idle label -
    // explicitly sanctioned by this phase's scope (display only, not
    // wiring the forget action itself). Deliberately simpler than
    // FullRepresentation.qml's fetchKnownAmpsFresh()/re-fetch-on-signal
    // machinery (needed there because KnownAmps' PropertiesChanged delta
    // payload isn't trustworthy on repeat updates - see that file's own
    // doc): this is a one-time snapshot read on dialog open, not a
    // long-lived live view, so a single onRefreshed read is enough.
    property int knownAmpsCount: 0

    // Same unwrap() as FullRepresentation.qml (Phase 2 finding, still true
    // here): properties.KnownAmps from onRefreshed arrives as a
    // {"value": [...]} wrapper, not a bare array - skipping this produced
    // a real bug caught live (raw.length on the wrapper object is
    // undefined, which QML silently coerces an int property to 0 -
    // rendered as a plausible-looking but wrong "Forget All (0)" with a
    // real known amp connected).
    function unwrap(prop, fallback) {
        if (prop === undefined || prop === null) return fallback;
        if (typeof prop === "object" && prop.value !== undefined) return prop.value;
        return prop;
    }

    Dbus.Properties {
        busType: Dbus.BusType.Session
        service: "com.ekmanch.DevialetRemote"
        path: "/com/ekmanch/DevialetRemote/Amp"
        iface: "com.ekmanch.DevialetRemote.Amp1"

        onRefreshed: {
            const known = root.unwrap(properties.KnownAmps, []);
            root.knownAmpsCount = known.length;
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: Kirigami.Units.largeSpacing * 2
            spacing: Kirigami.Units.largeSpacing

            Rectangle {
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: 9
                color: root.theme.surface
                border.width: 1
                border.color: root.theme.copperDim

                Label {
                    anchors.centerIn: parent
                    text: "◉"
                    font.pixelSize: 14
                    color: root.theme.copperBright
                }
            }

            ColumnLayout {
                spacing: 2

                Label {
                    text: "Devialet Expert Remote"
                    font.family: root.theme.fontDisplay
                    font.weight: Font.DemiBold
                    font.pixelSize: 17
                    color: root.theme.text
                }

                Label {
                    text: "WIDGET SETTINGS"
                    font.family: root.theme.fontMono
                    font.pixelSize: 10
                    font.letterSpacing: 1.2
                    color: root.theme.textFaint
                }
            }

            Item { Layout.fillWidth: true }
        }

        // ---- Appearance ----
        SectionLabel { text: "Appearance"; first: true }

        SettingsRow {
            name: "Blur background"
            desc: "Glassy vibrancy behind the flyout"
            SettingsSwitch { id: blurSwitch; checked: true }
        }

        SettingsRow {
            name: "Transparency"
            desc: "Let the desktop show through the panel"
            SettingsSwitch { id: transSwitch; checked: true }
        }

        // Mockup's .kcm-sub-row: not a SettingsRow (no name/desc/divider of
        // its own) - just the slider, indented under the Transparency row
        // it belongs to, dimmed/inert when that switch is off.
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 8
            Layout.bottomMargin: 4
            opacity: transSwitch.checked ? 1.0 : 0.35
            enabled: transSwitch.checked
            Behavior on opacity { NumberAnimation { duration: 150 } }
            spacing: 10

            Slider {
                id: transSlider
                Layout.fillWidth: true
                implicitHeight: 21
                from: 0
                to: 100
                stepSize: 1
                value: 72

                background: Rectangle {
                    x: transSlider.leftPadding
                    y: transSlider.topPadding + transSlider.availableHeight / 2 - height / 2
                    width: transSlider.availableWidth
                    height: 4
                    radius: 999
                    color: root.theme.surface3

                    Rectangle {
                        width: transSlider.visualPosition * parent.width
                        height: parent.height
                        radius: 999
                        color: root.theme.copper
                    }
                }

                handle: Rectangle {
                    x: transSlider.leftPadding + transSlider.visualPosition * (transSlider.availableWidth - width)
                    y: transSlider.topPadding + transSlider.availableHeight / 2 - height / 2
                    width: 15
                    height: 15
                    radius: 999
                    color: root.theme.copperBright
                }
            }

            Label {
                text: Math.round(transSlider.value) + "%"
                font.family: root.theme.fontMono
                font.pixelSize: 11
                color: root.theme.copperBright
                Layout.preferredWidth: 34
                horizontalAlignment: Text.AlignRight
            }
        }

        // ---- Volume ----
        SectionLabel { text: "Volume" }

        SettingsRow {
            name: "Step per scroll notch"
            desc: "Applies to scroll-over-icon and +/- buttons"

            Rectangle {
                id: stepSegmented
                radius: root.theme.radiusSm
                color: root.theme.surface
                border.width: 1
                border.color: root.theme.divider
                implicitWidth: stepRow.implicitWidth + 6
                implicitHeight: stepRow.implicitHeight + 6

                // Phase 4.4.2: derived from cfg_volumeStepDb rather than a
                // literal, so it stays in sync whether that value came from
                // the dialog's own initial load or a click below.
                property int activeIndex: root.stepValues.indexOf(root.cfg_volumeStepDb)

                RowLayout {
                    id: stepRow
                    anchors.centerIn: parent
                    spacing: 2

                    Repeater {
                        model: ["0.5 dB", "1 dB", "2 dB"]

                        Rectangle {
                            required property string modelData
                            required property int index

                            radius: 6
                            color: stepSegmented.activeIndex === index ? root.theme.surface3 : "transparent"
                            implicitWidth: stepLabel.implicitWidth + 22
                            implicitHeight: stepLabel.implicitHeight + 10

                            Label {
                                id: stepLabel
                                anchors.centerIn: parent
                                text: parent.modelData
                                font.family: root.theme.fontMono
                                font.pixelSize: 11
                                color: stepSegmented.activeIndex === parent.index ? root.theme.copperBright : root.theme.textDim
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.cfg_volumeStepDb = root.stepValues[parent.index]
                            }
                        }
                    }
                }
            }
        }

        // ---- Amplifiers ----
        SectionLabel { text: "Amplifiers" }

        SettingsRow {
            name: "Forget remembered amps"
            desc: "Clears saved IPs — daemon will rediscover via mDNS/UDP. Does not disconnect the active amp."

            Rectangle {
                id: forgetBtn
                radius: root.theme.radiusSm
                implicitWidth: forgetLabel.implicitWidth + 28
                implicitHeight: forgetLabel.implicitHeight + 14

                // idle -> confirming (3s revert timer) -> done (terminal,
                // matches the mockup's handleForget() - no-op this phase,
                // no real amps are ever forgotten.
                property string phase: "idle"

                color: phase === "confirming" ? Qt.rgba(root.theme.danger.r, root.theme.danger.g, root.theme.danger.b, 0.16) : root.theme.surface
                border.width: 1
                border.color: (phase === "confirming" || forgetArea.containsMouse) ? root.theme.danger : root.theme.divider
                opacity: phase === "done" ? 0.5 : 1.0

                Label {
                    id: forgetLabel
                    anchors.centerIn: parent
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    text: forgetBtn.phase === "confirming" ? "Click to confirm"
                        : forgetBtn.phase === "done" ? "Forget All (0)"
                        : "Forget All (" + root.knownAmpsCount + ")"
                    color: (forgetBtn.phase === "confirming" || forgetArea.containsMouse) ? root.theme.dangerBright : root.theme.text
                }

                Timer {
                    id: forgetRevertTimer
                    interval: 3000
                    onTriggered: if (forgetBtn.phase === "confirming") forgetBtn.phase = "idle"
                }

                MouseArea {
                    id: forgetArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: forgetBtn.phase !== "done"
                    onClicked: {
                        if (forgetBtn.phase === "idle") {
                            forgetBtn.phase = "confirming";
                            forgetRevertTimer.restart();
                        } else if (forgetBtn.phase === "confirming") {
                            forgetRevertTimer.stop();
                            forgetBtn.phase = "done";
                        }
                    }
                }
            }
        }

        // ---- Startup ----
        SectionLabel { text: "Startup" }

        SettingsRow {
            name: "Launch at login"
            desc: "Starts the background daemon via systemd --user"
            showDivider: false
            SettingsSwitch { id: loginSwitch; checked: false }
        }
    }
}
