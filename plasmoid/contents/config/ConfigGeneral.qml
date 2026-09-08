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
    // KCMUtils' generic ConfigModule loader (not this shell's own
    // AppletConfiguration.qml - grepped it directly, no match there)
    // expects a cfg_<name>Default companion for every cfg_<name> binding
    // it discovers, for its own defaults-comparison bookkeeping - found
    // live as a real (harmless but real) "Setting initial properties
    // failed: ConfigGeneral does not have a property called
    // cfg_volumeStepDbDefault" warning in the journal before these
    // existed, for every one of this file's cfg_* properties, not just
    // the ones added this pass. Sourced from shippedDefaults below rather
    // than re-typing the literals a third time.
    readonly property real cfg_volumeStepDbDefault: root.shippedDefaults.volumeStepDb
    readonly property var stepValues: [0.5, 1, 2]

    // Appearance section - see main.xml's own comment on these two
    // entries for why wiring them into the real flyout/OSD/tooltip alpha
    // is deferred.
    property bool cfg_transparencyEnabled: true
    property int cfg_transparencyPercent: 90
    readonly property bool cfg_transparencyEnabledDefault: root.shippedDefaults.transparencyEnabled
    readonly property int cfg_transparencyPercentDefault: root.shippedDefaults.transparencyPercent

    // Phase 8.0.0: volume-limit settings (main.xml entries volumeFloorDb/
    // hardLimitDb/startupVolumeDb) - same cfg_<entryName> convention as
    // cfg_volumeStepDb above. Real Expert Pro line range for every
    // DbStepper below (CLAUDE.md/mockup: -96..0 dB).
    property real cfg_volumeFloorDb: -45.0
    property real cfg_hardLimitDb: -10.0
    property real cfg_startupVolumeDb: -40.0
    readonly property real cfg_volumeFloorDbDefault: root.shippedDefaults.volumeFloorDb
    readonly property real cfg_hardLimitDbDefault: root.shippedDefaults.hardLimitDb
    readonly property real cfg_startupVolumeDbDefault: root.shippedDefaults.startupVolumeDb
    readonly property real dbRangeMin: -96.0
    readonly property real dbRangeMax: 0.0

    // Phase 8.3.0: floor and hard limit must stay strictly ordered
    // (floor < hard limit, never equal - a 0dB-wide range is meaningless).
    // One stepper increment is the minimum usable gap. Named rather than
    // relying on DbStepper's own default `stepDb: 1` so the two steppers
    // below and this gap agree by construction, not by coincidence.
    readonly property real limitStepDb: 1.0

    // Self-heal: called whenever either limit changes, for any reason - a
    // user step (already prevented from producing an invalid pair by the
    // steppers' own to/from binding below, so this is a no-op in that
    // case), Defaults/Reset (see its own onClicked comment for the
    // widen-first write order that keeps every intermediate pair valid
    // too), or any other in-process write to either cfg_* property.
    //
    // Does NOT reach external KConfig file corruption while the widget is
    // already running, despite this being the original intent (see
    // main.qml's own comment on its VolumeSettings.Component.onCompleted
    // check for the full story) - investigated live (Phase 8.3.0,
    // 2026-09-06) and found structurally unreachable from applet QML:
    // `Plasmoid.configuration` is one `KConfigPropertyMap` object, created
    // once per plasmashell process and shared by every QML file in this
    // KPackage (confirmed identical object address across two separate
    // ConfigGeneral.qml page instantiations, and the live flyout showing
    // the same stale values as this page at the same moment). It reads
    // the file correctly exactly once, at that KConfigPropertyMap's own
    // construction (i.e. at process start - main.qml's on-load check is
    // reliable specifically because it runs at that exact point), and
    // never re-reads it afterward for an external write, for the life of
    // that process - not on this page's own Component.onCompleted firing
    // again for a fresh page instance, not across real close/reopen
    // cycles, not for kwriteconfig6 vs. a raw editor save (both equally
    // stale). Only a full plasmashell restart re-reads the file. No QML-
    // level API to force a reload was found; hand-rolling one (reading
    // the raw INI file directly, bypassing KConfig) would duplicate and
    // diverge from Plasma's own config format/semantics for a rare,
    // non-adversarial scenario (CLAUDE.md's "not something the owner is
    // defending against maliciously") - not worth it. Floor gets the more
    // negative (quieter) of the pair, hard limit the less negative one,
    // matching every other floor/hardLimit pair in this file (shipped
    // defaults: floor -45.0 < hardLimit -10.0).
    function healLimitOrdering() {
        if (root.cfg_volumeFloorDb >= root.cfg_hardLimitDb) {
            console.log("[ConfigGeneral] floor/hardLimit invalid (" + root.cfg_volumeFloorDb +
                        " >= " + root.cfg_hardLimitDb + ") - self-healing to -40.0/-39.0");
            root.cfg_volumeFloorDb = -40.0;
            root.cfg_hardLimitDb = -39.0;
        }
    }

    onCfg_volumeFloorDbChanged: root.healLimitOrdering()
    onCfg_hardLimitDbChanged: root.healLimitOrdering()

    // Mirrors main.xml's own <default> entries - feeds both the
    // cfg_<name>Default properties above (what KCMUtils' generic loader
    // expects) and the Reset section's "Defaults" button below (what a
    // user click actually resets to). Still a real duplication in spirit
    // (this project has no generated kcfg-defaults QML accessor that
    // reads main.xml directly) but now only entered once, in one place,
    // rather than three times. Update this alongside main.xml if a
    // default ever changes.
    readonly property var shippedDefaults: ({
        transparencyEnabled: true,
        transparencyPercent: 90,
        volumeStepDb: 1.0,
        startupVolumeDb: -40.0,
        volumeFloorDb: -45.0,
        hardLimitDb: -10.0
    })

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
        // UI only for now, per explicit owner instruction (2026-09-05) -
        // see main.xml's own comment on transparencyEnabled/
        // transparencyPercent for why wiring this into the flyout/OSD/
        // tooltip's real alpha is deferred until after Phase 8.x.x.
        SectionLabel { text: "Appearance"; first: true }

        SettingsRow {
            name: "Transparency"
            desc: "Let the desktop show through the panel"

            SettingsSwitch {
                id: transparencySwitch
                checked: root.cfg_transparencyEnabled
                onCheckedChanged: root.cfg_transparencyEnabled = checked
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: -6
            Layout.bottomMargin: 8
            spacing: 10
            // Mockup's .kcm-sub-row.disabled - dims/disables the slider
            // whenever Transparency is off, matching toggleTransSub().
            opacity: transparencySwitch.checked ? 1.0 : 0.35
            enabled: transparencySwitch.checked

            Slider {
                id: transparencySlider
                Layout.fillWidth: true
                from: 0
                to: 100
                stepSize: 1
                value: root.cfg_transparencyPercent
                onMoved: root.cfg_transparencyPercent = value

                // Same copper track/handle styling as VolumeBlock.qml's
                // volumeSlider (contents/ui/) - kept as an inline style
                // here rather than a new shared component, since this is
                // the only slider control in the settings page so far.
                background: Rectangle {
                    x: transparencySlider.leftPadding
                    y: transparencySlider.topPadding + transparencySlider.availableHeight / 2 - height / 2
                    implicitHeight: 4
                    width: transparencySlider.availableWidth
                    height: 4
                    radius: 999
                    color: root.theme.surface3

                    Rectangle {
                        width: transparencySlider.visualPosition * parent.width
                        height: parent.height
                        radius: 999
                        color: root.theme.copper
                    }
                }

                handle: Rectangle {
                    x: transparencySlider.leftPadding + transparencySlider.visualPosition * (transparencySlider.availableWidth - width)
                    y: transparencySlider.topPadding + transparencySlider.availableHeight / 2 - height / 2
                    width: 15
                    height: 15
                    radius: 999
                    color: root.theme.copperBright
                }
            }

            Label {
                text: Math.round(transparencySlider.value) + "%"
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
            name: "Volume step size"
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

        SettingsRow {
            name: "Startup / source-switch volume"
            desc: "Applied after a widget-initiated power-on, and on every source switch"

            DbStepper {
                value: root.cfg_startupVolumeDb
                from: root.dbRangeMin
                to: root.dbRangeMax
                onStepped: (value) => root.cfg_startupVolumeDb = value
            }
        }

        // ---- Volume Limits ----
        // Mockup note (see design/mockups/settings_window/
        // devialet_config_dialog_mockup_v13_single_tab.html's own legend):
        // +/- steppers rather than a slider, since two interdependent
        // thresholds sharing one slider track is cramped and easy to
        // mis-drag - a stepper gives exact, unambiguous values. Volume
        // floor is ordered before Volume ceiling to match the mockup;
        // don't rearrange.
        SectionLabel { text: "Volume Limits" }

        SettingsRow {
            name: "Volume floor"
            desc: "Slider floor — hides the unused low end so real-world volumes are easier to select"

            DbStepper {
                value: root.cfg_volumeFloorDb
                from: root.dbRangeMin
                // Phase 8.3.0: can never reach (let alone pass) the current
                // hard limit - capped one step below it, not at dbRangeMax.
                // DbStepper's own `enabled: value < to` disables "+" the
                // moment this cap is reached, and its clamp() (Math.min)
                // makes the boundary step land exactly on it, never past.
                to: root.cfg_hardLimitDb - root.limitStepDb
                stepDb: root.limitStepDb
                onStepped: (value) => root.cfg_volumeFloorDb = value
            }
        }

        SettingsRow {
            name: "Volume ceiling"
            desc: "Absolute ceiling — the amp is never sent a volume above this"
            showDivider: false

            DbStepper {
                value: root.cfg_hardLimitDb
                // Phase 8.3.0: mirror of the floor stepper above - can
                // never reach the current floor, capped one step above it.
                from: root.cfg_volumeFloorDb + root.limitStepDb
                to: root.dbRangeMax
                stepDb: root.limitStepDb
                onStepped: (value) => root.cfg_hardLimitDb = value
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
            // Default true - a real install should autostart the daemon
            // out of the box. Still a dead placeholder otherwise: this
            // isn't wired to real `systemctl --user is-enabled` state yet
            // (that's Phase 4.4.6, not yet implemented - see TODO.md) or
            // backed by KConfig at all (per CLAUDE.md, it never should be -
            // systemd's own enablement state is the source of truth, not a
            // stored bool), so this default only affects what the toggle
            // visually shows before that wiring lands.
            SettingsSwitch { id: loginSwitch; checked: true }
        }

        // ---- Reset ----
        // Phase 8.0.0 follow-up: the mockup's original "Defaults" button
        // lived in the ConfigDialog's own footer (v13), but that footer
        // (Cancel/Apply/OK) is fixed shell chrome from
        // AppletConfiguration.qml - a plasmoid's config.qml has no way to
        // add a button to it (confirmed by reading that file directly, no
        // Loader/Repeater/conditional slot exists there for a 4th button).
        // v14 moves it into the page content instead, as this section -
        // see that mockup's own updated legend for the same reasoning.
        SectionLabel { text: "Reset" }

        SettingsRow {
            name: "Restore defaults"
            desc: "Resets every setting on this page back to its shipped values"
            showDivider: false

            Rectangle {
                id: defaultsBtn
                radius: root.theme.radiusSm
                implicitWidth: defaultsLabel.implicitWidth + 28
                implicitHeight: defaultsLabel.implicitHeight + 14
                color: root.theme.surface
                border.width: 1
                border.color: defaultsArea.containsMouse ? root.theme.copperDim : root.theme.divider

                Label {
                    id: defaultsLabel
                    anchors.centerIn: parent
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    text: "Defaults"
                    color: defaultsArea.containsMouse ? root.theme.copperBright : root.theme.text
                }

                MouseArea {
                    id: defaultsArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // Writes straight to the cfg_* properties, same as
                    // every other control on this page - the shell's own
                    // generic isConfigurationChanged() dirty-check (which
                    // already drives Apply for every other row here)
                    // picks this up for free, no extra wiring needed.
                    // Values must stay in sync with main.xml's own
                    // <default> entries - see root.shippedDefaults above.
                    onClicked: {
                        root.cfg_transparencyEnabled = root.shippedDefaults.transparencyEnabled;
                        root.cfg_transparencyPercent = root.shippedDefaults.transparencyPercent;
                        root.cfg_volumeStepDb = root.shippedDefaults.volumeStepDb;
                        root.cfg_startupVolumeDb = root.shippedDefaults.startupVolumeDb;
                        // Phase 8.3.0: widen the hard limit to dbRangeMax
                        // *first* - a lone extra write, not just reordering
                        // the two lines below - before touching either
                        // limit toward its real shipped default. Each of
                        // the three writes below is individually valid
                        // against whatever the other one currently holds
                        // (dbRangeMax is >= every reachable floor; the new
                        // floorDefault is < dbRangeMax; the new
                        // hardLimitDefault is > the new floorDefault), so
                        // healLimitOrdering() above - which reacts to every
                        // single write via onCfg_*Changed, not just the
                        // final pair - never sees a transient invalid pair
                        // partway through and self-heals over one of these
                        // three intended values. Without this widen step, a
                        // prior pair near the opposite extreme (e.g. floor
                        // -90/hardLimit -89) sets floorDb -45 first, which
                        // is >= the still-stale hardLimit -89, triggers a
                        // self-heal to -40/-39 mid-click, and the final
                        // hardLimitDb write below then leaves floorDb at
                        // -40 instead of the intended -45 - caught by
                        // tracing exactly this sequence, not observed live.
                        root.cfg_hardLimitDb = root.dbRangeMax;
                        root.cfg_volumeFloorDb = root.shippedDefaults.volumeFloorDb;
                        root.cfg_hardLimitDb = root.shippedDefaults.hardLimitDb;
                    }
                }
            }
        }
    }
}
