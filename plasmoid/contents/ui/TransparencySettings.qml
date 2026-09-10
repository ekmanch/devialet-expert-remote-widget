// Single shared owner of the Appearance section's transparency setting
// (transparencyEnabled + transparencyPercent from main.xml), resolved once
// into the alpha every translucent surface paints with - the flyout's panel
// tint (FlyoutContent.qml), the OSD toast (VolumeToast.qml) and the hover
// tooltip (VolumeHoverTooltip.qml). Phase 9.0.0 design; wired in 9.1.0/9.2.0.
// Phase 9.1.1 adds two more computed alphas: controlAlpha (interactive
// chrome - buttons, source chip, closed source row) and overlayAlpha
// (the AmpListOverlay/SourceListOverlay dropdown cards) - see each
// property's own comment. Revised same-day after the first controlAlpha
// formula (a flat floor) was rejected live for an enormous panel/chrome
// gap - see controlAlpha's own comment for the compositing-corrected
// replacement, and TODO.md's Phase 9.1.1-revision entries for the full
// history of both formulas.
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

    // Phase 9.1.1 REVISION 4: interactive chrome (volume +/- buttons,
    // mute/power buttons, the source row, and the current-source chip -
    // NOT the overlay dropdown cards, see overlayAlpha below) targets a
    // FRACTION of the remaining gap to full opacity, not a flat +N-point
    // EFFECTIVE offset - the previous ("REVISION") formula had a real
    // bug, not just a tuning issue: `Math.min(1.0, alpha +
    // controlOffsetTarget)` clamps to exactly 1.0 once alpha >= 1 -
    // controlOffsetTarget (0.90 at controlOffsetTarget=0.10), which
    // forces the inverse-solved controlAlpha to ALSO be exactly 1.0 for
    // the entire panel range 90-100% - buttons rendered as fully solid,
    // unchanging pixels while the panel itself kept visibly changing
    // right up to 100%. Confirmed both mathematically (a standalone
    // computation of the old formula across panel 75-100% showed
    // controlAlpha flat at 1.0000 from panel=0.90 onward, every single
    // step) and live (screenshots at panel 75/85/90/94/100%: 75% and
    // 100% looked correct, everything between looked visibly "off",
    // worst in the high-80s/low-90s - exactly the plateau's span).
    //
    // Fix: targetEffective = panelAlpha + (1 - panelAlpha) * k for a
    // fraction k (this file's controlAlphaK) - closes a FRACTION of the
    // remaining gap to 1.0, not a fixed number of points, so
    // targetEffective is strictly < 1.0 whenever panelAlpha is (for any
    // k < 1) and can never plateau or need clamping. Same compositing-
    // correction inverse as before (effectiveOpacity = 1 - (1 -
    // panelAlpha) * (1 - chromeAlpha), solved for chromeAlpha given the
    // target) - but for THIS specific target shape the algebra collapses
    // to an exact constant:
    //   1 - targetEffective = 1 - panelAlpha - (1-panelAlpha)*k
    //                        = (1-panelAlpha)*(1-k)
    //   controlAlpha = 1 - (1-targetEffective)/(1-panelAlpha)
    //                = 1 - (1-k) = k
    // i.e. painting chrome at a flat raw alpha k and letting Porter-Duff
    // compositing do the rest IS the inverse-corrected solution for a
    // proportional-gap target - verified numerically (a standalone
    // computation confirmed controlAlpha comes out to exactly k at every
    // panel value tested, 0 through 0.99) before relying on it. Written
    // as the closed form directly (not the general divide-based inverse)
    // for two reasons: it's what the algebra actually reduces to, and
    // the general form divides by (1-panelAlpha), which -> 0 as
    // panelAlpha -> 1 and is a real (if usually harmless) source of
    // floating-point noise near the top of the range - exactly where
    // the previous formula's bug lived, so avoiding that division
    // entirely here is deliberate, not just a simplification.
    //
    // k chosen live (Phase 9.1.1 REVISION 4 sweep, TODO.md): candidates
    // 0.3/0.4/0.5 compared at panel 50% plus a fine ~3%-step sweep across
    // 75-100% (the exact range the old bug broke) confirmed smooth,
    // continuously-changing effective opacity with no plateau at every
    // tested k - the choice among them is a real aesthetic trade-off
    // (low k: subtle everywhere, including at low panel opacity where
    // more standout was wanted; high k: closer to the old flat-offset
    // feel, more standout at low panel, less separation-per-point-of-
    // panel-change near the very top), not a bug to be tuned away.
    // Revision 5 picked 0.3; Revision 6 (owner, live): the top end
    // (panel ~70%+) already looked right at k=0.3, the problem was
    // specifically the low end - k*(1-panelAlpha) is a ~30pt gap at
    // panel=0%, too large for an almost-invisible panel. Since the gap
    // shrinks proportionally with k at every panel value (not two
    // problems needing different curve shapes), lowering k alone fixes
    // the low end and only makes the already-fine top end more subtle
    // still. 0.1 sets the panel=0% gap to exactly 10pt
    // (targetEffective = panelAlpha + (1-panelAlpha)*k reduces to
    // targetEffective = k when panelAlpha = 0), tapering smoothly from
    // there - the owner's explicit target.
    readonly property real controlAlphaK: 0.1
    readonly property real controlAlpha: root.controlAlphaK

    // Same reactive-function idiom as withAlpha() above.
    function withControlAlpha(c) {
        return Qt.rgba(c.r, c.g, c.b, root.controlAlpha);
    }

    // Phase 9.1.1 REVISION 3: the AmpListOverlay/SourceListOverlay
    // dropdown card BACKGROUNDS specifically (not controlAlpha's targets
    // above) - a raw, uncorrected formula, decided independently and
    // deliberately NOT reusing controlAlpha's compositing correction.
    // The two chrome problems point in opposite directions: controlAlpha
    // was fixing values that read as unexpectedly darker/more opaque
    // than intended (real, sweep-confirmed overshoot - see its own
    // comment); this property is chasing a perceptual "clearly stands
    // apart from the panel" legibility margin for multi-row list text,
    // not a precise proportional match to a computed effective-opacity
    // number - so no inverse-compositing step here, the raw value below
    // IS the alpha painted.
    //
    // Plain Math.max(alpha, floor) (this property's own Revision 2 form)
    // had a real structural flaw: once panelAlpha reaches the floor, the
    // list card equals the panel EXACTLY (Math.max collapses to alpha
    // itself) - no separation at all above that point, the opposite of
    // "clearly stands apart." Math.max(0.70, Math.min(1.0, alpha + 0.20))
    // fixes this by construction: the +0.20 term keeps pushing the list
    // past the floor as the panel gets more opaque, rather than
    // flatlining into equality with it - the two can only re-converge
    // once alpha itself is within 0.20 of 1.0 (i.e. panel >= 80%), where
    // both are already near-opaque and the separation matters far less.
    readonly property real overlayAlphaFloor: 0.70
    readonly property real overlayAlphaOffset: 0.20
    readonly property real overlayAlpha: Math.max(root.overlayAlphaFloor, Math.min(1.0, root.alpha + root.overlayAlphaOffset))

    function withOverlayAlpha(c) {
        return Qt.rgba(c.r, c.g, c.b, root.overlayAlpha);
    }
}
