// Phase 2: minimal working skeleton, proving the plasmoid loads in the
// system tray and the D-Bus/executable-engine plumbing works end-to-end.
// No visual design from the mockup yet - see CLAUDE.md's phased roadmap.

pragma ComponentBehavior: Bound

import QtQuick
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    // Placeholder icon (confirmed present in the installed Breeze icon
    // theme, not guessed) - a proper themed icon is a later-phase concern.
    Plasmoid.icon: "audio-speakers-symbolic"

    compactRepresentation: CompactRepresentation {
        plasmoidItem: root
    }

    fullRepresentation: FullRepresentation {}
}
