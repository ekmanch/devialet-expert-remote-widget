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

ConfigModel {
    ConfigCategory {
        name: i18n("General")
        icon: "audio-speakers-symbolic" // matches metadata.json's KPlugin.Icon
        source: "../config/ConfigGeneral.qml"
    }
}
