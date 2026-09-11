// Phase 10.1.3: the ONE place that knows how installed sound themes are
// found, named, and resolved to the file devialet-chime plays. Moved here
// verbatim from ConfigGeneral.qml (Phase 10.1.1 wrote it there for the
// theme dropdown / "System theme" status line / Preview) so the widget
// side can resolve a pinned theme with the very same code the dialog
// lists it with: main.qml instantiates one for VolumeSettings.qml's
// chimePinnedThemePath, ConfigGeneral.qml instantiates its own. Per-file
// instantiation like Theme.qml, not the root-anchored/forwarded shape of
// VolumeSettings: this is derived from disk, there is no live state that
// could diverge between the two instances.
//
// Plain QtObject (no qmldir/singleton in this KPackage) holding its
// P5Support.DataSource as an object-typed property, the way Theme.qml
// holds its FontLoaders. Deliberately does not import
// org.kde.plasma.plasmoid (see VolumeSettings.qml's header for why bare
// QtObject files here never do).
import QtQuick
import org.kde.plasma.plasma5support as P5Support

QtObject {
    id: root

    // [{id, name, path}] - every installed sound theme that actually has
    // the one file the chime plays (see scanCommand below). id = the
    // sound-theme directory name (what kdeglobals stores, what
    // devialet-chime reads, what main.xml chimePinnedTheme persists);
    // name = the display name System Settings shows.
    property var themes: []
    // Raw kdeglobals [Sounds] Theme value; "" until read, or when unset.
    property string desktopTheme: ""

    // Theme enumeration. KDE's own Sound Theme KCM does this in C++
    // (plasma-workspace kcms/soundtheme/kcm_soundtheme.cpp, loadThemes()
    // lines 128-177: every readable subdirectory of every
    // QStandardPaths GenericDataLocation "sounds" dir, first occurrence
    // of an id wins, kept only if index.theme has a [Sound Theme] group)
    // and ships no QML for it, and no KConfig/theme-listing QML type
    // exists for a plasmoid on this system (org.kde.config exports only
    // KAuthorized and WindowStateSaver; org.kde.kirigamiaddons.sounds
    // lists sounds *within* one theme). So: a one-shot /bin/sh walk of
    // the same directories in the same precedence order
    // ($XDG_DATA_HOME, then each $XDG_DATA_DIRS entry), emitting
    // "id<TAB>name<TAB>path" per theme, deduped by id (first wins).
    // Two filters, both deliberate: an index.theme must exist (the
    // KCM's own validity rule, which drops e.g. /usr/share/sounds/alsa),
    // AND stereo/audio-volume-change.oga must exist - the exact file
    // devialet-chime's theme.rs EVENT_FILE plays, with no Inherits=
    // walk, just like theme.rs. A theme that only inherits the sound
    // would list in KDE's KCM but could never be played by the chime, so
    // it's excluded here. `name` is index.theme's Name= via kreadconfig6
    // (which applies the same localized Name[xx]= lookup as the KCM's
    // KConfigGroup::readEntry, kcm_soundtheme.cpp:410), defaulting to
    // the raw id when Name= is missing - nameFor()'s fallback
    // (kcm_soundtheme.cpp:113-120), so a third-party theme without a
    // Name= still lists, under its directory id. Verified under `sh -c`
    // on this box: exactly ocean and freedesktop, alsa dropped.
    readonly property string scanCommand:
        "IFS=:; for base in \"${XDG_DATA_HOME:-$HOME/.local/share}\" ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do "
        + "for dir in \"$base\"/sounds/*/; do dir=${dir%/}; id=${dir##*/}; "
        + "[ -f \"$dir/index.theme\" ] || continue; "
        + "[ -f \"$dir/stereo/audio-volume-change.oga\" ] || continue; "
        + "name=$(kreadconfig6 --file \"$dir/index.theme\" --group \"Sound Theme\" --key Name --default \"$id\"); "
        + "printf '%s\\t%s\\t%s\\n' \"$id\" \"$name\" \"$dir/stereo/audio-volume-change.oga\"; "
        + "done; done | awk -F'\\t' '!seen[$1]++'"

    // The desktop's configured sound theme - the "System theme" status
    // line's live value. Same key devialet-chime's theme.rs parses by
    // hand (kdeglobals [Sounds] Theme); read here via kreadconfig6
    // through the executable engine, since no KConfig QML reader exists
    // (see above). Empty output = key unset.
    readonly property string desktopThemeCommand:
        "kreadconfig6 --file kdeglobals --group Sounds --key Theme"

    function scan() {
        root.probe.connectSource(root.scanCommand);
    }

    function refreshDesktopTheme() {
        root.probe.connectSource(root.desktopThemeCommand);
    }

    function applyScan(stdout) {
        const themes = [];
        const lines = String(stdout || "").split("\n");
        for (let i = 0; i < lines.length; i++) {
            const fields = lines[i].split("\t");
            if (fields.length < 3 || fields[0] === "") continue;
            const id = fields[0];
            let name = fields[1] || id;
            // HARDCODED SPECIAL CASE, copied from KDE, not a rule of the
            // sound-theme spec: KDE's own Sound Theme KCM overrides this
            // one theme's display name because its index.theme says
            // Name=Default (plasma-workspace, branch Plasma/6.7,
            // kcms/soundtheme/kcm_soundtheme.cpp:71 `FALLBACK_THEME =
            // "freedesktop"` and :153-158, quoting its comment: "The
            // fallback "freedesktop" theme identifies itself as
            // "Default" with no comment nor translations which can get
            // confused with the system's default theme" -> i18nc("Name
            // of the fallback \"freedesktop\" sound theme",
            // "FreeDesktop")). Confirmed present in the installed
            // kcm_soundtheme.so via `strings`. Reproduced so this
            // dropdown shows the same label System Settings does;
            // every other theme's name comes from its index.theme.
            if (id === "freedesktop") name = "FreeDesktop";
            themes.push({ id: id, name: name, path: fields[2] });
        }
        // kcm_soundtheme.cpp:163-173 - sort by display name, keep the
        // freedesktop fallback last.
        themes.sort(function (a, b) {
            if (a.id === "freedesktop") return 1;
            if (b.id === "freedesktop") return -1;
            return a.name.localeCompare(b.name);
        });
        root.themes = themes;
        // Phase 10.1.3: no "unknown pinned id -> snap to the first entry"
        // correction any more (10.1.1 had one on its local state). The
        // pinned id is a persisted cfg_ value now, and rewriting it on
        // every scan would dirty the dialog's Apply button on open
        // whenever the stored theme isn't installed. An unknown id just
        // shows as its raw id (nameFor) and resolves to "" (pathFor), so
        // Preview disables and maybeChime() skips with a warning.
    }

    function entry(id) {
        for (let i = 0; i < root.themes.length; i++) {
            if (root.themes[i].id === id) return root.themes[i];
        }
        return null;
    }

    // nameFor() (kcm_soundtheme.cpp:113-120): display name, or the raw
    // id for anything not in the list.
    function nameFor(id) {
        const e = root.entry(id);
        return e ? e.name : id;
    }

    // The theme's audio-volume-change.oga, or "" when the id isn't an
    // installed theme that has one.
    function pathFor(id) {
        const e = root.entry(id);
        return e ? e.path : "";
    }

    // Port of devialet-chime's theme.rs resolve(): the configured theme,
    // then ocean, then freedesktop - first one whose audio-volume-
    // change.oga exists (themes only holds those). null when none.
    function resolveFollow() {
        const order = [root.desktopTheme !== "" ? root.desktopTheme : "ocean", "ocean", "freedesktop"];
        for (let i = 0; i < order.length; i++) {
            const e = root.entry(order[i]);
            if (e) return e;
        }
        return null;
    }

    function followDisplayName() {
        const e = root.resolveFollow();
        if (e) return e.name;
        return root.desktopTheme !== "" ? root.desktopTheme : "ocean";
    }

    // Single-quote a path for the executable engine's `/bin/sh -c`
    // (CLAUDE.md, "devialet-ctl on PATH"). The one quoting helper for
    // both the dialog's Preview and maybeChime()'s --file argument.
    function shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    // One-shot probes (theme scan + kdeglobals read), dispatched on the
    // source string. Fire-once-then-detach idiom from contents/ui/'s
    // devialet-ctl DataSources.
    readonly property P5Support.DataSource probe: P5Support.DataSource {
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            const code = data["exit code"];
            if (code !== 0) {
                console.log("[SoundThemes] probe failed - exit code:", code, "stderr:", data["stderr"], "command:", source);
            }
            if (source === root.scanCommand) {
                root.applyScan(data["stdout"]);
            } else if (source === root.desktopThemeCommand) {
                root.desktopTheme = String(data["stdout"] || "").trim();
            }
            disconnectSource(source);
        }
    }
}
