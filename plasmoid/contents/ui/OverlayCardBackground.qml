// Phase 7.14.0 - the floating-card background shared by AmpListOverlay.qml
// and SourceListOverlay.qml (mockup v2 `.overlay-popup`: 13px radius, 1px
// rgba(255,255,255,0.1) border, #1e1e21 -> #19191c vertical gradient,
// soft drop shadow). One definition so the two cards can't drift apart.
//
// Kirigami.ShadowedRectangle is what qqc2-desktop-style's own Popup.qml
// uses for its background, so this adds no new dependency class. It has
// no gradient property, hence the inset child Rectangle carrying the
// gradient fill (radius one less than the outer so the two curves nest
// inside the 1px border). The shadow is drawn outside the item's own
// bounds by design - the Popup's Overlay parent doesn't clip, and both
// cards sit 16px inside the flyout so there is room for it.

import QtQuick
import org.kde.kirigami as Kirigami

Kirigami.ShadowedRectangle {
    id: card

    required property Theme theme
    // Phase 9.1.1 REVISION: overlay alpha (the card's own fill) - a
    // genuine floor, deliberately NOT controlAlpha's compositing-
    // corrected offset - see TransparencySettings.qml's overlayAlpha
    // comment for why list cards get their own, independent formula.
    // Layered on top of this card's own opaque-by-design mockup styling
    // (see this file's header comment) rather than replacing it - the
    // gradient/border/radius/shadow shape is unchanged, only the fill's
    // alpha now tracks the panel with a floor instead of always being
    // 1.0.
    required property TransparencySettings transparencySettings

    radius: card.theme.radiusOverlay
    color: card.transparencySettings.withOverlayAlpha(card.theme.overlayGradientTop)
    border.width: 1
    border.color: card.theme.overlayBorder
    // Approximates `box-shadow: 0 18px 44px -10px rgba(0,0,0,0.6)`.
    shadow.size: 24
    shadow.yOffset: 8
    shadow.xOffset: 0
    shadow.color: Qt.rgba(0, 0, 0, 0.5)

    Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: card.theme.radiusOverlay - 1
        antialiasing: true
        gradient: Gradient {
            GradientStop { position: 0.0; color: card.transparencySettings.withOverlayAlpha(card.theme.overlayGradientTop) }
            GradientStop { position: 1.0; color: card.transparencySettings.withOverlayAlpha(card.theme.overlayGradientBottom) }
        }
    }
}
