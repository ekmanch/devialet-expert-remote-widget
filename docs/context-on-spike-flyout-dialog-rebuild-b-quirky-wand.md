# Flyout Dialog Rebuild — Investigation & Design Document

## Context

TODO.md (2809-2846) already carries a "future investigation" item: rebuild
the flyout (`FullRepresentation.qml`) as a custom `PlasmaCore.Dialog`
instead of relying on the shell's managed expanded-representation popup
(currently backed by `PlasmaWindow`, which has no `NoBackground` option —
the same root constraint documented in CLAUDE.md's "real transparency…
infeasible" note). Doing so would open up real background/transparency
control on the flyout, the same way it already did for `VolumeToast.qml`
and `VolumeHoverTooltip.qml`.

That TODO note already flags the core risk, carried over from the
tooltip's own "Optical 1" bug (Phase 4.5.3): a custom Dialog's elements can
silently reposition based on a *sibling's* current content/visibility
rather than being fixed. This session's job was to turn that general
warning into a concrete, evidence-based answer: exactly where in
`FullRepresentation.qml` this risk actually lives today, exactly why the
tooltip's fix took three rounds to land, what a rebuild would really cost
to reimplement (dismiss/focus/positioning), and an honest go/no-go call —
no implementation this session, this document is the deliverable.

Three parallel investigations fed this document: (1) a full read of
`FullRepresentation.qml` (1833 lines) for layout hazards, (2) the git
history of `VolumeHoverTooltip.qml`'s three-round baseline bug, and (3) the
real KDE/libplasma source for what a custom Dialog would need to
reimplement. Citations below were spot-verified directly (not taken on
faith from the sub-investigations).

---

## 1. Layout hazard inventory — `FullRepresentation.qml`

Structural skeleton for reference: root `Item` (line 159, deliberately not
a Layout — settings gear and background overlay need independent
positioning) whose `implicitHeight` is bound to a single `mainColumn`
`ColumnLayout` (803-1832) containing, top to bottom: amp header → amp list
(collapsible) → volume block (dB/unit + source chip, then −/slider/+) →
action row (mute/power) → source `ComboBox` → footer.

### 0. Master finding — the whole popup's height, and therefore every control's screen Y, is content-derived

`FullRepresentation.qml:163` — `implicitHeight: mainColumn.implicitHeight`.
`mainColumn` (803, `spacing: 0`) sums every section's implicit/preferred
height. Plasma's Dialog machinery re-derives popup position from this root
item's size (see §3), so **any** section's implicit-height change —
amp-list expand/collapse, amp count changing, a divider appearing —
resizes and can reposition the *entire* popup, moving every control, not
just the ones near the change. Every finding below is a concrete trigger
feeding this one master dependency.

### Concrete findings, file:line

1. **`FullRepresentation.qml:1197`** — `Layout.alignment: Qt.AlignBaseline`
   on the nested `RowLayout` wrapping the dB-value Label (1199) and the
   "dB" unit Label (1226-1231). **Currently dormant**: no sibling in the
   outer row (1192-1254) also requests `AlignBaseline`, so there's nothing
   to compute a shared baseline against today. Flagged because this is the
   exact pattern class that broke the tooltip three times — it only takes
   one future edit (e.g. giving the source chip `AlignBaseline` too) to
   activate it.

2. **`FullRepresentation.qml:1242-1243`** — source chip `Rectangle` sized
   directly from `sourceChipLabel.implicitWidth/Height` (verified live),
   and `sourceChipLabel.text` (1248) is `root.activeSourceName` with
   **no `elide`, no `Layout.maximumWidth`** — unlike every other dynamic
   label in the file. A long source name grows the chip unbounded; it's
   absorbed by the `Item { Layout.fillWidth: true }` spacer at 1234 until
   that spacer bottoms out at 0, at which point the chip visibly overlaps
   or is squeezed against the dB-value row. Strongest "unbounded content
   width drives layout" finding in the file.

3. **`FullRepresentation.qml:821, 969, 1094`** — `ampHeaderBg`,
   `ampNoneOption`, `ampOption` all size their `implicitHeight` from a
   child row's `implicitHeight` plus a fixed pad. Currently safe because
   every text label feeding those rows is single-line + `elide:
   Text.ElideRight` with no explicit `wrapMode` — height stays constant
   regardless of text length, only width need varies. This is an
   *implicit*, not structural, guarantee (nothing pins `wrapMode:
   Text.NoWrap`), so it's a fragile safety, not a designed one.

4. **`FullRepresentation.qml:932`** — `ampListContainer.implicitHeight:
   root.ampListOpen ? Math.min(ampListColumn.implicitHeight, 220) : 0`,
   animated. This is the primary engine behind the §0 master finding:
   expansion state, `knownAmps` count, and the "no amps" label (next
   finding) all flow through here into `mainColumn`'s total height. The
   `Math.min(…, 220)` cap also means content silently starts clipping
   (via `clip: true`, line 931) with no scroll affordance once list
   content exceeds 220px — a distinct, adjacent risk.

5. **`FullRepresentation.qml:1045`** — "No amps discovered yet" Label,
   `visible: root.knownAmps.length === 0`, sibling of the `Repeater`
   (1055) inside `ampListColumn`. Toggling this on/off changes
   `ampListColumn.implicitHeight`, cascading through finding 4 into the
   master finding — moving the volume block, action row, source block,
   and footer below it.

6. **`FullRepresentation.qml:1171`** — divider `visible: root.ampListOpen`.
   Compounds with finding 4 on the *same* trigger (list toggling): both
   the container's animated height and this divider's visibility change
   together, both shifting everything in `mainColumn` below them.

7. **`FullRepresentation.qml:1055-1167`** — `Repeater` over
   `root.knownAmps` inside `ampListColumn` (a `ColumnLayout`, not an
   independently-scrolling `ListView`). Each delegate's height is stable
   per finding 3, but total height scales linearly with **amp count** —
   i.e. how many amps the daemon has ever discovered silently determines
   the popup's total height today, via the same cascade as findings 4-6.

8. **Volume slider (1288-1434), verified clean.** Its width is fully
   determined by two fixed 26×26 sibling buttons (`parent width − 2×26 −
   2×spacing`); `implicitHeight: 26` is a hardcoded literal; its
   `background`/`handle` delegates size purely from the Slider's own
   `availableWidth`/`visualPosition`. **Not** vulnerable to the
   sibling-content bug class — called out explicitly since it was a named
   concern in the task brief (`volumeInteracting` gating affects *value*
   during drag, not position/size — separate, unaffected concern).

9. **`VolumeToast.qml:220` and `:230` — live, unfixed, same pattern class
   the tooltip needed three rounds to close.** Verified directly: two
   Labels, `ampName` (218-227, `elide: Text.ElideRight`, fixed font) and
   `valueText` (229-242, font **family/weight/pixelSize all swap** between
   numeric-dB and word "Muted"/"Unmuted" forms), are direct siblings in
   one `RowLayout` (214-243), both `Layout.alignment: Qt.AlignBaseline`,
   with **no `Layout.preferredHeight` pin** on the row. This is the exact
   font-swap-under-shared-baseline shape that caused the tooltip's round
   5 bug — it just hasn't been visibly triggered/reported yet. This is
   important evidence: even *after* this project fully root-caused and
   fixed the pattern once (in the tooltip), the same hazard shipped
   unfixed in a sibling file using the identical `PlasmaCore.Dialog`
   approach. The lesson wasn't self-enforcing across the codebase.

---

## 2. The tooltip's three-round bug history

Three commits: `516333e` (original tooltip, not yet its own Dialog),
`2c1f702` (Aug 31 00:12 — rebuilt as own `PlasmaCore.Dialog`, bundles
rounds 3 *and* 4), `3f2c330` (Aug 31 19:06, ~19h later — round 5, isolated
commit, the actual fix).

- **Round 3**: the dB value+unit pair lived in its own nested `RowLayout`,
  itself `Qt.AlignBaseline`-aligned against the sibling `sourceName`
  Label. A generic `RowLayout` has no real font-metric baseline the way a
  `Label` does, so `sourceName` baseline-aligned to a real text baseline
  while the nested RowLayout aligned to effectively nothing — visible
  overlap. **Fix**: flattened the pair into direct `Label` siblings, still
  `AlignBaseline`. This fixed *which children participate* but not the
  underlying mechanism — the commit message for `2c1f702` already flags a
  remaining vertical shift as a known loose end before landing.

- **Round 4**: `nameRow` (the amp-name row, no `AlignBaseline` anywhere in
  it) shifted 2px between mute states. Root cause via live
  `onHeightChanged` logging: `statRow`'s own `implicitHeight` swung
  16px↔18px because its "dB" unit Label dropped out of Layout *sizing*
  (not just rendering) via `visible: false` when muted — QtQuick Layouts
  excludes invisible children from sizing. Since `statRow` follows
  `nameRow` in the same `ColumnLayout`, that swing perturbed `nameRow`'s
  position — a stacking artifact, not a `nameRow` bug. **Fix**: pinned
  `statRow.Layout.preferredHeight: 18`. This stopped the *leak between
  rows* but didn't touch the *baseline computation inside* `statRow`.

- **Round 5 (the actual fix)**: "Optical 1" (`sourceName`) itself still
  shifted a few pixels by mute state, discovered immediately after round
  4. Root cause: `Qt.AlignBaseline` computes **one shared row-internal
  offset from the font metrics of whichever children currently
  participate**. The value Label swaps font family/weight/size between
  numeric and "Muted"-word forms (different glyph ascent → different
  baseline), and the unit Label drops in/out via `visible`. Every
  baseline-aligned sibling — including `sourceName`, whose own font never
  changes — moved with that shared baseline. **The element that moved was
  never the element that changed.** Fix: switched all three Labels from
  `AlignBaseline` to `AlignVCenter` (positions from *own* height only,
  zero cross-sibling dependency), on top of round 4's height pin.
  Verified via `spectacle -f` pixel-diff across states plus a
  same-state control capture as a noise baseline — 0 differing pixels
  outside legitimately-different content.

**Why margin/padding tuning was a dead end, structurally**: margins are
offsets from a *computed base position*. The bug was never a wrong offset
— the base position itself (the shared baseline) was a function of a
sibling's live state. No fixed nudge compensates for a moving target. The
only real exits were removing the shared computation (`AlignVCenter`) or
fixed anchoring — which is exactly why rounds 3-4 (which tuned structure
without removing the shared-baseline dependency) didn't close it, and
round 5 (which removed the dependency itself) did.

---

## 3. Implementation burden: dismiss / focus / positioning

Two relevant classes exist in libplasma (Plasma 6.7.4 on this machine),
confirmed against real source, not summarized from memory:

- **`PlasmaQuick::Dialog`** (`PlasmaCore.Dialog`, `dialog.h`/`dialog.cpp`)
  — what `VolumeToast.qml`/`VolumeHoverTooltip.qml` already use.
- **`PlasmaQuick::AppletPopup` → `PopupPlasmaWindow` → `PlasmaWindow`** —
  a newer class, and, confirmed by fetching KDE's real
  `plasma-desktop/desktoppackage/contents/applet/CompactApplet.qml`
  (the literal shell wrapper currently producing *this project's own
  flyout* today), **this is the actual class chain already backing the
  current flyout.** "The shell's free behavior" is itself an instance of
  the same primitive a hand-rolled Dialog would use.

**Dismiss-on-click-outside**: real, in both classes, off by default
(`hideOnWindowDeactivate`). `Dialog::focusOutEvent()` (dialog.cpp
1254-1283, read verbatim) correctly distinguishes "focus moved to my own
child popup (combobox, submenu) → stay open" from "focus moved elsewhere →
close" — exactly the flyout's real requirement. `PopupPlasmaWindow`'s
version is wired to the global `QGuiApplication::focusWindowChanged`
rather than a local `focusOutEvent`, arguably more robust. **Real local
precedent** that this works for a "stay open through interaction" popup
(not just a toast): `com.github.kenansalar.plasma-gnome-pager`'s
`RenameDialog.qml`, installed on this machine, uses
`hideOnWindowDeactivate: true` with a `TextField` taking active focus and
its own comment "click-away cancels." Neither class handles Escape or a
context-menu dismiss automatically — even KDE's own `CompactApplet.qml`
writes an explicit `Keys.onEscapePressed` and a `Connections` block for
context-menu dismiss. **Low-to-medium risk**: the hard part is free, the
residual is a few copyable one-liners.

**Focus handling — the genuinely risky one.** Not free in *either* class.
Even `CompactApplet.qml` (KDE's own code) has to explicitly call
`dialog.requestActivate()` — with its own inline comment admitting this
"currently fails and complains at runtime: `QWindow::setWindowState does
not accept Qt::WindowActive`" — and manually relay focus into content via
a `MouseEventListener { focus: true; onActiveFocusChanged: … }` wrapper.
A rebuild inherits this exact wiring, bug included. This is the one area
where "it's free today" is least true, in the shell's own implementation.

**Screen-edge-aware positioning**: real and reasonably thorough in both
classes. `Dialog::popupPosition()` (dialog.cpp 983-1237) does genuine
4-direction edge-flip math against `screen()->availableGeometry()`, and is
automatically re-invoked when `mainItem`'s size changes
(`slotMainItemSizeChanged` → `syncToMainItemSize`, dialog.cpp 596-657,
912-914) — so a flyout resizing itself (§1 master finding) would get
re-flipped automatically. One confirmed gap in `Dialog`: it does not track
`visualParent`'s own window moving (panel repositioned, monitor change)
while open. `PopupPlasmaWindow` fixes exactly this gap
(`updateVisualParentWindow()`, popupplasmawindow.cpp 263-276, connects to
the anchor's `xChanged`/`yChanged`) and uses genuine Wayland-positioner-
style constraint placement. **Low risk**: mostly copying
`popupDirection`/`visualParent`/`removeBorderStrategy` bindings straight
out of `CompactApplet.qml`.

**Important gap in precedent**: no third-party plasmoid found (locally
installed or web-searched) manually instantiates `AppletPopup`/
`PopupPlasmaWindow` as its *primary* popup in place of `fullRepresentation`
— every real example either lets the shell build it (the normal path, used
today) or uses the older `Dialog` for a small *auxiliary* popup layered on
an already-inline representation. The class is confirmed real, exported,
and type-compatible (`appletInterface: QQuickItem*`, `PlasmoidItem` is a
`QQuickItem` subtype) — but actually driving it as the primary popup would
be uncharted territory for this specific move, even though
`CompactApplet.qml` proves the tool is right.

---

## 4. Proposed structural principles for the rebuild

Concrete, tied to the actual layout above — not a restatement of the
general rule:

1. **No `Qt.AlignBaseline` on any row containing dynamic text, anywhere in
   the new Dialog.** Use `Qt.AlignVCenter`/`Qt.AlignTop` with an explicit
   `Layout.preferredHeight` on the row instead — the exact pattern that
   closed round 5. Applies directly to the flyout's equivalent of
   `FullRepresentation.qml:1197` (currently dormant — make it explicitly
   safe from the start rather than waiting for it to activate) and should
   be applied as a **prerequisite fix to `VolumeToast.qml:220,230`**
   before or alongside the rebuild — it's the same live, unaddressed
   hazard, cheap to fix, and doubles as a dry run of the pattern on a
   small surface before betting the much larger flyout on it.

2. **Pin explicit `Layout.preferredHeight` on every row containing an
   element whose visibility or font can change** — not just the dB
   value/unit row (1195-1232), every row with a mute-state, power-state,
   or booting-state–dependent child (e.g. the action row's icon/spinner
   swap at 1601/1614, even though that one was found low-risk today).

3. **Elide + cap width on every dynamic-length label**, matching the
   pattern `ampHeaderRow`'s labels already use — fix the source chip gap
   (1242-1243) with `Layout.maximumWidth` + `elide: Text.ElideRight`
   rather than letting `sourceChipLabel`'s implicit width drive its
   container unbounded.

4. **Decouple total window height from the amp list's variable content.**
   The §1 master finding means every control below the amp list moves
   whenever it expands/collapses or amp count changes — and in a
   hand-built Dialog, *we* now also own re-triggering `popupPosition()`
   correctly on that resize, which the shell currently does for free.
   Two options, needs a decision before implementation (not resolved by
   this document): (a) make the list's max height truly fixed with a real
   scroll affordance from day one, replacing the current silent-clip-at-
   220px behavior, so the container's contribution to `mainColumn` never
   changes after first layout; or (b) pull the amp list out of in-flow
   `mainColumn` entirely (an overlay/child popup) so it can't perturb the
   rest of the flyout's position at all.

5. **Reserve width for the longest expected string** on any label with a
   fallback/placeholder form (the "—" em-dash cases already used for
   volume/source), rather than shrink-wrapping — prevents a value
   transitioning to/from its placeholder from nudging neighboring layout.

6. **Adopt `VolumeHoverTooltip.qml`'s final, verified pattern
   (`AlignVCenter` + pinned `preferredHeight`) as the house style for
   every row from day one** — write it into whatever review checklist
   accompanies the rebuild, since finding 9 above shows the lesson didn't
   travel automatically to a sibling file even after being fully
   root-caused once.

---

## 5. Proposed verification plan (for later execution, not run now)

Reuse the exact technique that actually closed round 5 — visual "looks
right" checks were what let this bug survive two prior rounds:

- **Pixel-diff screenshots** (`spectacle -f`) across the full state cross
  product: volume text length (e.g. `-40.0` vs `-15.0` vs `0.0` vs `—`)
  × mute on/off × power (off / Booting / on) × source (short name / long
  name / none) × amp (short name / long model-null-fallback UDP name /
  none selected / 0 known / 1 known auto-selected / 2+ known requiring
  explicit selection) × amp list expanded/collapsed. Include a same-state
  **control capture** as a noise baseline, exactly as round 5 did.
- **Programmatic coordinate capture**, not just visual diff — for every
  anchored element, log `mapToItem`/`mapToGlobal` x/y (round 4's own
  method, via `journalctl`) at each state permutation and diff those
  numerically. This catches a sub-pixel or visually-unremarkable shift on
  an element nobody happened to be looking at — precisely the failure mode
  that took three rounds to close on the tooltip, where each round only
  caught the element that happened to be visibly wrong *that time*.
- Run this as a **gate before any phase of the rebuild is called done**,
  not a one-time initial pass — the whole point is catching a regression
  on an element that wasn't the one just touched.

---

## 6. Go / no-go recommendation

**Qualified go, gated by a small spike — not a green light to start the
full rebuild immediately.**

Reasoning:

- The failure pattern that makes this risky is now genuinely understood,
  with a fix that's proven to work (§2) — this meaningfully de-risks a
  rebuild *if* §4's principles are enforced from day one. But finding 9
  (`VolumeToast.qml`'s still-live `AlignBaseline` hazard) shows the lesson
  doesn't self-enforce just because it's been learned once elsewhere in
  the same codebase — treat §4 as a checklist, not tribal knowledge.
- Dismiss and positioning are low-to-medium risk: both are real,
  reasonably thorough in libplasma, and largely copyable verbatim from
  KDE's own `CompactApplet.qml` — which turns out to already be built on
  the same `AppletPopup` primitive under discussion, not different
  machinery.
- **Focus handling is the real open risk.** It is not free even in KDE's
  own shell code, which carries a live, currently-unresolved-upstream Qt
  warning (`QWindow::setWindowState does not accept Qt::WindowActive`)
  around `requestActivate()`. That's a rough edge in the *reference*
  implementation, not just a theoretical concern for a hand-rolled one.
- No third-party precedent exists for driving `AppletPopup`/
  `PopupPlasmaWindow` directly as a *primary* popup in place of
  `fullRepresentation` — the class is confirmed real and type-compatible,
  but this exact move is untested territory, on this specific Plasma
  version/compositor.
- The reward is real (closes the corner-seam and no-`NoBackground`
  limitations noted in CLAUDE.md) but cosmetic, not functional — weighed
  against attempting it on the single largest, most heavily-tested surface
  in the codebase.

**Recommended path, in order:**

1. Fix `VolumeToast.qml`'s live `AlignBaseline` hazard (finding 9) first —
   cheap, closes a real latent bug, and is a low-stakes dry run of the
   fixed-anchor pattern before committing the flyout to it.
2. Time-box a minimal spike: replace just the compact→full transition with
   a bare `PlasmaCore.AppletPopup` (empty content, no real UI) and verify
   dismiss/focus/positioning actually behave acceptably on this exact
   system — specifically whether the `requestActivate()` warning is
   cosmetic-only here or actually breaks keyboard focus into flyout
   controls. This is the one unknown real testing can resolve cheaply
   before committing to the full rebuild.
3. If the spike is clean, proceed with the full rebuild using
   `PlasmaCore.AppletPopup` (not the older `Dialog`) — it's a strict
   superset for this use case (smarter dismiss wiring, tracks the anchor
   moving) and is the exact class already producing today's flyout, which
   lowers the real risk below what TODO.md's original "reimplement from
   scratch" framing implied.
4. Build every row in the new QML against §4's principles from the first
   commit, and treat §5's verification suite as a completion gate for each
   phase, not a final pass.

If the focus-handling spike in step 2 turns out to be genuinely broken on
this system (not just a benign warning), that's the point to stop and
keep this deferred — everything else in this investigation is
manageable, but unreliable keyboard focus in the flyout's own controls
(the slider, buttons, combobox) would be a regression the current
shell-managed popup doesn't have today.

---

## 7. Phase 7.0.0 spike results (executed 2026-09-01)

Ran §6 step 2 for real, on `spike/flyout-appletpopup-rebuild`. Scope was
exactly as specified there: a bare `PlasmaCore.AppletPopup` replacing the
compact→full transition, empty/placeholder content only, gated behind a
one-line toggle (`main.qml`'s `appletPopupSpikeEnabled`, default `false`)
so the real, shell-managed flyout stayed completely intact and reachable
whenever the flag is off. No `FullRepresentation.qml` content was ported
in; no changes were made to `FullRepresentation.qml` itself.

New file: `AppletPopupSpike.qml`. Its dismiss/positioning/focus bindings
were copied deliberately from the real, installed
`/usr/share/plasma/shells/org.kde.plasma.desktop/contents/applet/
CompactApplet.qml` (read directly this session, alongside
`appletpopup.h`/`.cpp` and `popupplasmawindow.h` under
`/usr/include/PlasmaQuick/`, re-confirming §3's API surface against the
real source rather than trusting the earlier summary from memory):
`popupDirection`/`floating`/`removeBorderStrategy`/`visualParent`/
`backgroundHints`, the `requestActivate()` call at the same site as the
shell's own known-warning call, the QTBUG-146992
`enabled: dialog.visible` workaround, and the
`MouseEventListener{focus:true}` + `onActiveFocusChanged` focus-relay
wrapper. `appletInterface` was deliberately left unset — it would have
made this throwaway popup share the real flyout's `popupWidth`/
`popupHeight` KConfig persistence keys (confirmed in
`appletpopup.cpp::setAppletInterface`/`hideEvent`), and sizing doesn't
depend on it (`LayoutChangedProxy` reads `mainItem`'s own Layout hints
regardless).

### Bug found and fixed before any live testing was possible

First install (flag on) auto-opened the spike popup ~5s after
`plasmashell` startup, with no click made. Root cause: `Window`-derived
QML types (which `PlasmaCore.AppletPopup` is, via `PopupPlasmaWindow` →
`PlasmaWindow`) default to `visible: true`. The real `CompactApplet.qml`
overrides this with an explicit binding
(`visible: root.plasmoidItem.expanded && root.fullRepresentation`); this
file initially had no equivalent explicit initial value, so it inherited
the `Window` default instead of the intended `false`. Fixed with a plain
`visible: false` initial-value assignment (not a binding — the
click-handler's later imperative `spikePopup.visible = !spikePopup.visible`
still overrides it freely). Re-verified clean after the fix: three
separate reloads, zero auto-opens.

Not a finding about the rebuild's viability — a bug in *this session's
own spike code*, not in the AppletPopup class or CompactApplet.qml's
pattern. Documented because it's a real, concrete illustration of
exactly the kind of "assumed a default, got a different one" mistake
this whole investigation is trying to guard against elsewhere too.

### Live verification results, real desktop (Plasma 6.7.4, Wayland/KWin)

No mouse/keyboard automation tool exists in this Wayland session (no
`xdotool`/`ydotool`/`wtype` installed or in the synced repos), so all
interaction below was performed by the project owner directly, narrating
results and supplying screenshots, while journald was tailed live for
correlation — not simulated or assumed.

- **Opens and positions correctly**: yes. The real panel icon sits at the
  extreme top-right corner of the screen (about as hard an edge case as
  this system offers without physically moving the panel); the popup
  appeared fully on-screen, anchored below-and-left of the icon
  (`popupDirection: Qt.BottomEdge`, matching `Plasmoid.location ===
  TopEdge`), no clipping, confirmed via two separate user-supplied
  screenshots two minutes apart.
- **Dismiss-on-click-outside**: yes, confirmed explicitly (left-clicking
  empty desktop wallpaper while the popup was open closed it) — not just
  inferred from the focus-loss cases below.
- **Escape key dismiss**: yes, confirmed explicitly (focus in the
  TextField, Escape closed the popup), via the `Keys.onEscapePressed`
  binding copied from `CompactApplet.qml`'s `mainItem`.
- **Keyboard focus into a real interactive control**: yes, and verified
  as more than "no warning in the log" — two screenshots show the
  TextField holding a visible text cursor, showing typed text
  ("testing testing testing hej whoooo") verbatim, with the live
  `"✓ TextField has active focus"` indicator lit. journald shows the
  expected relay sequence every time: `mainItem activeFocus: true` →
  `mainItem activeFocus: false` → `focusTestField activeFocus: true` —
  i.e. `MouseEventListener` receives focus first, then
  `onActiveFocusChanged` immediately forwards it into the real control,
  exactly the mechanism `CompactApplet.qml` uses to hand focus to
  `fullRepresentation`.
- **The `QWindow::setWindowState does not accept Qt::WindowActive`
  warning**: did **not** appear, not even once, across 11 separate
  open/`requestActivate()` cycles over ~5 minutes of real interaction
  (checked in journald filtered to the `plasmashell` process, and in its
  raw redirected stdout/stderr — both empty for this string). This is
  the single question this spike existed to answer. On this exact
  system (Plasma 6.7.4, KWin/Wayland), the warning that `CompactApplet.
  qml`'s own comment says "currently fails and complains at runtime" did
  not reproduce for this popup at all — and even if it had, the focus
  results above already show it wouldn't have been more than cosmetic
  here, since focus landed correctly every single time regardless.
- **Benign side note, not a bug**: text typed into the TextField
  persisted across separate open/close cycles. Expected —
  `visible: false` hides the window without destroying `mainItem`'s
  QML item tree, so its state simply survives, the same as any
  `Window`-backed popup. Not evidence of anything wrong with dismiss.
- **Not tested this session**: repositioning while the popup is open
  (dragging the panel to a different edge, or a monitor change) with the
  popup left open throughout. §3's cited gap in `Dialog` (doesn't track
  the anchor's window moving) was one of the specific things
  `PopupPlasmaWindow` was said to fix over the older class
  (`updateVisualParentWindow()`), but that specific live scenario wasn't
  exercised here — the tests above already covered the position-on-open
  and edge-clipping questions that were the more immediate concern.
  Worth a quick check before or during the real rebuild, not blocking on
  its own.

### Updated conclusion

Every question §6 flagged as the actual open risk for this spike came
back clean, on real hardware, with real interaction rather than assumed
behavior: dismiss (both click-outside and Escape) works, positioning is
correct including at a real screen-corner edge case, and — the
specifically named unknown — keyboard focus reaches a real interactive
control reliably and the `requestActivate()` warning that worried
`CompactApplet.qml`'s own authors didn't reproduce at all here. Nothing
in this pass surfaced a reason to stop per §6's own stated stop
condition ("if the focus-handling spike... turns out to be genuinely
broken... that's the point to stop").

This does **not** by itself authorize starting the full rebuild —
per the original task scope for this phase, that decision belongs to
the project owner, to be made after reviewing these results, not
triggered automatically by a clean spike outcome. If a full rebuild is
greenlit, §4's structural principles and §5's verification plan are
unaffected by anything in this section and still apply in full.
