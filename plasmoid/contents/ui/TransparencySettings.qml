// Single shared owner of the Appearance section's transparency setting
// (transparencyEnabled + transparencyPercent from main.xml), resolved once
// into the alpha every translucent surface paints with - the flyout's panel
// tint (FlyoutContent.qml), the OSD toast (VolumeToast.qml) and the hover
// tooltip (VolumeHoverTooltip.qml). Phase 9.0.0 design; wired in 9.1.0/9.2.0.
//
// Same shape as VolumeSettings.qml / PendingAmpState.qml: a plain QtObject
// (no `pragma Singleton` - no qmldir exists anywhere under contents/ui/),
// instantiated exactly once in main.qml with its two inputs bound
// declaratively to Plasmoid.configuration there (main.qml is proven to have
// that context property; a bare QtObject file is not - see VolumeSettings.
// qml's header), and forwarded down via `required property` through
// CompactRepresentation.qml -> FlyoutPopup.qml -> FlyoutContent.qml, and
// from CompactRepresentation.qml straight into VolumeToast/VolumeHoverTooltip
// (both instantiated there). See CLAUDE.md's "Shared cross-view state" note.
//
// Why the alpha lives here and not in Theme.qml: Theme.qml is deliberately
// re-instantiated per consuming file (four sites, including the ConfigDialog
// page ConfigGeneral.qml, a separate QML tree with no access to main.qml's
// root-anchored objects). A `required property` on Theme.qml would break
// that page's `Ui.Theme {}`; a non-required default would silently let one
// surface fall back to a different alpha than the others - the exact
// divergence this object exists to rule out (owner decision, 2026-09-05:
// all three surfaces land on the same alpha). Theme.qml therefore keeps only
// the opaque base tint colours; this object supplies the alpha.
//
// percent is OPACITY, not transparency (owner decision, Phase 9.0.0):
// alpha = percent / 100, so 94 reproduces the OSD/tooltip's historical 0.94
// and 100 is fully opaque. `enabled == false` is exactly 1.0 - not a high
// value - which is what Phase 9.3.0's "off is truly opaque" check measures.
import QtQuick

QtObject {
    id: root

    required property bool enabled
    required property int percent

    // Clamped defensively: kcfg <min>/<max> would only guard a hand-edited
    // config file, not the value ConfigGeneral.qml's 0..100 slider writes -
    // but a stray out-of-range value must never produce an invalid colour.
    readonly property real alpha: root.enabled ? Math.min(1.0, Math.max(0.0, root.percent / 100)) : 1.0

    // Reads root.alpha live on every call (never a cached local), so a
    // GradientStop bound as `color: transparencySettings.withAlpha(theme.x)`
    // stays a normal reactive QML binding - a ConfigDialog Apply/OK
    // re-evaluates every consumer immediately, no reload. Same idiom as
    // VolumeSettings.clamp(). Only the alpha channel is replaced; RGB stays
    // the caller's Theme.qml colour.
    function withAlpha(c) {
        return Qt.rgba(c.r, c.g, c.b, root.alpha);
    }
}
