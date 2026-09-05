# CLAUDE.md

## Project

KDE Plasma panel-pinned widget (Plasmoid) for controlling the Devialet
Expert Pro 140 amplifier over UDP — an icon a user drags directly onto
their panel via "Add Widgets" (like Digital Clock or Compact Pager), not a
system tray item. See "Why panel-pinned, not a system tray plasmoid" below
for why. Companion project to an existing Android app and an in-progress
Flutter app for the same amplifier — same protocol, different platform.
Rust + QML, no C++.

## Background

An Android app was developed earlier in Kotlin (source of truth for the
protocol and known bugs):
https://github.com/ekmanch/devialet-expert-remote

A Flutter port for Android/iOS is also in progress, in a separate repo:
https://github.com/ekmanch/devialet-expert-remote-app

This widget is a second, independent port of the same protocol to a third
platform (Linux desktop / KDE Plasma), not built on top of either of the
above — but the protocol itself, and known gotchas, are shared truth across
all three.

## Reference docs (read before working on networking or protocol code)

- `docs/protocol.md` — UDP packet structure, transport details, command
  types. Treat as the spec for the networking layer. Anything marked
  "inferred, not confirmed" should be verified against the real device
  before being relied on.
- `docs/known-gotchas.md` — bugs already found and fixed in the Kotlin/
  Flutter apps. Check before implementing anything networking/state
  related so we don't reintroduce a fixed bug — in particular the
  non-linear source-index-to-command-value lookup table and the forced
  −40dB send after every source switch.
- `docs/app-overview.md` — architecture/feature overview of the original
  app. Most of its "platform-specific behavior" section is Android/iOS-
  specific and doesn't transfer; the KDE-specific equivalent questions
  (daemon lifecycle, D-Bus vs. polling) are decided below, not in that doc.

## Architecture (settled — do not re-derive)

- **No C++, no CMake.** Rust + QML only. This is a hard project constraint,
  not a soft preference — if a design decision seems to require C++
  (cxx-qt or similar), stop and flag it rather than proceeding.
- **Panel-pinned, not a system tray plasmoid (settled, do not relitigate).**
  This widget installs as a normal panel applet — the user drags it onto
  their panel via "Add Widgets," like Digital Clock or Compact Pager — not
  something that lives inside the system tray's collapsed icon cluster.
  `metadata.json` has no `X-Plasma-NotificationArea` /
  `X-Plasma-NotificationAreaCategory` keys (removed; their presence is
  what makes an applet tray-eligible in the first place, confirmed live by
  their removal producing `"inTray": false` in
  `plasmashell --replace`'s own `dumpCurrentLayoutJS` output for this
  applet). Reason: the system tray is itself a Plasma widget
  (`org.kde.plasma.private.systemtray`) that defines its own shared popup
  Dialog, whose `mainItem` is the tray's own `ExpandedRepresentation.qml`
  — every applet hosted inside the tray gets embedded inside that shared
  wrapper, which draws a back-arrow/title header row no individual hosted
  applet can remove or override from its own QML (confirmed via the
  tray's own architecture:
  https://zren.github.io/2018/11/17/exploring-plasmas-systray-widget, not
  just observed behavior). Living in the tray would mean permanently
  carrying that header row, with no workaround — incompatible with this
  widget's own copper/graphite panel being the entire flyout, edge to
  edge, matching `design/mockups/devialet_tray_flyout_mockup.html`
  exactly. Verified end-to-end after removing the tray keys: widget added
  to a real panel via the Plasma scripting API, clicked for real, and
  screenshotted — clean panel, no back-arrow, no title bar, no navy frame,
  identical with or without other windows open. The QML structure needed
  no changes for this — `PlasmoidItem` +
  `compactRepresentation`/`fullRepresentation` in `main.qml` is the same
  standard popup-applet structure whether tray-hosted or panel-pinned
  (confirmed against `com.github.tilorenz.compact_pager`, a real
  panel-pinnable applet installed on the dev machine); only
  `metadata.json` controlled tray eligibility.
- **Commands** (volume/mute/power/source): single-shot Rust CLI binary,
  invoked from QML via `Plasma5Support.DataSource`'s executable engine.
  Each invocation builds one UDP command packet, sends it, exits. No
  daemon involvement.
- **Status listener**: a single long-running Rust daemon owns the UDP
  45454 socket, parses every status broadcast, and maintains latest-known
  state (per-amp discovery list, online flag via the 8s staleness rule).
  Plain synchronous Rust, single thread, blocking `UdpSocket::recv_from`
  loop — no async runtime.
- **State delivery to QML**: push via D-Bus, using `zbus` (pure Rust, no
  C++) on the daemon side and the `org.kde.plasma.workspace.dbus` QML
  module (`Plasma.DBusProperties`) on the QML side — ships standard with
  plasma-workspace, no build step. Daemon exposes properties (Volume,
  Muted, Power, ActiveSource, DeviceName, Online) on the session bus;
  `PropertiesChanged` signals keep QML in sync automatically. No polling,
  no status file.
- **Daemon lifecycle**: managed by a `systemd --user` unit
  (`devialet-remote-daemon.service`), `Restart=on-failure`,
  `WantedBy=plasma-workspace.target` (or `graphical-session.target`) so it
  autostarts at login and is supervised/restarted on crash. Not XDG
  autostart — the daemon needs crash recovery and query-ability
  (`systemctl --user is-active`), which XDG autostart doesn't provide.
