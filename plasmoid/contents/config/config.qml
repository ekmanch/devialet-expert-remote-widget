// Phase 4.4.0: adds our own "General" category to the ConfigDialog that
// Plasma's shell already auto-provides for every installed applet (gear
// icon -> Keyboard Shortcuts + About, confirmed live in Phase 4.2.1,
// before this file ever existed). This does NOT create the dialog or wire
// up the gear icon's action - both already exist and already work.
//
// Confirmed by reading the shell's own source
// (/usr/share/plasma/shells/org.kde.plasma.desktop/contents/configuration/
// AppletConfiguration.qml), not assumed: Keyboard Shortcuts and About are
// built from two separate Repeaters, entirely independent of whatever
// ConfigModel this file provides - there is no mechanism by which adding
// a category here could suppress or replace them. For a non-containment
// applet (this one), the sidebar order is: [our own categories] ->
// Keyboard Shortcuts -> About, always. Also confirmed: no metadata.json
// key is involved at all - Plasma's KPackage structure auto-detects
// contents/config/config.qml purely by its fixed conventional path (three
// real shipped Plasma 6 applets checked - luisbocanegra.panel.colorizer,
// org.kde.desktopcontainment, org.kde.plasma.systemmonitor - none
// reference config.qml in metadata.json).
//
// One live-verifiable side effect of this file existing at all: the same
// shell source's open()-on-launch logic defaults to the applet's own
// first category once configModel is non-empty, rather than falling back
// to Keyboard Shortcuts the way it does today with no config.qml present.
//
// ROOT CAUSE of a long live-debugging session, found by reading several
// other real, third-party KPackage plasmoids' own config.qml comments
// (installed alongside this one under ~/.local/share/plasma/plasmoids/) -
// not documented in any KDE reference found, but independently stated by
// multiple unrelated plasmoid authors and confirmed live here:
// `ConfigCategory.source` resolves relative to `contents/ui/` (the
// plasmoid's main QML root), NOT relative to config.qml's own location in
// `contents/config/` - regardless of what value is assigned (a bare
// string, or an explicit Qt.resolvedUrl() call made from inside
// config.qml, which resolves relative to config.qml's own file and so
// produces the SAME wrong path either way). A bare `"ConfigGeneral.qml"`
// or `Qt.resolvedUrl("ConfigGeneral.qml")` here both pointed at a
// nonexistent `contents/ui/ConfigGeneral.qml`, which is why the real
// ConfigGeneral.qml (living in `contents/config/`, alongside config.qml/
// main.xml per this project's Repository Layout) never loaded - PageRow
// received an unloadable/empty component and failed deep in Kirigami
// ("Could not convert argument 1 ... to QQuickItem*"), which then broke
// page navigation for the rest of that dialog session. `../config/` is
// the fix - it's the same "prefix to reach config pages living
// elsewhere" technique real precedents use (e.g.
// com.github.tilorenz.compact_pager's `"config/ConfigGeneral.qml"` reaches
// its own `contents/ui/config/`), just adapted for this project's layout
// where `config/` is a sibling of `ui/`, not nested under it.

import org.kde.plasma.configuration

// Phase 4.4.0.1: General's own copper glow-dot icon, replacing the
// generic "audio-speakers-symbolic" fallback. Keyboard Shortcuts/About's
// icons ("preferences-desktop-keyboard"/"help-about") are hardcoded
// inline in the shell's own AppletConfiguration.qml (a separate
// KPackage, org.kde.plasma.desktop) - confirmed by reading that file
// again, no property/hook exists to override them from here, so a
// matching monochrome set isn't possible; the colored glow-dot (matching
// About's own fixed colored icon) is the right call, not a mismatched
// half-measure.
//
// ConfigCategory.icon feeds Kirigami.Icon.source (confirmed by tracing
// ConfigCategoryDelegate.qml, the real sidebar delegate) - the same
// mechanism Plasmoid.icon already uses, so an arbitrary resolvable path
// works here too, unlike metadata.json's KPlugin.Icon (Phase 4.1 finding:
// QIcon::fromTheme()-only). Reuses the exact SVG already bundled for the
// panel icon (plasmoid/contents/icons/devialet_icon_glow_dot.svg, Phase
// 4.2.5) rather than duplicating the asset.
//
// A bare relative string (`icon: "../icons/devialet_icon_glow_dot.svg"`)
// rendered as a broken-image placeholder live, confirmed by testing -
// unlike `source:` (a QUrl-typed property, auto-resolved against
// config.qml's own base URL at assignment time, per this file's ROOT
// CAUSE comment above), `icon:` appears to be a plain string passed
// through unresolved to ConfigCategoryDelegate.qml's `Kirigami.Icon {
// source: model.icon }` - and Kirigami.Icon resolves a relative source
// against ConfigCategoryDelegate.qml's OWN location (a different
// KPackage, the shell's org.kde.plasma.desktop), not ours. Fixed with an
// explicit `Qt.resolvedUrl()` call made here, inside config.qml - a
// genuinely absolute URL once computed, so it needs no further
// resolution regardless of which file later reads it.

import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("General")
        icon: Qt.resolvedUrl("../icons/devialet_icon_glow_dot.svg")
        source: "../config/ConfigGeneral.qml"
    }
}
