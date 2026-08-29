// Phase 4.0: centralizes the copper/graphite palette + custom font access
// ported 1:1 from design/mockups/devialet_tray_flyout_mockup.html's :root
// CSS custom properties, so FullRepresentation.qml doesn't repeat hex
// literals throughout. Plain QtObject (not `pragma Singleton`) - this
// KPackage has no qmldir/module registration set up for a true singleton,
// and a single `Theme { id: theme }` instance shared within
// FullRepresentation.qml is all that's needed (only one representation is
// ever shown at a time for this plasmoid's popup).
//
// Font loading: font files live at contents/fonts/ (NOT design/font/,
// which is a source/reference-only location outside the KPackage payload -
// kpackagetool6 installs only what's under plasmoid/, confirmed via
// CLAUDE.md's Repository Layout and by finding real precedent, not
// guessed: org.kde.plasma.advanced-weather-widget ships
// contents/fonts/weathericons-regular-webfont.ttf and loads it from
// contents/ui/ via `FontLoader { source: Qt.resolvedUrl("../fonts/...") }`
// - same convention followed here). Confirmed live (qml6, this machine):
// each weight-variant file reports the SAME `font.family` string (e.g.
// all four Space Grotesk files report family "Space Grotesk") with
// correctly distinct `font.weight` (400/500/600/700) - so loading every
// weight file registers it in Qt's font database under one shared family
// name, and plain `font.family: theme.fontDisplay; font.weight:
// Font.DemiBold` (etc.) correctly selects the matching static face -
// standard Qt font-database weight matching, not something this file
// needs to hand-roll.
import QtQuick

QtObject {
    id: theme

    // ---- Palette (design/mockups/devialet_tray_flyout_mockup.html :root) ----
    readonly property color bg: "#0e0e10"
    readonly property color surface: "#1a1a1d"
    readonly property color surface2: "#222225"
    readonly property color surface3: "#2a2a2e"
    readonly property color copper: "#c17f4e"
    readonly property color copperBright: "#e3a06a"
    readonly property color copperDim: "#8a5c39"
    readonly property color text: "#f2f0ec"
    readonly property color textDim: "#9a9a9f"
    readonly property color textFaint: "#5c5c60"
    readonly property color divider: Qt.rgba(1, 1, 1, 0.08)
    readonly property color danger: "#b5544a"
    readonly property color dangerBright: "#d17165"
    readonly property color success: "#5fa374"
    readonly property color successBright: "#7bc796"
    readonly property color warning: "#a3813a"
    readonly property color warningBright: "#e0b563"

    // Flyout panel gradient + blur-enabled tint, from .flyout /
    // .flyout.blur-enabled in the mockup - see FullRepresentation.qml's
    // root background for how this is layered on top of Plasma's own
    // (genuinely blurred) Dialog background rather than replacing it.
    readonly property color panelGradientTop: Qt.rgba(23 / 255, 23 / 255, 26 / 255, 0.82)
    readonly property color panelGradientBottom: Qt.rgba(18 / 255, 18 / 255, 20 / 255, 0.82)

    // ---- Fonts ----
    // One FontLoader per weight actually used in the mockup - matches the
    // exact weight set Google Fonts is asked for there (Space Grotesk
    // 400/500/600/700, JetBrains Mono 400/500/600), which is exactly the
    // set of files present in contents/fonts/, confirmed by listing them.
    readonly property FontLoader _sgRegular: FontLoader { source: Qt.resolvedUrl("../fonts/space_grotesk_regular.ttf") }
    readonly property FontLoader _sgMedium: FontLoader { source: Qt.resolvedUrl("../fonts/space_grotesk_medium.ttf") }
    readonly property FontLoader _sgSemibold: FontLoader { source: Qt.resolvedUrl("../fonts/space_grotesk_semibold.ttf") }
    readonly property FontLoader _sgBold: FontLoader { source: Qt.resolvedUrl("../fonts/space_grotesk_bold.ttf") }
    readonly property FontLoader _jbRegular: FontLoader { source: Qt.resolvedUrl("../fonts/jetbrains_mono_regular.ttf") }
    readonly property FontLoader _jbMedium: FontLoader { source: Qt.resolvedUrl("../fonts/jetbrains_mono_medium.ttf") }
    readonly property FontLoader _jbSemibold: FontLoader { source: Qt.resolvedUrl("../fonts/jetbrains_mono_semibold.ttf") }

    // Family name strings, available once at least one weight of each has
    // loaded (all weights of the same family report the same name - see
    // header comment). Falls back to "" (Qt's default UI font) while
    // loading rather than showing blank/broken text - matches the
    // guarded-access idiom found in the real weather-widget precedent
    // (`loader.status === FontLoader.Ready ? loader.font.family : ""`).
    readonly property string fontDisplay: theme._sgRegular.status === FontLoader.Ready ? theme._sgRegular.font.family : ""
    readonly property string fontMono: theme._jbRegular.status === FontLoader.Ready ? theme._jbRegular.font.family : ""

    // The mockup's --font-body (Inter, via Google Fonts) has no bundled
    // font file in this repo (only Space Grotesk/JetBrains Mono are
    // shipped at design/font/) - deliberately not fetched here (the task
    // was to use the files already in the repo, not source new ones).
    // Body text that the mockup styles with --font-body falls back to
    // Plasma's own system UI font instead (leaving font.family unset).
    // Flagging this as a deliberate, documented substitution, not a
    // silent gap.

    // ---- Spacing/sizing constants reused across the restyle ----
    readonly property int panelWidth: 300
    readonly property int radiusLg: 16
    readonly property int radiusMd: 11
    readonly property int radiusSm: 8
}
