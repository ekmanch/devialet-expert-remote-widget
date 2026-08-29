// Phase 4.4.0: our "General" ConfigDialog page - the brand header only
// this phase (icon mark + "Devialet Expert Remote" / "Widget Settings"),
// per design/mockups/devialet_config_dialog_mockup_v3.html's .brand-header.
// All actual settings rows (Appearance/Volume/Amplifiers/Startup) are
// Phase 4.4.1's job, not this one.
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
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import "../ui" as Ui

KCM.SimpleKCM {
    id: root

    readonly property Ui.Theme theme: Ui.Theme {}

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
}
