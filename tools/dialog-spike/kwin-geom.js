// Phase 7.9.0 spike - dump KWin's view of the spike window (and any of this
// applet's popups) and the screen. Output lands in kwin_wayland's journal.
const wins = workspace.windowList();
print("[SpikeKWin] " + JSON.stringify({type: "screen", area: workspace.clientArea(KWin.FullScreenArea, workspace.activeScreen, workspace.currentDesktop),
    work: workspace.clientArea(KWin.WorkArea, workspace.activeScreen, workspace.currentDesktop)}));
for (const w of wins) {
    const g = w.frameGeometry;
    const isSpike = w.caption === "DialogSpike";
    const isShell = w.resourceClass.indexOf("plasmashell") >= 0 && (w.popupWindow || w.tooltip || w.dialog || w.appletPopup || w.notification || w.onScreenDisplay);
    if (isSpike || isShell) {
        print("[SpikeKWin] " + JSON.stringify({type: "win", caption: w.caption, cls: w.resourceClass,
            x: g.x, y: g.y, w: g.width, h: g.height, active: w.active, popup: w.popupWindow, tooltip: w.tooltip,
            appletPopup: w.appletPopup, dialog: w.dialog, minSize: [w.minSize.width, w.minSize.height],
            maxSize: [w.maxSize.width, w.maxSize.height], resizeable: w.resizeable, transient: w.transient,
            skipTaskbar: w.skipTaskbar, keepAbove: w.keepAbove}));
    }
}
print("[SpikeKWin] " + JSON.stringify({type: "active", caption: workspace.activeWindow ? workspace.activeWindow.caption : null,
    cls: workspace.activeWindow ? workspace.activeWindow.resourceClass : null}));
