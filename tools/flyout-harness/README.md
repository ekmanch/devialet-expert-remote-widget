# Flyout verification harness (Phase 7.2.0)

The §5 verification suite from the flyout-rebuild investigation document
(`context-on-spike-flyout-dialog-rebuild-b-quirky-wand.md`), built as a
per-phase gate for every content phase from 7.3.0 onward. Two halves:

- **Coordinate half** — `plasmoid/contents/ui/LayoutProbe.qml` logs every
  item's window/global x/y, size, visibility and text for each state as JSON
  lines via `console.log` → journald; the driver reads them back and diffs
  them numerically. This is what catches a sub-pixel shift on an element
  nobody was looking at (the tooltip's three-round history, §2).
- **Screenshot half** — `spectacle -b -n -f` per state, cropped to the
  popup, pixel-diffed exactly (Phase 4.5.3's method), with a same-state
  control capture as the noise baseline.

No synthetic input is used anywhere. State is driven over D-Bus:
`fakeamp.py` impersonates the daemon on its real bus name and additionally
owns a control name the probe listens to (`PopupOpen`, `UiState` as a
JSON string, `StateId`/`Seq`, `SettleMs`). Opening the popup is `popup.visible = true`
from inside QML — the same statement the click handler runs.

## Preconditions

1. Just the normal reload workflow: `kpackagetool6 --type Plasma/Applet
   --upgrade plasmoid/` then `plasmashell --replace &` (CLAUDE.md's
   reload workflow) after any QML change. `main.qml`'s
   `appletPopupSpikeEnabled` flag no longer needs flipping (Phase 7.8.0
   Step A cutover) — the new flyout is unconditional now, so `LayoutProbe`
   is always live behind the harness's own bus name regardless of that
   flag's value. (Historical: before 7.8.0, this step was "flip
   `appletPopupSpikeEnabled: true`, reload, revert after" — kept here only
   as a note in case you're reading this against a pre-cutover checkout.)
2. Python 3 with PyGObject (`gi`), Pillow and numpy — all present on the
   dev machine via pacman; `spectacle` on PATH.
3. Keep hands off mouse and keyboard while a run is in progress: a hover
   on the panel icon shows the tooltip, a click elsewhere dismisses the
   popup (`hideOnWindowDeactivate`).
4. The real daemon may be running — `run` stops
   `devialet-remote-daemon.service` itself if it is active and restarts it
   on exit (including Ctrl-C). A *manually started* foreground daemon must
   be stopped by hand; the run refuses otherwise.

## Quick start

```sh
H=tools/flyout-harness/harness.py
python3 $H states --set full                 # list + count, no side effects
python3 $H run --set smoke                   # → tools/flyout-harness/runs/<stamp>/
python3 $H run --vary vol,mute               # Phase 7.4.0-style subset
python3 $H run --set full --noise-mask       # Phase 7.7.0 full gate (~438 states)
python3 $H run --set amp --settle-ms 1200    # settle-floor check, see below
python3 $H report tools/flyout-harness/runs/<stamp> [--expected expected.json]
python3 $H compare runs/<a> runs/<b>            # coordinate diff across two runs
```

Selection: `--set smoke|amp|volume-mute|power|source|full`, or `--vary
dim,dim` (others held at the base state `1auto-short / -40.0 / off / On /
short / closed`), plus `--fix dim=value` filters. Dimensions and values are
in `scenarios.py`; not-connected amp values (`0known`, `1none`, `2none`)
collapse vol/mute/pow/src to `-` because the daemon's None branch zeroes
them — those states carry no inner product.

## What `run` does

1. Stops the systemd daemon unit if active; verifies nobody owns
   `com.ekmanch.DevialetRemote`; owns it (and the control name) with
   `DO_NOT_QUEUE` — the fake can never take the name from a live daemon,
   and never sits queued to grab it later (checked against zbus 5.19's
   builder: the daemon requests with `DO_NOT_QUEUE`, no replacement flags).
2. Starts following `journalctl --user -f _COMM=plasmashell`.
3. Takes one popup-closed full-screen reference (`_closed_full.png`),
   sets `PopupOpen = true`.
4. Per state: sets all 13 `Amp1` properties (emitting `PropertiesChanged`
   one property per signal in the daemon's `emit_all()` order), sets
   `UiState`, bumps `Seq`. The probe waits `SettleMs`, then dumps. The
   driver asserts the probe's own `Amp1` snapshot (`AmpIp`, `VolumeDb`,
   `PowerState`) matches what it set — "state never reached the widget" is
   a hard error — then screenshots and crops to the popup's **mainItem
   rectangle** (window position + the root item's offset, × devicePixelRatio,
   `--pad` 0). Not the whole window: the theme frame's antialiased rounded
   corners and edges let the desktop behind the popup bleed into a capture
   (~150 differing pixels in an otherwise identical control pair), and the
   frame itself never changes with state. Override with `--crop x,y,w,h`
   in physical px if ever needed.
5. The first state is captured twice (`<id>__control`); `--noise-mask`
   does that for every state and excludes each state's self-differing
   pixels (caret blink, Booting pulse) from its pair diffs.
6. Closes the popup, releases the names, restarts the daemon unit if it
   was active, runs the analysis.

## Output (`runs/<stamp>/`)

| file | content |
|---|---|
| `states.json` | resolved states: id, dims, Amp1 props, UiState, capture ids |
| `run.json` | selection, settle, crop box + source, per-state timings, warnings |
| `coords/<id>.json` | probe dump: `begin` (window/mainItem geometry, dpr, Amp1 snapshot, UI warnings), `items[]`, `windows[]`, `end` |
| `shots/<id>.png` | cropped capture (`--keep-full` keeps `<id>.full.png`) |
| `report.md` / `summary.json` | analysis, human / machine |
| `diffs/*.png` | red-highlighted diff images for non-zero pairs |

Report sections: (1) control identity — coordinates must be identical,
pixel noise reported with bbox/row bands; (2) popup geometry per state —
more than one row means the whole popup resizes (§1 master finding), and
(Phase 7.7.0) every state's `mainItem` w/h must also equal its own
implicit w/h — a *stable-but-stuck* size (the AppletPopup popupWidth/
popupHeight KConfig collision — see Caveats) passes the "one row" check
but fails this one; (3) unexpected element moves on single-dimension
flips, grouped by element with Δx/Δy/Δw/Δh and text before/after;
(3b) moves matched by `expected.json`; (4) pixel diffs per pair;
(5) warnings. Exit code 1 = control unstable, 3 = popup size doesn't
match its own implicit size in some state, 2 = unexpected moves, 0 =
clean.

`expected.json` (optional, per phase): `[{"key": "<regex on key>", "dim":
"vol" | "*", "note": "dB value label legitimately changes width"}]`.

## House rules for content phases (7.3.0+)

- **Every anchored element gets a stable `objectName`.** Keys fall back
  to the structural path (`root/ColumnLayout[0]/Label[1]`), which shifts
  whenever siblings are inserted — the path is a fallback, not the
  contract.
- **QML-internal UI state is exposed as plain properties on one item**,
  and `FlyoutPopup.qml`'s probe points `uiTarget` at it. Phase 7.3.0:
  `ampListOpen` on the content root — the amp-list overlay binds to it
  internally (option (b) self-containment), so if the overlay is ever
  reverted to an in-flow list the harness hook is unchanged. A `UiState`
  key the target lacks is logged as a warning in `begin.uiWarnings` and in
  the report.
- **Re-measure the settle floor per phase.** 600 ms is a starting value
  (above the current flyout's 160/200 ms behaviours), not a fact. Run the
  phase's set at the default and at `--settle-ms 1200`; any coordinate
  that differs between the two sweeps (`harness.py compare a b`) means the
  layout had not landed at the shorter value. Record the measured floor in TODO.md — never copy it
  forward (the VolumeToast pin lesson).
- Nested popup windows (a `PlasmaCore.Dialog`/`AppletPopup` child of any
  item under `mainItem`) are logged with their own `window` record and
  walked; their `wx/wy` are relative to their own window.

## Caveats

- `spectacle` is run with `QT_QPA_PLATFORM=wayland` forced. From a
  non-interactive shell in this session it otherwise picks the xcb backend,
  and an XWayland grab of a Wayland session is a fully transparent image
  with exit code 0 (the first 7.2.0 smoke run produced blank crops this
  way). The harness fails hard on an all-transparent capture — but first
  retries the `spectacle` invocation up to 3 times (Phase 7.7.0, added
  after two real occurrences ~100 states apart during the full sweep, an
  intermittent compositor/spectacle timing race — screen-lock/screensaver
  activity during a run is one real-world trigger, confirmed live).

- Perpetual animations (Booting dot pulse 550 ms loop, spinner 700 ms) and
  the placeholder's blinking text caret can never pixel-match between two
  captures; the control capture surfaces that and `--noise-mask` masks
  it. Coordinates are unaffected.
- **Keep hands off the machine for the whole run, screensaver included.**
  Phase 7.7.0's full sweep hit `popup window is not visible - PopupOpen
  was not honoured` twice — real window-deactivation events (the user's
  own interaction, then their screensaver engaging), not a QML bug:
  `hideOnWindowDeactivate` is genuine `PopupPlasmaWindow` behavior, and
  anything that steals window activation during a run closes the popup
  out from under it. `run_capture()` retries once, explicitly forcing
  `PopupOpen=True` again before re-dumping (not just re-checking the same
  still-closed window) — recovers from a one-off dismissal, still fails
  hard if the popup won't reopen. If a run is long enough to risk the
  screen going idle, disable the screensaver/screen-lock first rather
  than relying on the retry to absorb repeated hits.
- **Popup size keys.** libplasma's `AppletPopup::hideEvent()` writes
  `popupWidth`/`popupHeight` into the applet's KConfig group on *every*
  close when `appletInterface` is set — no resize needed (read from
  appletpopup.cpp 6.7.4, confirmed empirically). Until Phase 7.8.0's
  cutover `FlyoutPopup` and the shell's real flyout share that group, and
  the real popup applies the keys when it is constructed, so a run would
  leave the real flyout truncated to the spike's size after the next
  plasmashell restart. `run` snapshots both keys for every instance of the
  applet before starting and restores them (or deletes them if they were
  absent) at teardown, logging both values; `run.json` records
  `size_keys_before`/`size_keys_restored`. Opening the spike popup by
  hand has the same effect — clean up with `kwriteconfig6 --delete`
  (group `[Containments][N][Applets][M][Configuration]`) afterwards.
- Full-screen captures (kept only with `--keep-full`, plus the one closed
  reference) contain the whole desktop; `runs/` is gitignored.
- `fakeamp.py --state <id> [--open] [--ui k=v]` runs the fake standalone
  for manual poking (real daemon stopped by hand first;
  `--list-states` prints ids). Restart the daemon yourself afterwards.