- **Debounce**: lives in QML, not the daemon. On a locally-initiated
  change, QML applies an optimistic update and records a per-field
  timestamp; for 400ms after, QML ignores whatever the D-Bus property
  push delivers for that field and keeps showing its own optimistic
  value. Matches the Android Kotlin app's validated 400ms debounce window
  (mirrors known-gotchas.md's debounce-race lesson) — no evidence this
  transport needs a longer window, so start here rather than a larger,
  unjustified value. Revisit only if real testing shows 400ms isn't
  enough for the UDP → daemon → D-Bus → QML path specifically.
- **Persistence**:
  - Widget settings (blur, reduce motion, scroll step, "launch at
    login" toggle *display*) — `Plasmoid.configuration`
    (`contents/config/main.xml`). None of these are read by the daemon
    or command CLI.
  - Daemon autostart itself — systemd unit enablement
    (`systemctl --user is-enabled/enable/disable`), *not* a
    `Plasmoid.configuration` boolean. The QML settings toggle reflects
    and controls this systemd state via the executable engine; it is
    not the source of truth.
- **Protocol logic**: isolated in a pure library crate, zero I/O (no
  sockets, no files, no async) — `Command -> [u8; 142]` and
  `&[u8] -> Result<Status, Error>` functions covering packet building,
  CRC16, `dbConvert`, and the source remap table. Both the daemon and the
  command CLI depend on this crate as thin I/O shims around it.
- **Flyout overlay lists are `QtQuick.Controls.Popup`, not ComboBox
  (settled in Phase 7.14.0, do not re-derive).** Both the amp picker
  (`AmpListOverlay.qml`) and the source picker (`SourceListOverlay.qml`)
  are plain Popups the widget owns, parented to their trigger row and
  reparented by Qt into the flyout window's `Overlay.overlay` when open
  (no second native window), with content in a synchronous
  `ColumnLayout` + `Repeater` so their height is known before `open()`.
  `FlyoutContent.qml` owns one bool per list (`ampListOpen`,
  `sourceListOpen`), drives `open()/close()` imperatively, listens to
  `closed`, never binds `visible`, and clears the other flag when one
  opens (mutual exclusion is explicit, not left to press-outside
  policies). The source list used `PlasmaComponents3.ComboBox` through
  Phase 7.13.0 under a "required per QTBUG-66446" rule; that rule was
  re-examined in 7.14.0 and does not hold: QTBUG-66446 is "Popup's
  contentItem isn't mirrored if no Window exists" — an RTL
  `LayoutMirroring` bug filed against Popup in general (it applies to
  these Popups too and is moot for this LTR-only UI). The real Phase 3
  failure was `QtQuick.Controls.ComboBox`'s qqc2-desktop-style popup
  being a QStyle-drawn `Menu`, which a plain Popup never touches. Do not
  restyle the open dropdown by overriding a ComboBox's `popup:` — its
  ListView only gets its model once visible and its height chases
  delegates as they land, which broke live three times before the Popup
  rebuild.
- **In-process alternative (cxx-qt) considered and rejected**: the listener
  could in principle run inside plasmashell's own process via a cxx-qt QML
  plugin instead of as a standalone daemon, eliminating the need for a
  systemd unit entirely. Rejected because: (a) a crash in an in-process
  plugin can take down plasmashell itself — the whole panel/tray, not just
  this widget — versus a standalone daemon crash only losing amp
  connectivity until systemd restarts it; (b) Rust panics unwinding across
  the Rust↔C++ FFI boundary into Qt's call stack are undefined behavior
  unless explicitly guarded at every entry point; (c) no QML hot-reload for
  plugins means every code change requires reinstalling the .so and
  restarting plasmashell, a meaningfully worse dev loop while actively
  building this. The systemd-unit cost (one config file, written once) is
  small relative to these risks. Do not revisit this without a new reason.

## Scope

Control-only: volume, mute, power, source selection. No SAM/Night
Mode/Bass/Treble (UDP bytes not reverse-engineered) — see known-gotchas.md
for what's confirmed out of scope.

## Networking

- Follow `docs/protocol.md` exactly for packet structure — don't
  reconstruct it from guesswork.
- Cross-check any new networking/protocol code against
  `docs/known-gotchas.md`.
- The −15dB safety ceiling (matching Kotlin's `coerceAtMost`) must be
  enforced in the protocol/daemon layer, not just left to QML range
  limiting.

## Testing

- Protocol crate: `cargo test`, fixed byte fixtures — packet building,
  CRC16 poly/init, the source remap table (encode as a regression test
  with hardcoded expected output bytes, guarding against reintroducing
  known-gotchas.md bug #3 — source index treated as command value).
- No network or hardware required for protocol crate tests.

## Working style

- This is a phased build (architecture → scaffold → protocol crate →
  daemon → command CLI → QML UI → polish). Don't jump ahead to UI before
  the daemon and protocol layer are verified against the real amp.
- Prefer flagging ambiguity over guessing, especially for protocol/state
  behavior — ask rather than assume if `docs/` doesn't cover it.
- Keep commits scoped to one phase/concern at a time.
- Current phase status and the full roadmap are tracked in `TODO.md`, not
  here. Check it before assuming what's done vs. pending — but the phase
  stated explicitly in the prompt for a given session takes precedence if
  the two ever seem to disagree (e.g. TODO.md hasn't been updated yet).
- never add files as tracked, commit changes, or push changes to remote.
  The user of Claude Code would like to do this himself after verifying
  that everything works the way he expects it to.

## Reloading changes into the live widget

The plasmoid installed at
`~/.local/share/plasma/plasmoids/com.ekmanch.devialetremote/` is a **copy**
of `plasmoid/`, not a symlink — `kpackagetool6` copies files on install.
Editing files under the repo's `plasmoid/` does nothing to the running
widget by itself; the copy has to be refreshed and the shell restarted.
Discovered the hard way after Phase 4.0: committed QML changes produced no
visible difference in the live widget until this was done.

Reload workflow after any change under `plasmoid/`:

```
kpackagetool6 --type Plasma/Applet --upgrade plasmoid/
plasmashell --replace &
```

`--upgrade` re-copies the package contents (bumps a version check
internally so it doesn't no-op); `plasmashell --replace` is needed because
Plasma caches/compiles QML per-process and won't pick up the new package
contents in an already-running shell. `--replace` briefly kills and
restarts the whole shell (panels, tray, desktop) — expected, not a crash.

Re-verified identical after the panel-pinned architecture change (removing
`X-Plasma-NotificationArea`/`X-Plasma-NotificationAreaCategory` — see
Architecture above): this workflow doesn't change at all. The only actual
difference is *how the widget gets added* to a panel in the first place —
it no longer appears in the system tray's own "configure visible icons"
list (it isn't tray-eligible any more), only in the normal Plasma widget
list ("Add Widgets"), the same place Digital Clock or Compact Pager show
up. Confirmed live: added via the Plasma scripting API
(`org.kde.PlasmaShell.evaluateScript`, `panels()[i].addWidget(...)`) as a
stand-in for a real drag-and-drop "Add Widgets" add, which produced
`"inTray": false` in `dumpCurrentLayoutJS` and a normal panel icon — same
outcome a manual drag would produce.

This is a real trade-off worth revisiting deliberately, not a default to
silently switch to:

- **`kpackagetool6 --upgrade` per phase (current)**: extra two-command step
  after every change, but matches how the plasmoid will actually be
  installed for real users (a copy, no dev-machine-specific symlink setup)
  and gives an explicit moment where "is this actually installed" is
  unambiguous.
- **Symlink `~/.local/share/plasma/plasmoids/com.ekmanch.devialetremote` →
  the repo's `plasmoid/` directory instead**: drops the `kpackagetool6`
  step entirely — just `plasmashell --replace` after edits. Faster
  inner loop while this widget is under active development. Downside:
  diverges from the real install path (real users get a copy via
  `kpackagetool6 --install` or packaging, never a symlink), so it
  stops being a faithful rehearsal of "did the install step actually
  work" — a bug in the copy/install step itself could go unnoticed
  until real packaging. Not adopted without asking first.

Either way, `plasmashell --replace` is required for QML changes to take
effect — there is no hot-reload for KPackage-based applets short of a full
shell restart.

## `target/` can go missing out from under a running daemon — every widget command then silently no-ops (found live, post-Phase-7.13.0 investigation)

**Symptom**: every widget control (volume, mute, source, power) appears to
apply optimistically for well under a second, then reverts to whatever the
amp last actually reported — uniformly across every control type, not just
one. Looks exactly like a QML/daemon logic regression (e.g. in the Phase
5.0.0 pending-command masking or the 400ms debounce), but isn't one.

**Root cause**: the whole `target/` build directory (git-ignored, so
`git status` shows nothing unusual) was deleted from disk at some point
outside of any command this project's own workflow runs — not by
`cargo clean` from a documented step here, cause never fully identified.
Consequences, both silent:

- `~/.local/bin/devialet-ctl` (see this file's own PATH section below) is a
  symlink into `target/debug/devialet-ctl`. Once that target is gone, the
  symlink dangles. Every QML `Plasma5Support.DataSource` invocation of
  `devialet-ctl` then fails with shell exit code **127**
  (`devialet-ctl: command not found`) — but QML's `onNewData` handler only
  `console.log()`s the exit code/stderr, it doesn't surface this anywhere a
  user would see it. The real UDP command is simply never sent.
- The **daemon keeps running anyway.** Linux keeps a deleted-but-still-
  mapped executable alive in a process that already started from it
  (`/proc/<pid>/exe` shows `... (deleted)`), so `systemctl --user status`
  reports `active (running)` the entire time, giving no hint anything is
  wrong. The daemon itself doesn't need rebuilding to keep working — only
  a fresh invocation of the *other* binary (`devialet-ctl`) is affected.

With the real command never sent, the daemon's own Phase 5.0.0
pending-command mask (`PENDING_COMMAND_TIMEOUT`, 400ms) does exactly what
it's designed to do: show the optimistic value briefly, then fall back to
the amp's actual (unchanged) last-reported state once no real broadcast
confirms it in time. That fallback is what reads as "snaps back" — the
masking logic is not the bug here, a missing binary upstream of it is.

**How this was actually confirmed**, not just inferred from the symptom —
don't skip straight to a code fix next time either:

1. `systemctl --user status devialet-remote-daemon.service` looked
   completely healthy.
2. `journalctl --user -b | grep devialet-ctl` showed the real widget
   invocations failing with exit 127 the whole time — the actual smoking
   gun, found from real usage logs, not a guess.
3. `ls target/release/ target/debug/` — directory didn't exist at all.
   `readlink -f ~/.local/bin/devialet-ctl` pointed at a path that also
   didn't exist. `ls -la /proc/<daemon-pid>/exe` confirmed `(deleted)`.

**Fix, if this happens again**:

```
cargo build --release   # daemon's systemd unit points at target/release/
cargo build              # devialet-ctl symlink (see PATH section below) points at target/debug/
ln -sf "$(pwd)/target/debug/devialet-ctl" ~/.local/bin/devialet-ctl
systemctl --user restart devialet-remote-daemon.service
```

Verify the daemon is actually off the fresh binary afterward — status
alone won't tell you (see point 1 above):

```
systemctl --user show devialet-remote-daemon.service -p MainPID --value \
  | xargs -I{} ls -la /proc/{}/exe   # must NOT say "(deleted)"
devialet-ctl --help                  # must exit 0, not 127
```

**Before assuming a code regression when every control type reverts
identically**: that symmetry (volume *and* mute *and* source *and* power
all failing the same way) is itself a strong signal to check this class of
cause first — a single shared dependency (the executable engine's command,
or the daemon's own binary) breaking cleanly explains "everything reverts
uniformly" far more directly than a coincidental bug independently hitting
every control's own separate code path at once.

## Real flyout renders truncated (324×180) after a reload — the AppletPopup size-key collision (Phase 7.1.0/7.2.0; NOT cleared by 7.8.0 as first claimed — closed by Phase 7.10.0, see the last paragraph)

**Symptom**: after `plasmashell --replace`, the real, shell-managed flyout
opens cut off after the volume block - no action row, source selector or
footer - at exactly 324×180 logical px, the placeholder `FlyoutPopup.qml`
mainItem's size (18×10 grid units). Nothing in the flyout's own QML is
wrong; do not debug `FullRepresentation.qml` for this.

**Mechanism** (read from libplasma 6.7.4's `appletpopup.cpp`, fetched
from invent.kde.org, and confirmed empirically): `AppletPopup::hideEvent()`
writes `popupWidth`/`popupHeight` into
`appletInterface->applet()->config()` **unconditionally on every close** -
no user resize involved - and `setAppletInterface()` reads them back at
construction (`m_sizeExplicitlySetFromConfig` → `resize`). On the
`spike/flyout-appletpopup-rebuild` branch, `FlyoutPopup.qml` binds
`appletInterface` to the same `PlasmoidItem` as the shell's own
`CompactApplet.qml` popup around `FullRepresentation.qml`, so both write
and read the **same** KConfig group
(`[Containments][46][Applets][128][Configuration]` on the dev machine;
find yours via the `plugin=com.ekmanch.devialetremote` line in
`~/.config/plasma-org.kde.plasma.desktop-appletsrc`). Any single
open/close of the spike popup - a harness run, or a manual click with
`appletPopupSpikeEnabled` on - persists its size; the real flyout applies
it the next time its popup is constructed, i.e. after the next
`plasmashell --replace`. Phase 7.1.0's note blamed only resize-testing;
Phase 7.2.0 found it is every close.

**Cleanup, required after any manual spike-popup test** (the harness
does this itself - `tools/flyout-harness/harness.py run` snapshots both
keys before a run and restores/deletes them at teardown, logged in
`run.json`):

```
F=plasma-org.kde.plasma.desktop-appletsrc
G="--group Containments --group 46 --group Applets --group 128 --group Configuration"
kwriteconfig6 --file $F $G --key popupWidth --delete
kwriteconfig6 --file $F $G --key popupHeight --delete
plasmashell --replace &
```

**Verifying this needs a fresh shell.** `KConfigGroup::writeEntry` only
marks the group dirty when the value differs from the shell's in-memory
copy; an external `kwriteconfig6 --delete` doesn't invalidate that cache,
so a test against a still-running shell shows no write at all and looks
like a pass. And never verify "keys unchanged" by comparing values that
may already be the corruption - Phase 7.2.0's first report did exactly
that (324×180 before and after, rewritten with identical values) and
missed it; compare against absence after a restart instead.

**Did not go away at Phase 7.8.0**, contrary to this section's original
claim ("cutover removes the shell-managed popup, so only one `AppletPopup`
writes the group"). 7.8.0's cutover only stopped *opening* the
shell-managed popup; `main.qml`'s `fullRepresentation:` binding and the
shell's `CompactApplet.qml` popup around it stay instantiated until Phase
7.13.0 deletes them, and the cut-over `FlyoutPopup.qml` was itself an
`AppletPopup` with `appletInterface` set - so both writers survived. Phase
7.9.0 measured the consequence directly: a plain `plasmashell --replace`
with nothing ever opened rewrote the keys to 284×358 (the never-shown
popup's `hideEvent()` firing at shell teardown, window minus frame
margins). Phase 7.7.0's size pinning does not fix it either - it changes
what gets written, not that it gets written.

**Closed by Phase 7.10.0 from the other side**: the rebuilt
`FlyoutPopup.qml` is a `PlasmaCore.Dialog` that deliberately does not set
`appletInterface`. `Dialog::hideEvent()` only writes the keys when it is
set, and with the size pinned (`Layout.minimum* == Layout.maximum*`)
`Dialog` never reads them back anyway (`dialog.cpp`
`updateSizeFromAppletInterface()` returns early when min == max), so
setting it would have bought one KConfig write per close and nothing
else. Verified per this section's own rule (absence after a restart, not
value comparison): both keys deleted, then ~20 open/close cycles, a
harness smoke run and four `plasmashell --replace` - keys still absent.
The shell's dead popup around `FullRepresentation.qml` did not write in
that test either; if the keys ever do reappear before 7.13.0 removes it,
they are harmless to the pinned Dialog flyout (nothing reads them), and
the cleanup commands above still apply.

## Settings ConfigDialog (Plasma-provided default — settled, do not re-derive)

`Plasmoid.internalAction("configure")` is **not** null in a real installed
Plasma 6 applet, even before this project declares any `config.qml`/
`main.xml` of its own. Plasma's shell auto-provides a default
`ConfigDialog` for every installed applet — with baseline **Keyboard
Shortcuts** and **About** pages — regardless of whether the applet ships
custom config UI. Confirmed live (2026-08-29, real panel, Phase 4.2.1):
wiring the gear-icon trigger's `onClicked` to
`Plasmoid.internalAction("configure")?.trigger()` opened a real,
functioning "Devialet Remote Settings" window with those two pages,
before any `config.qml`/`main.xml` existed in this repo.

This corrects an earlier pre-implementation claim (made before that live
test) that the action returns a nullable `QAction*` and is genuinely null
until a `ConfigDialog` is declared — that claim was reasoned from the
`QAction*` API surface being nullable in principle (and from a real guard
seen in `BasicPlasmoidHeading.qml`), not from testing an actual installed
applet, and it doesn't hold here. The `?.` guard is harmless to keep but
isn't load-bearing — the action already resolves to something real.

Practical consequence for any future settings-page work: shipping
`contents/config/config.qml` (+ `contents/config/main.xml`) **adds a page
to this already-existing dialog**, it does not create the dialog or wire
up the trigger action — both already exist and already work. No
`metadata.json` key is involved at all — confirmed by checking three real
shipped Plasma 6 applets (`luisbocanegra.panel.colorizer`,
`org.kde.desktopcontainment`, `org.kde.plasma.systemmonitor`), none of
which reference `config.qml` there; Plasma's KPackage structure
auto-detects it purely by its fixed conventional path.

Confirmed live (Phase 4.4.0, 2026-08-29, reading the shell's own
`/usr/share/plasma/shells/org.kde.plasma.desktop/contents/configuration/
AppletConfiguration.qml`): the custom page(s) always appear *alongside*
Keyboard Shortcuts/About, never replacing them — the sidebar is built
from separate `Repeater`s (own categories, then Keyboard Shortcuts, then
About for a non-containment applet like this one), not a single merged
model, so there is no way to suppress the default two pages even if
wanted. Once a `config.qml` category list is non-empty, the dialog also
defaults to opening on the applet's own first category on launch, rather
than Keyboard Shortcuts as it does with no `config.qml` present.

### `ConfigCategory.source` resolves relative to `contents/ui/`, not `contents/config/` (found the hard way — Phase 4.4.0)

Not documented in any official KDE reference found, but independently
stated in several real third-party plasmoids' own source comments and
confirmed live here: a `ConfigCategory { source: "X.qml" }` path is
always resolved relative to the plasmoid's **`contents/ui/`** directory
(the main QML root), **regardless of where `config.qml` itself lives**.
This holds for a bare string *and* for an explicit `Qt.resolvedUrl("X.qml")`
call written inside `config.qml` — both resolve relative to
`config.qml`'s own file (`contents/config/`), which is the wrong base
either way, so neither form is a workaround for the other.

Getting this wrong doesn't produce a clean "file not found" error. It
manifests as a deep, misleading Kirigami `PageRow` failure instead:
`"Could not convert argument 1 from  to QQuickItem*"` /
`TypeError: Passing incompatible arguments to C++ functions from
JavaScript is not allowed.` (in `initAndInsertPage@PageRow.qml`, called
from the shell's own `AppletConfiguration.qml`), and — worse — that
failed *first* push corrupts page navigation for the **rest of that
dialog session**: every other category (including Plasma's own,
definitely-fine Keyboard Shortcuts/About) then fails identically via
`replace()`, making the bug look far more general than it is. A blank
category page plus other categories getting stuck showing stale content
after switching are the visible symptoms.

This project's `contents/config/` (per Repository Layout below) holds
`config.qml`, `main.xml`, *and* the actual category page QML files
(`ConfigGeneral.qml` etc.) side by side — a layout choice that directly
collides with this resolution rule. The fix used here: reference category
pages from `config.qml` with an explicit `"../config/"` prefix (e.g.
`source: "../config/ConfigGeneral.qml"`), the same "prefix to reach pages
living elsewhere" technique real precedents use for their own
`ui/config/` subdirectories (e.g. `com.github.tilorenz.compact_pager`'s
`source: "config/ConfigGeneral.qml"`), just adapted for `config/` being a
*sibling* of `ui/` here rather than nested under it. Do not "fix" a blank
or stuck config page by suspecting the page's own QML content, imports,
or `metadata.json` API keys first — check this path resolution rule
first, it is the far more likely cause for this specific failure
signature.

### Every settings control must persist, not just apply its effect

A settings toggle/slider "working" during a live session and a
settings toggle/slider actually being **wired** are two different
things — don't treat the first as proof of the second. Every control
on the settings page must have its value stored in
`plasmoid.configuration` (a `main.xml` kcfg entry), read back from
there on load, and written back on change. If a control instead only
drives its visual effect directly (e.g. a toggle that flips
`Plasmoid.backgroundHints` straight from its own local `checked`
state, with nothing backing it in KConfig), it will appear fully
functional within that one dialog session and then silently reset to
default the next time the dialog opens or the widget reloads — this
already happened once (Phase 4.4.3/4.4.4's original wording didn't
say "store in KConfig" explicitly, only "wire the toggle to the
effect," which is exactly the gap that produced this).

The exception is any control that deliberately reflects live external
state rather than a stored preference — Launch at login is the one
example so far, which must always show real `systemctl --user
is-enabled` output, not a remembered KConfig bool (see its own TODO
entry). Don't apply the "must persist to KConfig" rule to that kind of
control; applying it there would be the opposite mistake.

**Verification for any settings-wiring phase must include a reload,
not just an in-session toggle check**: close and reopen the settings
dialog, and separately reload the widget itself, and confirm the
control still reflects the value you set — not just that toggling it
visibly changed something in the moment.

## QML layout: Qt.AlignBaseline is unsafe with dynamic text (settled, do not relitigate)

**The pattern**: `Qt.AlignBaseline` computes one shared row-internal
baseline offset from the font metrics of whichever children currently
participate in that row. If any sibling's font or content can change at
runtime — not just its visibility — that sibling's glyph metrics
(ascent in particular) shift the shared baseline, which silently
repositions every other `AlignBaseline` sibling in the row, including
ones whose own `text`/`font.*` properties never changed. This is not a
margin or spacing bug and won't look like one; it looks like an
unrelated label "jittering" a couple of px only when some other part of
the row changes state.

**This has now happened three separate times in this codebase**, always
in the same shape (a row pairing a static label with a value label whose
font/content varies by state):

- `VolumeHoverTooltip.qml` (Phase 4.5.3) — took three rounds to close.
  Round 5's actual root cause (documented in that file's own header
  comment on `statRow`): the value Label swaps `font.family`/
  `font.weight`/`font.pixelSize` between its numeric-dB and "Muted" word
  forms, and the "dB" unit Label drops out of layout entirely via
  `visible: false` when muted — both were enough to drag "Optical 1" (a
  plain sibling whose own font never changed) along with the shifting
  baseline, even after the row's own height had already been pinned.
- `VolumeToast.qml` — fixed in this same style of session, but found
  proactively during the flyout-appletpopup-rebuild spike's own
  investigation (finding 9), *not* from a user report or a live glitch
  anyone had seen. Same shape exactly: `ampName` (static) and
  `valueText` (font/content swaps between numeric-dB and "Muted"/
  "Unmuted") as direct `AlignBaseline` siblings in one `RowLayout`.

Three strikes on the same exact shape — including a fresh, independent
recurrence in a second file, found by investigation rather than by
another live bug report — is the signal this is a house rule, not a
one-off fix.

**House rule going forward**: no `Qt.AlignBaseline` on any row that
contains a child whose text content or font can change at runtime.
Use `Qt.AlignVCenter` on every child in that row instead — it positions
each child from its own height only, not a shared cross-sibling metric —
**and** pin an explicit `Layout.preferredHeight` on the row itself to
the tallest child's actual measured implicit height across *all* of
that child's content states.

That last clause is load-bearing, not decoration — confirmed the hard
way while fixing `VolumeToast.qml` in this same pass. The first attempt
pinned `Layout.preferredHeight: 18`, copied from `VolumeHoverTooltip
.qml`'s own pinned value on the assumption a similar row needs a similar
number. It didn't: live measurement (`onImplicitHeightChanged`/`onYChanged`
logging via a standalone driver instantiating the real component) showed
`valueText`'s true implicit height is `20` in its numeric-dB form vs `16`
in its word form, and `18` — being *less* than the tallest state's real
height — left a reproducible 1px shift on `ampName` even with
`AlignVCenter` already applied on both children. Root cause: when a
sibling's implicit height exceeds the row's pinned height, `RowLayout`'s
internal cross-axis centering still keys off that overflowing sibling,
so `AlignVCenter` alone is necessary but not sufficient — the pinned
height must equal the tallest child's real measured height, not an
approximation, and not a value borrowed from a different file's
different content. Re-measure it fresh every time this pattern is
applied; don't copy the number.

**Required reading before writing any QML for the flyout-appletpopup-
rebuild spike.** That surface has more dynamic-content rows than either
`VolumeHoverTooltip.qml` or `VolumeToast.qml` combined, and is exactly
where this lesson needs to actually get applied up front — not
re-discovered a fourth time after the rebuild ships.

## Environment

- OS: CachyOS (Arch-based); Desktop: KDE Plasma.
- Editors: Kate, terminal.
- Rust: `rustup`-free, installed via `pacman -S rust` (Arch/CachyOS repo
  package, not rustup) — 1.97.1 at scaffold time. Workspace edition 2021,
  `rust-version = "1.75"` (MSRV floor is arbitrary/conservative, not tied
  to a specific feature requirement yet — raise it if a later phase needs
  something newer).
- Cargo workspace layout (`Cargo.toml` at repo root, `resolver = "2"`):
  - `crates/protocol` (`devialet-protocol`) — zero-I/O packet
    encode/decode library. No dependencies.
  - `crates/devialet-remote-daemon` (`devialet-remote-daemon`) — status listener binary.
    Depends on `protocol`, `zbus`, `socket2`, `async-io`.
  - `crates/devialet-ctl` (`devialet-ctl`) — single-shot command CLI
    binary. Depends on `protocol` only.
- Pinned/notable dependency versions (latest stable as of the scaffold
  pass — re-check before bumping, don't blindly `cargo update` without
  reading changelogs given how load-bearing zbus's blocking API is here):
  - `zbus = "5"` (5.15.0 at scaffold time). Default features already
    include `blocking-api` (the sync `zbus::blocking::*` API used
    throughout the daemon) and `async-io` (its executor backend) — no
    extra feature flags needed in `Cargo.toml`.
  - `socket2 = "0.6"` — only used for `SO_REUSEADDR` before bind
    (`std::net::UdpSocket` doesn't expose this directly).
  - `async-io = "2"` — depended on directly (not just transitively via
    zbus) because emitting a D-Bus `PropertiesChanged` signal from zbus's
    generated `<property>_changed()` methods is an `async fn` even when
    using the "blocking" API; the daemon drives each one to completion
    with a bare `async_io::block_on(...)` call at the point it needs to
    emit, not a project-wide async runtime. The daemon's own loop (main.rs)
    stays plain synchronous Rust — no `#[tokio::main]`, no `.await`
    scattered through business logic, no spawned tasks. This is an
    implementation detail fully internal to how zbus's blocking wrapper is
    built, not a violation of "no async runtime" — but worth knowing about
    since CLAUDE.md's original architecture note didn't anticipate it.
  - No JSON/serde — nothing here needs it (properties go straight to
    zbus/zvariant types).
- D-Bus service (daemon): bus name `com.ekmanch.DevialetRemote`, object
  path `/com/ekmanch/DevialetRemote/Amp`, interface
  `com.ekmanch.DevialetRemote.Amp1`, session bus. Primary-amp properties
  (unchanged since Phase 3, existing QML bindings): `DeviceName`, `AmpIp`,
  `Online`, `Power`, `Muted`, `VolumeRaw`, `VolumeDb`, `ActiveSourceIndex`,
  `ActiveSourceName`, `Sources` (array of `(name, index, enabled, selected)`
  tuples, 30 entries when an amp is selected/auto-selected, **empty** when
  none is — see below).
  - **Phase 3.5 multi-amp surface**, added alongside the above (no QML
    consumes it yet — that's Phase 4): `KnownAmps` (array of
    `(ip, device_name, online, model_name)` tuples — `model_name` added in
    Phase 3.7, see below — one per amp ever heard broadcasting, not just
    the primary one; never pruned — a gone-quiet amp just flips to
    `online = false` rather than disappearing, `online` using the same 8s
    `STALE_AFTER` rule as the `Online` property). `SelectedAmpIp` (string,
    `""` = no amp *explicitly* selected — mirrors the Kotlin app's
    `SharedPreferences amp_ip` sentinel in `MainActivity.kt`). `SelectAmp(ip:
    String)` method selects by IP (`""` explicitly clears selection, the
    "None" option in the Kotlin app's amp sheet; an IP never heard from yet
    is also accepted, mirroring its manual-IP-entry fallback).
  - Interaction between the two: the primary properties above reflect
    whichever amp `SelectedAmpIp` names. If `SelectedAmpIp` is `""` (nothing
    explicit) **and** exactly one amp is currently known, that amp is
    auto-selected for the primary properties (preserves Phase 3's
    single-amp UX with no picker yet to call `SelectAmp`). With `""` and
    zero or 2+ known amps, the primary properties show the empty/
    not-connected state (`DeviceName`/`AmpIp` `""`, `Online` `false`,
    `Sources` empty, etc.) rather than guessing which one to show.
    Selection is **not** persisted across daemon restarts (in-memory
    only) — deferred to Phase 4, where the picker UI actually drives it.
  - `devialet-ctl` has no knowledge of any of this — it takes `--ip`
    explicitly per invocation and never talks to the daemon or D-Bus (see
    its module doc). This surface is informational only until Phase 4's
    QML reads `AmpIp`/`SelectedAmpIp`/`KnownAmps` and passes the chosen IP
    to `devialet-ctl --ip` itself.
  - **Phase 3.7 mDNS model name resolution**: each known amp's real
    make/model (e.g. "Devialet Expert 140 Pro") is resolved in the
    background over mDNS (`_spotify-connect._tcp`, via the `mdns-sd`
    crate — pure Rust, no async runtime dependency, matching this
    daemon's synchronous loop) and matched against known amps by IP
    (that service type isn't Devialet-specific, so an unmatched IP is
    discarded, never trusted). `KnownAmps`' `device_name` field always
    stays the raw UDP name; a separate `model_name` field (`""` until
    resolved) carries the resolved value. The primary `DeviceName`
    property does `model_name ?: raw_udp_name` — ported exactly from
    `MainActivity.updateDeviceCard()`'s `modelName ?: udpName`/
    `AmpModelNameResolver.parseModelName` (a general letter/digit-boundary
    regex transform, **not** a per-model lookup table — ported to
    `devialet_protocol::parse_model_name` as a hand-rolled char scan, no
    new dependency on the zero-deps protocol crate). Once resolved, never
    re-attempted or cleared.
- **`devialet-ctl` on PATH** (needed by every QML button that shells out to
  it, not just the volume one — mute/power/source in Phase 3 all need this
  too, so it's documented once here rather than per-button):
  - QML invokes it via `Plasma5Support.DataSource`'s executable engine as
    a bare command name (`"devialet-ctl --ip " + ip + " ..."`), **not** an
    absolute path. This is reliable, confirmed empirically rather than
    assumed: the executable engine runs every command through
    `/bin/sh -c "<command>"` (proven by a deliberately-missing command's
    stderr literally reading `/bin/sh: line 1: ...: command not found` —
    that's shell output, not a raw-exec error), so ordinary shell PATH
    resolution applies, using plasmashell's own inherited `PATH`
    (`/home/christian/.local/bin:/usr/local/bin:/usr/bin:/bin:...` at
    scaffold time — confirmed via `/proc/<plasmashell-pid>/environ`, not
    assumed). Failure mode confirmed graceful too: with the binary
    unreachable on PATH, the engine returns exit code 127 and a normal
    shell stderr message, no crash.
  - For this to work, `devialet-ctl` must actually be reachable on that
    PATH. Dev-machine setup (this is **not** yet a real install/packaging
    story — that's a later phase): a symlink at
    `~/.local/bin/devialet-ctl` pointing to the workspace's
    `target/debug/devialet-ctl` build output. `~/.local/bin` is first on
    plasmashell's PATH by default on this system (standard XDG
    convention), so no PATH modification was needed, just the symlink:
    `ln -sf <repo>/target/debug/devialet-ctl ~/.local/bin/devialet-ctl`.
    Re-point or refresh this symlink after every `cargo build` that
    changes `devialet-ctl` (a release build, or real packaging later,
    would install directly to a proper PATH location instead and replace
    this symlink workflow entirely).
- **`spectacle -b -f` from a non-interactive shell needs
  `QT_QPA_PLATFORM=wayland`** (found in Phase 7.2.0): launched from a tool/
  script shell in this Wayland session it otherwise picks the xcb backend,
  and an XWayland grab of a Wayland session is a fully transparent
  3840×2160 PNG with exit code 0 - no error, just empty pixels. Interactive
  terminals don't hit this. `tools/flyout-harness/harness.py` forces the
  variable and fails hard on an all-transparent capture; do the same in any
  other screenshot-driven check rather than trusting a zero exit code.
- **D-Bus `a{ss}` (and any array-of-struct, e.g. `Sources`/`KnownAmps`)
  reaches QML's `Plasma.DBusProperties` as an opaque `QDBusArgument`** with
  no visible keys/length - re-confirmed in Phase 7.2.0 for a dict, not just
  the array case `test-scaffold/watch.qml` documents. Scalars round-trip
  fine; for structured control data prefer a JSON string (`s`) property
  (what the harness's `UiState` does) over a dict type.
- Package manager / tooling: `pacman` (system Rust, Qt6, zbus/socket2/
  async-io via Cargo from crates.io). Qt6 dev tooling (`qmake6`,
  `qt6-base`, `qt6-declarative`) and a C++ compiler are present on this
  machine already (checked during the cxx-qt vs. daemon architecture
  discussion) but are **not** used by anything in this repo — no C++ is
  compiled here; their presence was only relevant to a rejected
  alternative (see "In-process alternative (cxx-qt) considered and
  rejected" above).
- Repo: `devialet-expert-remote-widget`.

## Repository Layout

devialet-expert-remote-widget/
├── Cargo.toml                      # workspace root
├── CLAUDE.md
├── README.md
├── crates/
│   ├── protocol/                   # dependency-free library crate: packet
│   │                                #   encode/decode, CRC16, dbConvert,
│   │                                #   source remap table. No sockets, no async.
│   ├── devialet-remote-daemon/     # long-running UDP status listener; pushes
│   │                                #   live state to QML via D-Bus (zbus),
│   │                                #   properties + PropertiesChanged, no polling
│   └── devialet-ctl/               # single-shot command CLI (volume/mute/power/
│                                    #   source), invoked from QML via
│                                    #   Plasma5Support.DataSource's executable engine
├── plasmoid/                       # KPackage root. Passed directly to
│   │                                #   `kpackagetool6 -t Plasma/Applet -i plasmoid/`
│   │                                #   — do not nest further (no plasmoid/package/).
│   │                                #   This shape is dictated by KPackage, not
│   │                                #   arbitrary; don't "clean it up."
│   ├── metadata.json
│   └── contents/
│       ├── ui/                     # main.qml, FullRepresentation.qml, etc.
│       └── config/                 # config.qml + main.xml + the "General"
│                                    #   ConfigDialog page (Phase 4.4.0) — see
│                                    #   "Settings ConfigDialog" above for the
│                                    #   ConfigCategory.source path-resolution
│                                    #   gotcha this layout runs into (fixed
│                                    #   with a "../config/" source prefix).
├── systemd/
│   └── devialet-remote-daemon.service   # user unit (Restart=on-failure) for
│                                    #   `systemctl --user enable`, per the settled
│                                    #   decision to use systemd over XDG autostart
└── docs/
    ├── protocol.md
    ├── known-gotchas.md
    ├── app-overview.md
    └── devialet_source_mapping.md

Notes:
- The `crates/` vs `plasmoid/` split mirrors the Rust-does-logic /
  QML-does-UI boundary — if you're touching protocol or D-Bus logic, you're
  in `crates/`; if you're touching layout, theming, or the flyout, you're in
  `plasmoid/`.
- `plasmoid/` and `systemd/` are shaped by their respective tools
  (`kpackagetool6`, `systemctl --user`), not by project convention — resist
  restructuring them without checking what each tool expects first.

## Related repos

- Android (Kotlin, source of truth for protocol): 
  https://github.com/ekmanch/devialet-expert-remote
- Flutter port (Android/iOS, in progress, independent port of the same
  protocol): https://github.com/ekmanch/devialet-expert-remote-app
  
## Known issues

***  sub-pixel corner seam under Darkly theme (accepted, not a bug to re-investigate) ***

The flyout's corner radius uses `Kirigami.Units.cornerRadius` (matches
Darkly's real Dialog/window corner size, e.g. 5 on this system) rather
than a hardcoded value — this fixed the original "box within a box"
and gross corner-artifact bugs (see Phase 4.0/4.1 history).

A very faint residual seam can still be seen at the corners against a
solid dark background, if you look for it. Root cause, confirmed by
reading Darkly's actual SVG path data
(`/usr/share/plasma/desktoptheme/darkly/dialogs/background.svg`,
`topleft` group): Darkly's corner is a **custom cubic Bezier curve**
(`M 0,6 H 6 V 0 C 2,0 0,2 0,6`, kappa ≈ 0.667), not a true circular
arc (kappa ≈ 0.5523). Qt Quick's `Rectangle.radius` always renders a
mathematically true circular arc. Matching the *radius value* (done)
gets the two curves to agree at their shared endpoints, but the curve
*shapes* diverge slightly in between — at 1:1-ish unit scale on this
system that divergence lands at sub-device-pixel scale, which shows as
an antialiasing-level seam only visible against high-contrast (solid
dark) backgrounds, not against light backgrounds or blurred wallpaper.

Deliberately NOT fixed further: the only way to fully close this is to
hand-replicate Darkly's exact Bezier curve via `QtQuick.Shapes`
instead of `Rectangle.radius`. That would hardcode the widget to one
specific theme's corner math and silently render incorrectly (same
seam or worse) under any other Plasma theme with a different corner
curve — a worse failure mode than a near-invisible seam under Darkly
specifically. If this is ever revisited, do so only alongside testing
against multiple Plasma themes, not just Darkly.

Do not re-open this as a fresh bug investigation without reading this
note first — it's been root-caused and the remaining artifact is an
accepted trade-off, not an unexplained regression.

**Update (Phase 7.12.0, 2026-09-05, closed)**: the paragraphs above
describe the pre-Dialog (`AppletPopup`-hosted) flyout, where Darkly's
own frame SVG was still drawn underneath our tint Rectangle — the seam
was two different corner curves layered on top of each other (our
`Rectangle.radius`'s true circular arc vs Darkly's real frame SVG's
cubic-Bezier corner). Phase 7.10.0's rebuild onto `PlasmaCore.Dialog`
with `backgroundHints: NoBackground` removes that second curve
entirely — `NoBackground` clears Darkly's frame SVG's own image path
(`dialogBackground->setImagePath(QString())`, confirmed in
`dialog.cpp`), so there is nothing left underneath for our own corner
radius to seam against. Phase 7.12.0 verified this live rather than
assuming it from the header change alone: the project owner opened the
real flyout against a solid dark background (the same high-contrast
condition this section originally named as where the seam was
visible) and reported no corner artifacts; independently re-verified
by locating the flyout's exact pixel bounds via a raw pixel scan (the
panel tint and that particular dark background were close enough in
value that the edge wasn't obvious by eye) and inspecting all four
corners at 12x zoom — each shows one single smooth anti-aliased curve,
no double-border, no box-within-box artifact. No code change was made
or needed; the setting/toggle investigation this trade-off's own
"if this is ever revisited" clause anticipated is now moot, since
there's no seam left to bypass. This closes the seam as a live issue
on the current `Dialog`-based flyout — the mechanism/history above
stays accurate as an explanation of the old `AppletPopup`-era
behavior, and would still apply if the flyout were ever hosted in a
popup class with a real background frame again.

***  real transparency was investigated and found infeasible from applet code (settled, do not re-attempt without new evidence) ***

Investigated on the now-deleted `experiment/real-transparency` branch.
Initial theory: this widget's popup uses Plasma's default background
frame, which (for Darkly specifically) is hardcoded fully opaque -
confirmed by reading Darkly's `dialogs/background.svg` and its active
color scheme's alpha-less RGB values directly. The fix was assumed to
be `Plasmoid.backgroundHints = NoBackground`.

That assumption turned out to be built on the wrong class entirely.
Runtime diagnostics (walking `root.Window.window` and logging the
actual class) showed this widget's popup is a `PlasmaWindow`
(`PlasmaQuick::AppletPopup` → `PopupPlasmaWindow` → `PlasmaWindow`, a
newer, 2023-era class), not `PlasmaQuick::Dialog` as originally
assumed - all of the initial investigation's C++ source reading was
of the wrong header. `PlasmaWindow`'s real `BackgroundHints` enum
(confirmed in its actual header) has only `StandardBackground` and
`SolidBackground` - **no `NoBackground` value exists at all** for this
window class, on this Plasma version. There is no applet-level API to
remove the frame image entirely.

Separately confirmed: visible transparency/blur seen under other
Plasma themes (e.g. Ant-Dark) on other widgets (Kickoff, Digital
Clock, weather widgets) is not those widgets doing anything special in
code - it's the *theme's own* `dialogs/background.svg` frame asset
having genuine partial opacity baked in by the theme author. Every
applet using the default background picks this up automatically, with
zero code, purely because the shared system frame image itself is
translucent under that theme. An individual applet has no ability to
choose or override which theme's frame asset the user has selected,
and no ability to make a theme's opaque frame asset translucent from
the outside.

Conclusion: genuine, controllable desktop transparency is not
achievable from applet-level QML on this Plasma version, regardless of
theme. It is a property of the user's chosen Plasma theme's own frame
asset, entirely outside this widget's control. Feature dropped
entirely (see TODO.md). Do not re-attempt without first confirming a
fundamentally different Plasma API is available (e.g. a future
`PlasmaWindow::BackgroundHints` value, or migration back to a window
class that does expose `NoBackground`).

**Update (Phase 7.9.0+, follow-up correction)**: the conclusion above is
still accurate for what it actually tested - the *shell-managed* popup
(`CompactApplet.qml`'s own `AppletPopup`), which has no `NoBackground`
option. It was never a conclusion that a *hand-built* popup couldn't do
better - escaping exactly that limitation was the stated reason Phase 7.x's
flyout rebuild exists at all, and this section's own last sentence already
named the escape hatch ("migration back to a window class that does expose
`NoBackground`"). Phase 7.0.0-7.8.0 then built a hand-rolled popup, but
chose `PlasmaCore.AppletPopup` for it - the same `PlasmaWindow`-family class
already confirmed above to have no `NoBackground` value, reproducing the
identical limitation this section describes. That choice was made on
dismiss/focus/positioning-risk grounds without re-checking it against the
transparency goal; see TODO.md's Phase 7.0.0 entry for the correction and
Phase 7.9.0+ for the fix in progress (`PlasmaCore.Dialog`, which - unlike
`PlasmaWindow` - has a real, code-enforced `NoBackground` value, confirmed
directly in `dialog.cpp`, and is what `VolumeHoverTooltip.qml`/
`VolumeToast.qml` already use successfully).
Phase 7.10.0 (2026-09-05) then shipped that rebuild — `FlyoutPopup.qml`
on `PlasmaCore.Dialog` with `NoBackground` — and measured real
transparency on the real flyout for the first time (same-patch
closed-vs-open capture: blend error 0.35 at α 0.82 vs 7.08 for opaque
paint; wallpaper visible through the panel). So the "infeasible" verdict
above stands only for the shell-managed popup class; this widget's own
flyout window is no longer in that class.