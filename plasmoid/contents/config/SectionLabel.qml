// Phase 4.4.1: reusable section header, matching the mockup's
// .kcm-section-label (font-display, uppercase, letter-spaced, copperBright,
// with a divider line filling the remaining width via ::after) - built
// as a RowLayout(label, divider-line) since QML has no ::after equivalent.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import "../ui" as Ui

RowLayout {
    id: root

    property string text: ""
    // Mockup's .kcm-section-label.first has margin-top:2px instead of 28px
    // (the very first section label on the page, right under the brand
    // header) - everything else uses the default top margin.
    property bool first: false

    readonly property Ui.Theme theme: Ui.Theme {}

    Layout.fillWidth: true
    Layout.topMargin: root.first ? 2 : 28
    Layout.bottomMargin: 6
    spacing: 8

    Label {
        text: root.text
        font.family: root.theme.fontDisplay
        font.weight: Font.DemiBold
        font.pixelSize: 11
        font.letterSpacing: 1.4
        font.capitalization: Font.AllUppercase
        color: root.theme.copperBright
    }

    Rectangle {
        Layout.fillWidth: true
        height: 1
        color: root.theme.divider
    }
}
