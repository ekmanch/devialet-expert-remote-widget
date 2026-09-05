// Phase 7.9.0 spike - the compositor half of "clicked elsewhere": hand
// keyboard focus/activation to another window (first a normal app window,
// else the desktop). This is what a real click on another window or on
// the wallpaper does at the compositor level; Dialog::focusOutEvent()
// then decides whether to hide.
const wins = workspace.windowList();
let target = null;
for (const w of wins) {
    if (w.normalWindow && !w.minimized && w.resourceClass.indexOf("plasmashell") < 0 && w.caption !== "DialogSpike") { target = w; break; }
}
if (!target) { for (const w of wins) { if (w.desktopWindow) { target = w; break; } } }
if (target) {
    workspace.activeWindow = target;
    print("[SpikeKWin] " + JSON.stringify({type: "activated", caption: target.caption, cls: target.resourceClass, normal: target.normalWindow, desktop: target.desktopWindow}));
} else {
    print("[SpikeKWin] " + JSON.stringify({type: "activated", error: "no target window"}));
}
