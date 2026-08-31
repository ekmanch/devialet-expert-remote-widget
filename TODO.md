# TODO / Roadmap

Tracks phase status for devialet-expert-remote-widget. See CLAUDE.md for
architecture decisions; this file is just sequencing and status.

## Done

- [x] **Phase 1 — protocol + daemon + CLI scaffold.** Cargo workspace,
      28/28 protocol tests passing, clippy clean. Verified live: daemon
      receives/parses real UDP status broadcasts, devialet-ctl controls
      source/power/volume/mute against the real amp, D-Bus
      PropertiesChanged confirmed firing via busctl.
- [x] **Phase 2 — minimal working tray plasmoid.** Plasma 6 system tray
      icon + flyout, live-updating volume display bound to the daemon's
      D-Bus properties, one working command (-1dB button) round-tripped
      against the real amp. No styling, no other controls yet.
- [x] **Phase 2.5 — cleanup.**
  - devialet-ctl resolved via PATH instead of a hardcoded dev-machine
    path (executable engine invokes via `/bin/sh -c`, so shell PATH
    resolution applies — documented in CLAUDE.md + README).
  - D-Bus reactivity claim corrected from "documented upstream
    limitation" to explicitly-labeled inference (no matching report
    found on a bounded search); imperative `onPropertiesChanged`
    workaround unaffected.
- [x] **Phase 3 — full functional controls, default styling.** Volume
      slider + step buttons, mute toggle, power toggle, source picker —
      all bound to real D-Bus properties, all confirmed round-tripping
      against the real amp (both via my own `busctl`/`devialet-ctl`
      checks and your real-tray clicks). No copper/graphite theming, no
      amp picker, no settings view yet.
  - Debounce ported directly from MainActivity.kt (verified against that
    source, not reconstructed from memory): button steps use a sliding
    400ms window (each step resets the timer); the slider only sends +
    stamps its timestamp once, on release; a separate `volumeInteracting`
    flag blocks all incoming volume pushes for the whole duration of an
    active drag or button-hold, independent of the timestamps. Mute/
    Power/Source get a single-shot 400ms window too (not in the Kotlin
    app, but explicitly requested for consistency - a deliberate
    addition, not silent parity drift).
  - Volume range: -15dB ceiling is code-enforced (`MAX_VOLUME_DB` in the
    protocol crate); -60dB floor is a UI convention only (matches the
    Kotlin app's own slider bounds) - **not** enforced anywhere in Rust.
  - Confirmed by reading devialet-ctl's source: the forced -40dB
    post-source-switch volume is already handled inside `devialet-ctl
    source`, not something QML needs to send separately.
  - Volume label bug: the display was bound to `root.volumeDb` (only
    updated on release) instead of the slider's own live `value`, so it
    stayed static during a drag. Fixed by binding the label to
    `volumeSlider.value` directly, which tracks the drag continuously
    regardless of when the actual send happens.
  - Source ComboBox saga, root-caused with wire-level evidence rather
    than left as an unsubstantiated workaround:
    1. Popup wouldn't open at all inside `PlasmoidItem`'s
       fullRepresentation (real tray only, not `plasmawindowed`). Fixed
       by switching to `org.kde.plasma.components.ComboBox`, grounded in
       real evidence: no installed plasmoid on this machine uses
       QtQuick.Controls' ComboBox inside its actual popup content (only
       in separate config dialogs), and PlasmaComponents3's own
       ComboBox.qml source contains an explicit comment + linked QTBUG
       acknowledging QQC2 Popup behaves incorrectly outside a genuine
       top-level Window.
    2. Regression after that fix: dropdown greyed out, popup still
       wouldn't open. Root-caused via `busctl monitor` independent of
       QML: the daemon emits `Sources` correctly on every single
       `PropertiesChanged` cycle (confirmed both from the wire, 60/600
       signals over 6s, and from the daemon's own source -
       `apply_and_emit()` has no equality check), but the signal's own
       delta payload becomes unusable client-side after the first
       delivery (confirmed via `JSON.stringify` showing a real array
       once, then a genuinely empty result every time after - not just
       inconsistently wrapped, unlike every scalar property). Matches a
       documented general QtDBus behavior (complex types inside a
       PropertiesChanged payload are left undemarshalled) - cited, not
       just asserted this time.
    3. Fix: on receiving a `PropertiesChanged` signal mentioning
       `Sources`, explicitly issue a fresh `org.freedesktop.DBus.
       Properties.Get` call via `Plasma::DBusConnection.asyncCall` and
       use that reply instead of trusting the signal's own payload -
       still fully push-driven, no polling. Two real API gotchas hit and
       fixed along the way (both confirmed by logging actual runtime
       shapes, not assumed): `DBusMessage`'s constructor needs the key
       `interface`, not the `iface` alias used everywhere else in this
       codebase; `asyncCall`'s resolve callback receives the whole
       `DBusPendingReply` object, needing `.value` on it.
    4. Verified at the wire level sustained over 15s in the real tray:
       98 explicit Get calls, all replies carrying the complete 30-entry
       array, zero malformed ones.
  - Final full four-control re-verification (post source-dropdown fix),
    confirmed independently via `busctl`/`devialet-ctl`: power on/off,
    mute on/off, volume set, and source switch (with forced -40dB) all
    round-trip correctly against the real amp.

- [x] **Phase 3.5 — multi-amp daemon support.** Daemon-only, no QML changes
      (Phase 4 builds the picker against this). Design proposed and
      confirmed before implementing (see CLAUDE.md's D-Bus service bullet
      for the settled shape) rather than silently picked.
  - `AmpState` (interface.rs) now tracks every amp ever heard broadcasting
    (`amps: HashMap<ip, TrackedAmp>`, never pruned) alongside an explicit
    `selected_ip` (`""` = none — ported from `MainActivity.selectedIp`'s
    SharedPreferences sentinel, confirmed by reading that source rather
    than guessing). Exposes it all on the *same* object/interface Phase 3's
    QML already binds to, not a replacement: `KnownAmps` (array of
    `(ip, device_name, online)`), `SelectedAmpIp`, `SelectAmp(ip)` method,
    alongside the existing primary properties (now driven by the selected/
    auto-selected amp instead of "whichever broadcast most recently").
  - Investigated (not assumed) how `devialet-ctl` targets an amp: it takes
    `--ip` explicitly per invocation and has zero daemon/D-Bus interaction
    — confirmed by reading its source. This phase's selection surface is
    therefore informational only until Phase 4's QML reads it and passes
    the IP to `devialet-ctl --ip` itself.
  - Auto-select-if-alone: with nothing explicitly selected and exactly one
    known amp, that amp drives the primary properties (avoids a
    "Not connected" regression before Phase 4's picker exists to call
    `SelectAmp`); with zero or 2+ known amps and nothing explicit, primary
    properties show the empty/not-connected state instead of guessing.
    Selection is in-memory only, not persisted across daemon restarts —
    deferred to Phase 4.
  - Protocol crate gained a public `fixtures::StatusFixtureBuilder`
    (promoted from a test-only private struct, now shared by the
    protocol crate's own tests too) so downstream crates can build
    realistic synthetic status packets without hand-rolling wire bytes.
  - **Automated tests** (8 new, `interface::tests`, all passing): two
    distinct synthetic amps built via `StatusFixtureBuilder` → real
    `parse_status` → `AmpState::ingest_status`, confirming they're tracked
    as separate `KnownAmps` entries (not overwritten), plus coverage of
    auto-select-if-alone, not-connected fallback with 2+ amps, explicit
    selection (known and unknown IPs), clearing back to `""`, and stable
    IP-sorted ordering. Full workspace: 36/36 tests, clippy clean.
  - **Live verification against real hardware + a synthetic second amp**
    (2026-08-22): added alias IP `192.168.0.222/24` on `eno1` (real amp at
    `192.168.0.134`'s subnet, real amp itself broadcasting from
    `192.168.0.22` as "My Devialet-ETH"). A throwaway test-sender (reused
    `devialet_protocol::fixtures`/`parse_status` wire format, not
    hand-rolled) broadcast a synthetic "SYNTH-TEST-AMP" from the alias IP
    at ~1s intervals. Confirmed via `busctl`: `KnownAmps` correctly showed
    both amps simultaneously by distinct IP; with nothing selected the
    primary properties correctly fell back to not-connected (2 known
    amps); `SelectAmp` round-tripped for both the synthetic and real amp
    IPs and for the `""` "None" clear, each confirmed via property reads
    and (for one case) a `busctl monitor` capture showing the actual
    `PropertiesChanged` signal firing on the wire. After stopping the
    synthetic broadcaster, confirmed (wire-level `busctl monitor` capture)
    that it flips to `online = false` in `KnownAmps` within one staleness
    tick (~1s) without being evicted — matches the deliberate "never
    prune" design — while the explicitly-selected real amp's own
    properties were unaffected. IP alias removed after testing and
    confirmed gone via `ip addr show dev eno1` (only the original
    `192.168.0.134/24` remains, no `secondary` entry left behind).
  - **Assumed, not verified:** behavior with three or more simultaneous
    amps (only two were feasible to test here — one real, one synthetic);
    the two-known-amps "not connected" fallback is exercised, but a
    three-way disambiguation UX (if one is ever needed beyond "explicit
    selection required") is unverified. Cross-daemon-restart behavior
    beyond "resets to no explicit selection" (i.e. real persistence) is
    unimplemented by design, not just untested — deferred to Phase 4.

- [x] **Phase 3.6 — systemd unit: create, enable, and verify.**
  - `systemd/devialet-remote-daemon.service` created. Investigated rather
    than assumed: `main.rs` takes no CLI args, reads no config file, has
    no working-directory dependency, and only one optional env var
    (`DEVIALET_DAEMON_DEBUG`, off by default) — so `ExecStart` needs
    nothing but the binary path. Confirmed the real release binary lands
    at `target/release/devialet-remote-daemon` (workspace-root `target/`,
    binary name matches package name, no `[[bin]]` override) by actually
    building it, not assumed from the crate directory name.
  - `WantedBy=plasma-workspace.target`: CLAUDE.md listed this "(or
    graphical-session.target)" without picking, so checked the real
    dependency graph on this machine (`systemctl --user show
    plasma-workspace.target`) — it has `Requires=graphical-session.target
    plasma-core.target`, i.e. it's strictly downstream, so activating it
    guarantees the full graphical session (D-Bus session bus included) is
    already up. Matches CLAUDE.md's first-listed option.
  - `ExecStart` in the committed unit is a placeholder (`@@EXECSTART@@`)
    resolved via `sed` at install time (README's new "Daemon autostart"
    section) — same "no fixed install location yet" category as the
    existing `devialet-ctl` PATH symlink docs, not a new pattern.
  - **Verified myself, with evidence (2026-08-22):**
    1. `systemctl --user enable` succeeded (created the
       `plasma-workspace.target.wants/` symlink); `is-enabled` reported
       `enabled`.
    2. `systemctl --user start` succeeded; `status` showed
       `active (running)`, PID 19574; confirmed the actual D-Bus surface
       (not just "a process exists") via `busctl introspect` and live
       property reads — `DeviceName`/`Online`/`VolumeDb`/`KnownAmps` all
       reflected the real amp's current state while running under
       systemd.
    3. Crash recovery: `kill -9` on PID 19574; systemd's journal logged
       "Scheduled restart job, restart counter is at 1"; new PID 19606
       came up automatically; re-confirmed the D-Bus interface was
       reachable again (not just a new process) via a fresh
       `busctl get-property` read on the restarted instance, matching
       real amp state.
  - **Reboot autostart confirmed by you (2026-08-22):** after a real
    reboot, `systemctl --user status devialet-remote-daemon.service`
    showed `active (running)` since login, PID 978 (low PID consistent
    with an early-boot start, not one you launched by hand), `enabled;
    preset: enabled`. You also cross-verified the whole pipeline
    end-to-end for real, beyond what this unit alone covers: changes made
    in the Kotlin Android app reflected on both the amp and the KDE
    widget, and changes made in the KDE widget reflected on both the amp
    and the Android app.

- [x] **Phase 3.7 — mDNS amp model name resolution.** Daemon-only, no QML
      changes (mirrors Phase 3.5's shape - D-Bus surface addition, no UI
      yet).
  - Investigated rather than assumed: read `AmpModelNameResolver.kt`
    directly. Service type is `_spotify-connect._tcp` - not
    Devialet-specific, so resolved names are only trusted for an IP
    already known from a real UDP broadcast (ported guard, matches
    `discoveredAmps[ip]?.let { ... }` in `MainActivity.kt`). The
    hostname→display-name mapping is **not** a lookup table - it's a
    general regex transform (`parseModelName`, the resolver's companion
    object): strip everything from the first `-` onward, insert a space
    at every letter→digit boundary and every digit→uppercase-letter
    boundary (digit→lowercase is deliberately *not* a boundary), prefix
    `"Devialet "`. Ported to `devialet-protocol::parse_model_name` as a
    hand-rolled char scan (no `regex` dependency - keeps the protocol
    crate at zero external deps) with 9 unit tests covering the general
    algorithm (multiple boundaries, no digits, leading digits, the
    digit→lowercase non-boundary case, empty/no-hyphen edge cases), not
    just the one real "Expert140Pro" example.
  - Resolution is async/best-effort, confirmed by reading the Kotlin
    resolver (NSD's own listener-callback API, never blocks the caller) -
    mirrored daemon-side via `mdns-sd` (chosen over alternatives for being
    pure Rust, no C/C++ dependency, and "no async runtime dependency" by
    its own design, fitting this daemon's synchronous loop with zero
    tokio/async-std pull-in; actively maintained - 79 published versions,
    latest 10 days old, ~1.8M recent downloads). A single continuous
    `browse()` session starts once at daemon startup for the whole
    process lifetime; every `ServiceResolved` event is drained
    non-blockingly once per main-loop iteration (not gated to the 1s
    staleness tick, so a burst of real UDP packets can't starve it) and
    matched against known amps by IP.
  - Resolution policy stated explicitly: one continuous browse, not
    per-amp or scheduled-retry. Initially stated this as "`mdns-sd`
    already re-queries/refreshes its cache internally per RFC 6762"
    without having actually verified it by reading the crate's source -
    caught on review and checked properly (2026-08-22): confirmed via
    `dns_cache.rs`'s `refresh_due_ptr`/`refresh_due_srv_txt`/
    `refresh_due_hosts` (citing RFC 6762 §7.1 for refresh timing), called
    every iteration of the daemon's own event loop via
    `refresh_active_services()` (`service_daemon.rs:1622`), which sends
    real re-queries (`send_query`/`send_query_vec`) as cached records'
    TTLs approach expiry - not dead code, not just a doc claim. So
    Android's own manual restart-burst workaround
    (`RETRY_DELAYS_MS`/`STEADY_INTERVAL_MS` in `AmpModelNameResolver`)
    wasn't ported: that mechanism exists specifically to compensate for
    Android's `NsdManager` being slow to re-query, not a general mDNS
    requirement. Once an amp resolves, it's
    never re-attempted or cleared - matches the Kotlin app.
  - `KnownAmps` gained a 4th tuple field (`model_name`, `""` until
    resolved; wire signature `a(ssb)` → `a(ssbs)`) - safe to change since
    nothing consumes `KnownAmps` yet (Phase 4 builds against whatever this
    phase produces). Its `device_name` field deliberately still shows the
    raw UDP name even once resolved (a future picker needs both - main
    label vs. subtitle, the way the Kotlin app's device card does).
  - The primary `DeviceName` property (and nothing else - `AmpIp` etc.
    unchanged) now does `modelName ?: udpName` exactly like
    `MainActivity.updateDeviceCard()`, same porting approach as
    `SelectedAmpIp`/`selectedIp` in Phase 3.5: same property name/shape
    Phase 3's QML already binds to, just a different data source behind
    it.
  - **Automated tests**: 9 new in the protocol crate
    (`model_name::tests`, the general mapping algorithm) + 4 new in the
    daemon (`interface::tests`: resolving a known amp updates `KnownAmps`
    and becomes the primary `DeviceName`; resolving an IP never heard
    over UDP is rejected; unresolved falls back to the raw UDP name;
    a resolved name survives a later UDP broadcast from the same amp
    without being wiped). Full workspace: 50/50 tests, clippy clean.
  - **Live verification against the real amp**: captured the actual mDNS
    advertisement first rather than assuming it matched the Kotlin doc's
    example (`avahi-browse -r _spotify-connect._tcp`) - confirmed
    `hostname = Expert140Pro-K48A00904ZE1V.local`, `address =
    192.168.0.22`, matching the real amp. Ran the daemon (both a manual
    debug-logged instance and, afterward, the real systemd-managed
    instance from Phase 3.6, rebuilt with this phase's code) and
    confirmed via `busctl`: `KnownAmps` showed
    `("192.168.0.22", "My Devialet-ETH", true, "Devialet Expert 140
    Pro")` and the primary `DeviceName` property read `"Devialet Expert
    140 Pro"` - both the raw UDP name and the resolved model name visible
    simultaneously in the right places. Confirmed via the debug log that
    normal UDP status processing (90+ packets, steady cadence) was
    unaffected/undelayed by mDNS resolution running alongside it, and
    that the resolved name persisted correctly across every subsequent
    UDP broadcast from the same amp (carry-forward, not wiped every ~1s).
  - **Assumed/not caught live**: the "resolution hasn't completed yet"
    fallback window - on this LAN, mDNS resolution completed too fast
    (under ~0.6s) to observably race against a fresh daemon start, so the
    pre-resolution raw-UDP-name state is proven by the deterministic unit
    test (`unresolved_model_name_falls_back_to_raw_udp_device_name`) and
    code inspection (`TrackedAmp.model_name` defaults to `None` until
    `resolve_model_name` is explicitly called), not by a live capture of
    that specific window. Behavior when mDNS is entirely unavailable
    (`ServiceDaemon::new()`/`browse()` failing outright - e.g. no usable
    network interface) is designed to degrade gracefully (logs a warning,
    daemon continues UDP-only) but wasn't exercised live, since mDNS
    worked normally in this environment throughout.

- [x] **Phase 4.0 — Main view mockup styling.** Re-skinned the existing,
      already-functional Phase 3 main view to match
      `devialet_tray_flyout_mockup.html`. Pure visual pass — every D-Bus
      binding, debounce timestamp, and the ComboBox's popup/delegate
      internals (Phase 3's hard-won fix) are untouched; only restyled via
      `background`/`contentItem`/`indicator` overrides.
  - **Fonts**: investigated rather than assumed where they need to live.
    `design/font/` is a source/reference location outside the KPackage
    payload (`kpackagetool6` only installs what's under `plasmoid/` —
    confirmed via CLAUDE.md's Repository Layout), so the 7 `.ttf` files
    were copied to `plasmoid/contents/fonts/`, loaded via
    `FontLoader { source: Qt.resolvedUrl("../fonts/...") }` — a real
    precedent found and followed, not invented: `org.kde.plasma.
    advanced-weather-widget` ships fonts the same way. Confirmed live
    (`qml6`, this machine) that all weight-variant files of a family
    report the *same* `font.family` string with correctly distinct
    `font.weight` (400/500/600/700 for Space Grotesk, 400/500/600 for
    JetBrains Mono — exactly the weights the mockup's Google Fonts import
    requests, and exactly the files present), so standard Qt font-weight
    matching applies once all variants are loaded. `--font-body` (Inter)
    has no bundled file (only Space Grotesk/JetBrains Mono were provided)
    — deliberately not fetched; body text the mockup styles with Inter
    falls back to Plasma's system UI font instead, flagged in `Theme.qml`
    as a documented substitution, not a silent gap.
  - **Blur-behind — investigated, then a design fork flagged for review
    before implementing (not picked silently)**: confirmed via
    `PlasmaQuick::Dialog`'s own header that genuine KWin blur-behind on a
    popup is automatic and tied to the Dialog's `backgroundHints` (its
    doc comment: `NoBackground` is what "loses kwin side shadows and
    blur", implying the default keeps them) — not something a plasmoid
    requests itself, and confirmed no QML-exposed
    `KWindowEffects::enableBlurBehind` exists in `org.kde.kwindowsystem`'s
    QML module (read its qmltypes), so a fully custom-drawn background
    would genuinely lose blur with no way to fake it in pure QML (no
    live desktop content to grab from within the plasmoid's own scene).
    Presented the fork; chosen: leave `Plasmoid.backgroundHints` unset
    (Plasma's normal default, real blur-behind, matches every other stock
    tray popup) and layer the flyout's own semi-transparent copper/
    graphite gradient `Rectangle` on top — mirrors the mockup's own CSS
    technique exactly (`backdrop-filter:blur` **plus** a semi-transparent
    gradient tint, not blur alone). Caveat carried forward: the outer
    corner-radius/shadow chrome comes from the current Plasma color
    scheme's own dialog background asset, not a pixel-identical copy of
    the mockup's exact values.
  - **Open/close pop animation**: bound to `Plasmoid.expanded`/
    `expandedChanged`, not `Component.onCompleted` — whether
    `fullRepresentation` is recreated fresh per open or instantiated once
    and reused isn't determinable from QML alone (`fullRepresentation`/
    `fullRepresentationItem` split confirmed via `plasmoidplugin.
    qmltypes`, consistent with either lifecycle), and `onCompleted` would
    silently only fire once in the reused case. On by default, no way to
    disable yet (that's Phase 4.3's reduce-motion toggle) - matches the
    task.
  - Settings trigger ("⋯", top-right) added, wired as an explicit no-op
    with a `TODO(Phase 4.3)` comment — not left silently unwired.
  - Root changed from `ColumnLayout` to `Item` (needed for the
    settings-trigger's absolute positioning and the background overlay
    layering, which a `ColumnLayout`'s single-column child flow can't do)
    — `Layout.minimumWidth/Height` from Phase 2/3 dropped as part of
    this, confirmed dead weight either way (root was never a child of
    another Layout, so those attached properties never did anything).
  - New `Theme.qml` centralizes the palette/font-family/spacing constants
    ported 1:1 from the mockup's `:root` CSS custom properties - plain
    `QtObject`, not `pragma Singleton` (no qmldir/module registration set
    up for a true singleton in this KPackage; one shared instance per
    `FullRepresentation` is all a tray popup ever needs).
  - Footer text simplified from the mockup's literal live-ticking
    "Updated Xs ago" to a static "Connected"/"Not responding"/"Not
    connected" (driven by existing `online`/`ampIp` state only) - a
    ticking counter would need a new local timestamp + Timer, which
    felt like it crossed from "restyle" into "new behavior" even though
    it wouldn't touch any D-Bus/backend surface. Flagging the
    simplification rather than silently picking either extreme.
  - Mute/power icons use Kirigami symbolic icons (`audio-volume-muted-
    symbolic`, `system-shutdown-symbolic` - confirmed present in the
    installed icon theme before using them) rather than recreating the
    mockup's exact inline SVG paths - visually analogous, not a pixel
    copy.
  - **Verified myself**: `plasmoidviewer` isn't installed on this
    machine, so used a direct `qml6` load of `FullRepresentation.qml`
    (via a standalone harness importing the real `plasmoid/contents/ui/`
    directory) as the closest available check - genuinely caught two real
    bugs before they'd have hit the real tray (a missing
    `org.kde.plasma.plasmoid` import, and several `font.pixelSize`
    fractional values QML's `int` type rejects outright, e.g. `9.5`).
    After fixing both: zero QML warnings/errors on load, and a
    `grabToImage` render (screenshot inspected directly) confirms the
    layout, fonts, colors, and live D-Bus data (this dev machine's real
    daemon/amp) all render correctly end-to-end - close visual match to
    the mockup. `qmllint` on this machine is a Qt5 build (version
    string "1.0") incompatible with the Qt6/KDE6 QML modules used here
    (silent failure, exit 255, no usable output) - noted rather than
    treated as a clean bill of health from a tool that can't actually
    parse this code.
  - **Needs a real human check in the actual tray (not verified by me)**:
    whether KWin blur-behind is actually visible/on for this specific
    popup in practice (depends on the user's live KWin Blur effect state
    and active color scheme, neither reproducible in an offscreen qml6
    harness); whether the pop animation actually plays correctly on
    every real popup open/close (the `Plasmoid.expanded`-driven approach
    is designed to be lifecycle-agnostic per the reasoning above, but
    this is exactly the kind of thing that needs eyes on the real tray,
    not code review); whether the restyled ComboBox's popup still opens
    correctly with the new `background`/`contentItem`/`indicator`
    overrides (Phase 3's hard-won `popup`/`delegate` internals were left
    untouched, but the surrounding overrides weren't exercised through a
    real click in this environment); general "does it actually look
    right" fit/finish.
  - Explicitly did not start any Phase 4.1/4.2/4.3 scope (amp-list
    interactivity, persistence, or the settings view's actual content) -
    the settings trigger and amp header are static/no-op by design this
    phase.

- [x] **Architecture change — panel-pinned instead of system tray.**
      This widget no longer registers as a system tray item; it installs
      as a normal panel applet (drag onto the panel via "Add Widgets",
      like Digital Clock or Compact Pager). Full reasoning logged in
      CLAUDE.md's "Panel-pinned, not a system tray plasmoid" bullet - not
      repeated here.
  - `metadata.json`: removed `X-Plasma-NotificationArea` and
    `X-Plasma-NotificationAreaCategory` - the two keys that actually
    controlled tray eligibility. Nothing else in `metadata.json` changed.
  - QML structure needed no changes: `PlasmoidItem` +
    `compactRepresentation`/`fullRepresentation` in `main.qml` is the same
    structure regardless of tray-hosted vs. panel-pinned (confirmed
    against `com.github.tilorenz.compact_pager`). The Phase 4.0.1
    box-in-box background fix in `FullRepresentation.qml` also needed no
    code changes - only its comments, which had baked in the
    now-obsolete tray-hosting assumption, were corrected.
  - Verified live, not assumed: widget added to a real panel (via the
    Plasma scripting API as a stand-in for a manual "Add Widgets" drag),
    confirmed `"inTray": false` in `dumpCurrentLayoutJS`, clicked for
    real, and screenshotted - clean copper/graphite panel, no
    back-arrow, no title bar, no navy frame, edge to edge, matching the
    mockup, identical with or without other windows open on the desktop.
  - Reload workflow (`kpackagetool6 --upgrade` + `plasmashell --replace`)
    confirmed unchanged - the only actual difference is that the widget
    no longer appears in the system tray's own "configure visible icons"
    list, only in the normal Plasma widget list.
  - Cosmetic fixup while in there: the flyout's decorative scroll hint
    now reads "Scroll over the panel icon to adjust" (was "the tray
    icon") - text only, Phase 4.4 (renamed from 4.1, see below) still
    owns actually implementing scroll-to-adjust.
  - Did not touch: the MPV Lua scroll-redirect concept (separate,
    parked item below, revisited later with more detail) or start any
    Phase 4.1/4.2/4.3/4.4 scope.

- [x] **Phase 4.1 — Amp picker UI.** Styled using 4.0's copper/graphite/
      Space Grotesk/JetBrains Mono language throughout, built against Phase
      3.5's existing `KnownAmps`/`SelectedAmpIp`/`SelectAmp` D-Bus surface.
      No persistence — the picker has no awareness that Phase 4.2 exists;
      it just calls `SelectAmp` on user action, unchanged from how it
      always would.
  - Amp header (`FullRepresentation.qml`) made clickable — whole row, not
    just a sub-element, wrapped in a `Rectangle`+`MouseArea` rather than
    putting the `MouseArea` directly in the header `RowLayout` (which would
    only occupy one layout cell). Toggles `root.ampListOpen`, driving an
    animated (`clip: true` + `Behavior on implicitHeight`) collapsible list
    below the header, caret rotates open/closed.
  - `KnownAmps` is the same array-of-struct D-Bus type as `Sources`
    (`a(ssbs)`), so it gets the identical Phase 3 fix: don't trust the
    `PropertiesChanged` delta payload for it, treat the signal only as a
    trigger for an explicit `Properties.Get` re-fetch. `SelectedAmpIp` is a
    plain string scalar and is trusted directly, like `Online`/`DeviceName`/
    `AmpIp`.
  - **Bug found and fixed (first round of review)**: amp-list rows showed
    the raw UDP device name ("My Devialet-ETH") instead of the
    mDNS-resolved model name ("Devialet Expert 140 Pro") the header already
    showed correctly — not a daemon regression (`KnownAmps` already
    carried both `device_name`/`model_name` fields correctly per Phase
    3.7), but a QML bug: the delegate read `modelData.deviceName` directly
    and never referenced `modelData.modelName` at all. Fixed with
    `modelName ?: deviceName`, the same fallback `root.ampDisplayName`
    already used for the header and the same one the design mockup's own
    `displayName(a){ return a.modelName || a.udpName; }` uses for both the
    header and each `.amp-option-name` (confirmed by reading the mockup's
    JS, not assumed) — including its `" · name unresolved"` subtitle tag,
    ported verbatim.
  - **"None" option, ported from the Android app's actual source**
    (`ekmanch/devialet-expert-remote`, cloned locally), not invented — two
    rounds:
    1. First pass added a "None" row with invented wording ("No amp
       selected"). Corrected after being asked to check the Android app
       directly: `MainActivity.showAmpSheet()`/`sheet_amp_picker.xml` show
       "None" always sitting first, above a divider, above the real amps;
       italic name text, a plain outline-ring dot state (`dot_none`/
       `dot_none_selected` — Android's own comment explains a dashed stroke
       renders unreliably under hardware acceleration on some API levels,
       hence the plain ring, which happened to already match this port's
       existing header-dot "none" treatment); strings ported verbatim from
       `strings.xml`: `amp_none_name` = "None", `amp_none_sub` = "Don't
       connect to any amplifier".
    2. The *header* text for the true nothing-selected state (`ampIp ===
       ""`) was separately wrong too — read from `MainActivity.
       updateDeviceCard()`'s `selectedIp.isBlank()` branch and
       `strings.xml`: `device_none_selected` = **"No Amplifier"**,
       `device_tap_to_choose` = **"Tap to connect"** (lowercase "connect")
       — previously showed "Devialet" / "No amp selected" (both invented).
  - **Dimmed/disabled controls for the no-amp-selected state, also ported
    from the Android app** after being asked to check it: `setGroupEnabled()`/
    `updateConnectionState()` in `MainActivity.kt` apply `disabledAlpha =
    0.4f` to each control group *as a whole* ("not per-child", per that
    file's own comment) plus recursive `isEnabled = false`, and show
    `dial_no_source = "—"` / `no_source_label = "No source"` when
    `!hasSelectedAmp`. Ported the same shape: `opacity: root.ampIp === ""
    ? 0.4 : 1.0` on the volume block/action row/source block containers
    (the individual `enabled: root.ampIp !== ""` bindings already existed
    from the picker's first pass, just weren't visually dimmed). Along the
    way, found and fixed the actual bug behind an observed "-15.0dB"
    artifact when nothing was selected: the daemon's "None" state sets
    `VolumeDb` to its zero-value default (`0.0`, not undefined), which is
    below the `Slider`'s own `from` bound and was silently clamping to
    `to` (the -15dB ceiling) — a real-looking value with nothing connected.
    Both the readout and the slider's bound value now explicitly check
    `ampIp === ""` first.
  - **Incident: a synthetic test amp leaked into the live daemon.**
    Verifying the picker with a second amp meant injecting a synthetic UDP
    broadcast (`SYNTH-UNRESOLVED-AMP`/`127.0.0.1`, built with
    `devialet_protocol::fixtures::StatusFixtureBuilder`) — but the first
    time, straight into the real systemd-managed daemon rather than an
    isolated instance. Since `AmpState` never prunes known amps (Phase
    3.5, intentional, for real amps), it persisted in `KnownAmps` after the
    throwaway sender was killed, until caught (a real network scan showed
    no such device existed) and fixed by restarting the live service —
    confirmed via `busctl` the fake entry was gone and `KnownAmps` held
    only the real amp. Verification method corrected going forward: stop
    the real systemd service first, run a disposable foreground instance
    of the same binary for any synthetic-amp injection, kill it, then
    start the real service fresh — the long-lived supervised instance
    backing the actual widget never sees synthetic data at all.
  - **Bug found and fixed (second round of review): "None" didn't actually
    stick.** Clicking "None" closed the picker but the previous amp stayed
    selected. Read `AmpState`/`effective_ip()` in
    `crates/devialet-remote-daemon/src/interface.rs` to confirm rather
    than assume: `select_amp()` only ever wrote `selected_ip`, and an
    explicit `SelectAmp("")` was byte-for-byte identical to "never
    selected" — so `effective_ip()`'s Phase 3.5 auto-select-if-alone branch
    (designed for "nothing has ever been chosen" with exactly one known
    amp) silently re-selected the sole amp immediately after, every time.
    `SelectedAmpIp` itself did briefly flip to `""` (a real signal fired),
    but `AmpIp`/`DeviceName`/everything the UI actually renders off of
    snapped straight back. The QML click handler was never at fault
    (confirmed it already called `SelectAmp("")` correctly). Fixed by
    adding `has_explicit_selection: bool` to `AmpState`, set unconditionally
    by `select_amp()` regardless of `ip` (including `""`), with
    auto-select-if-alone now gated on `!has_explicit_selection` instead of
    `selected_ip.is_empty()` — "never selected" and "explicitly cleared"
    are now genuinely distinct states. **Flagged for Phase 4.2**: loading a
    persisted selection on startup — even a persisted `""` (a previously-
    explicit None) — must also set `has_explicit_selection = true`, not
    just `selected_ip`, or a restart would silently resurrect auto-select
    for a user who'd deliberately opted out of it.
  - **Automated tests**: the existing `clearing_selection_back_to_empty_
    string_returns_to_auto_select_behavior` test directly asserted the
    buggy behavior (a raw `selected_ip = ""` write auto-selecting again) —
    replaced with `explicit_none_selection_does_not_fall_back_to_
    auto_select` (regression test for the fix) and
    `never_explicitly_selected_still_auto_selects_the_sole_known_amp`
    (confirms the fix didn't overcorrect and break the genuine fresh-
    startup case). Full workspace: 51/51 tests (14 daemon + 37 protocol),
    clippy clean.
  - **Live verification, all three review rounds, via `busctl` and
    `grabToImage` screenshots** (not visual-only): amp list correctly
    showing resolved vs. unresolved names side by side (real amp +
    synthetic, isolated instance); `SelectAmp("")` with 2 known amps
    correctly falling back to the not-connected state rather than
    auto-selecting (Phase 3.5's fallback re-confirmed still intact);
    dimmed/disabled treatment screenshotted against the real single-amp
    daemon after the auto-select fix (previously unreachable through a
    real click, since "None" never actually stuck before that fix);
    `SelectAmp("")` held for 3s across real incoming UDP broadcasts with
    zero reversion (previously reverted on the very next `recompute()`);
    re-selecting the real amp afterward round-tripped cleanly every time.
    Real daemon confirmed clean (`KnownAmps` = 1 entry, the real amp only)
    after each round. Widget reloaded live (`kpackagetool6 --upgrade` +
    `plasmashell --replace`) after every fix.
  - **Tooling note**: `qml6` in this environment fully swallows QML
    construction errors (confirmed by testing known-bad QML — no stderr
    output at all, even with `QT_LOGGING_RULES`/`QT_MESSAGE_PATTERN` set),
    so a real bug (a fractional `font.pixelSize: 12.5` — QML's `int`-typed
    property silently rejects non-integer values, same class of bug as
    Phase 4.0's own `9.5` finding) had to be caught by manually bisecting
    the file with a scratch copy rather than reading an error message.
    `qmllint` on this machine remains the Qt5-incompatible build noted in
    Phase 4.0 — still not usable here.
  - Did not touch persistence (4.2), the settings view (4.3), or
    scroll-to-adjust (4.4) — out of scope, confirmed unstarted.

- [x] **Phase 4.11 — Custom panel icon.** Replaced the Phase 2
      `audio-speakers-symbolic` Breeze placeholder with a real custom icon
      from `design/icon/`. Small, self-contained visual change — did not
      expand into 4.2/4.3/4.4/4.5 scope.
  - **Mechanism confirmed before implementing, not guessed**: two separate
    icon references exist in this package. `Plasmoid.icon` (`main.qml`,
    consumed by `CompactRepresentation.qml`'s `Kirigami.Icon.source`)
    drives the actual panel/compact-representation icon and accepts an
    arbitrary resolvable file path — confirmed via a real precedent
    (`org.kde.desktopcontainment`'s `ConfigIcons.qml` binds a user-browsed
    `KIconThemes.IconDialog` file path straight to `Plasmoid.icon`/
    `Plasmoid.configuration.icon`). `metadata.json`'s `KPlugin.Icon` (the
    "Add Widgets" list entry) is separate and more limited:
    `KPluginMetaData::iconName()`'s own header doc says `\sa
    QIcon::fromTheme()` — a system icon-theme name only, confirmed against
    a real KPackage precedent (`org.kde.plasma.folder`'s
    `"Icon": "org.kde.plasma.folder"` resolves to an actual Breeze-shipped
    `.../breeze/applets/256/org.kde.plasma.folder.svg`, not a bundled
    package file). Getting a custom icon into the "Add Widgets" list too
    would mean installing into the system/user hicolor icon theme — real
    packaging work deferred to Phase 4.5, not done here; `metadata.json`'s
    `Icon` is left as a real Breeze name, unchanged.
  - Bundled the same way Phase 4.0 bundled its fonts:
    `plasmoid/contents/icons/`, loaded via `Qt.resolvedUrl(...)` in
    `main.qml` — matches the real `luisbocanegra.panel.colorizer`
    precedent of a plasmoid shipping its own `contents/icons/` directory.
  - **Iteration 1 — `devialet_icon_filled.svg`** (fixed copper colors,
    `#e3a06a`/`#c17f4e`, matching `Theme.qml`'s palette exactly). Verified
    live: reinstalled, restarted plasmashell, screenshotted the real top
    panel with `spectacle`, and located the icon by scanning for its
    known copper RGB values pixel-by-pixel (not eyeballed) — renders
    crisply, correct colors, no blur.
  - **Iteration 2 — switched to `devialet_icon_currentColor_tray.svg`**
    (asked to try it for comparison). A plain source swap rendered
    **nearly invisible**: confirmed by sampling actual pixel values, not
    assumed — `fill="currentColor"` loaded as a bare file path has no CSS
    context to resolve against, so it defaulted to near-black on the dark
    panel. Root-caused and fixed via `Kirigami.Icon`'s `isMask: true` +
    `color: Kirigami.Theme.textColor` (confirmed via its `qmltypes` that
    both properties exist precisely for this) — the real mechanism
    real symbolic/tray icons use for theme-adaptive recoloring, not
    literal SVG `currentColor` resolution. Trade-off flagged, not
    silently absorbed: this collapses the filled variant's two-tone
    copper shading into one flat theme color, by design.
  - A separate background task (concurrent, unrelated to the icon-choice
    decision above) briefly swapped both files to
    `devialet_icon_white.svg` (fixed white, no `isMask` needed since it
    has no `currentColor`) — reverted back to the `currentColor_tray` +
    `isMask`/`color` combination once confirmed as the actual preference;
    the now-unused `devialet_icon_white.svg` copy was removed from
    `plasmoid/contents/icons/` (the shipped package) so it wasn't left as
    dead weight, while all three original variants remain under
    `design/icon/` as source reference (same "committed source assets"
    treatment as `design/font/`).
  - **Bug found and fixed: icon rendered visibly larger than sibling
    panel icons** (weather/network/Bluetooth). Investigated before
    changing anything, per instruction:
    1. QML sizing was **not** the cause — checked two real shipped KDE
       applets' `CompactRepresentation.qml` (`org.kde.kdeconnect`, this
       project's own porting reference, and `org.kde.desktopcontainment`)
       and both use the identical `Kirigami.Icon { anchors.fill: parent }`
       pattern with zero extra padding/sizing logic. Ours matched exactly.
    2. The SVG's own artwork bled nearly edge-to-edge instead: computed
       (not guessed) where the `rotate(-14 15 15)` transform actually
       sends each triangle vertex in the `viewBox="0 0 30 30"` canvas —
       one vertex landed at `y=29.30`, only 0.7 units (2.3%) from the
       edge. Compared against a real Breeze 22px symbolic icon
       (`preferences-system-bluetooth-symbolic.svg`) whose artwork sits
       ~13-14% inset from its canvas edge on all sides — the actual KDE
       symbolic-icon convention.
    3. Fix: added `translate(15 15) scale(0.75) translate(-15 -15)` to
       the `<g transform>`, scaling the artwork down around the same
       rotation pivot before rotating (preserves shape/proportions, just
       adds margin) — computed the resulting worst-case margin at 14.2%,
       matching Breeze's convention. Applied identically to both
       `plasmoid/contents/icons/devialet_icon_currentColor_tray.svg`
       (shipped) and `design/icon/devialet_icon_currentColor_tray.svg`
       (source), so they don't diverge.
    4. **Verified quantitatively, not just visually**: measured the
       icon's actual rendered pixel bounding box from same-instant
       screenshots, using the neighboring moon icon (23×28px, unchanged
       across every screenshot) as a stable reference rather than
       absolute panel coordinates (which drift as the panel's digital
       clock/weather text width changes). Before: 35×33px (1.52× the
       moon's width, 1.18× its height). After: 26×24px (1.13×/0.86×) —
       matches the predicted ~25% reduction from `scale(0.75)` almost
       exactly.
  - The source SVG was then edited externally (outside this session, a
    small deliberate-looking tweak: the shared middle vertex split into
    two slightly different points, `9,15` → `9,14.4`/`9,15.6`, adding a
    small notch at the paper-plane's tail) with the `scale(0.75)` padding
    fix removed in the same edit. Per instruction not to silently
    revert/override an on-disk change I didn't make, set the shipped copy
    to exactly match when asked to "try" it for comparison, and reported
    the resulting size regression (measured: back to 35×33px) rather than
    silently reapplying the fix myself. Once explicitly confirmed the
    sizing needed to match the other panel icons again, reapplied the
    identical `scale(0.75)` treatment on top of the new notched shape
    (re-verified at 26×24px, matching the moon reference again) to both
    the shipped copy and the `design/icon/` source.
  - **Not committed.** CLAUDE.md's working-style rules were updated
    mid-phase to explicitly forbid staging/committing/pushing on my own
    — every icon-related change in this phase (including the very first,
    `devialet_icon_filled.svg` iteration, which *was* committed under the
    prior rules) from the `currentColor_tray` switch onward is sitting as
    uncommitted working-tree changes, left for deliberate review/commit.
    Current on-disk state (as of this entry): `Plasmoid.icon` points at
    `devialet_icon_currentColor_tray.svg`, `CompactRepresentation.qml`
    has `isMask: true`/`color: Kirigami.Theme.textColor`, and the SVG has
    the notched-vertex shape with the `scale(0.75)` padding fix applied.
  - Did not touch metadata.json further, persistence (4.2), the settings
    view (4.3), or scroll-to-adjust (4.4).

- [x] **Phase 4.2 — Amp selection persistence (daemon-side).** Deferred
      from 3.5 specifically so it could be verified against a real picker
      UI instead of blind via busctl.
  - **Ownership (settled, as planned):** the daemon owns persistence, not
    the widget - see TODO.md's prior "Reasoning" note (lifecycle mismatch,
    live-reconciliation needs daemon-side discovery state anyway).
  - **Location, investigated rather than assumed:** new `config` module
    (`crates/devialet-remote-daemon/src/config.rs`), plain text (no
    serde/JSON, matching this workspace's existing "nothing here needs
    it" stance), one line holding the selected IP or empty. Path is
    `$XDG_CONFIG_HOME/devialet-remote-daemon/selected-amp-ip`, falling
    back to `$HOME/.config/devialet-remote-daemon/selected-amp-ip` per
    the freedesktop.org XDG Base Directory spec's own stated fallback
    rule ("if $XDG_CONFIG_HOME is either not set or empty, a default
    equal to $HOME/.config should be used") - read directly via
    `std::env`, no `dirs`/`directories` crate added for two env var
    reads. Confirmed the Kotlin app's own approach first (read its actual
    source, not reconstructed from memory): `MainActivity` persists via
    plain `SharedPreferences` (`amp_ip`/`amp_name` keys) and trusts the
    restored `selectedIp` immediately, with connectedness governed
    entirely separately by `isAmpRecentlyHeard`/`discoveredAmps`
    staleness - i.e. Android does no explicit "reconciliation" step
    either; trusting the persisted value while staleness-checking it
    independently *is* the reconciliation pattern, ported as-is.
  - **Reconciliation required zero new logic.** `AmpState::recompute()`
    already only shows a selected IP as connected/named once that IP has
    a real `TrackedAmp` entry (populated solely by `ingest_status`, i.e.
    an actual received UDP broadcast) - a persisted IP with no matching
    live entry falls straight into the existing "unknown ip" branch
    (`Online=false`, `DeviceName=""`, etc.), same as Phase 3.5's
    already-tested `explicit_selection_of_an_unknown_ip_shows_the_ip_but_
    not_connected` case. `set_persisted_selection()` (interface.rs)
    deliberately does not synthesize a `TrackedAmp` for this exact reason.
  - **has_explicit_selection carried over correctly:**
    `set_persisted_selection(ip)` sets `has_explicit_selection = true`
    unconditionally, including for a persisted `ip == ""` - the specific
    regression this phase was warned about (see Phase 4.1's fix). Save
    side: `AmpState::select_amp` (the `SelectAmp` D-Bus method) calls
    `config::save_selected_ip(&ip)` on every call, including `""`. Load
    side: `main()` calls `config::load_selected_ip()` once at startup,
    before `serve_at()`, and applies it via `set_persisted_selection` if
    `Some` (file existed) - `None` (file never written) leaves
    `has_explicit_selection` at its correct default `false`, preserving
    genuine first-run auto-select-if-alone.
  - Persistence write/read are best-effort, matching this daemon's
    existing mDNS "cosmetic, not depended on" framing - a failure (read-
    only filesystem, missing `$HOME`, etc.) is logged to stderr and
    otherwise ignored; `SelectAmp` never fails because persisting failed.
  - **Automated tests** (16 new: 9 in `config::tests` covering XDG/HOME
    path-fallback resolution and save/load round-tripping including the
    critical `Some("")` vs `None` distinction; 5 in `interface::tests`
    covering the phase brief's 4 verification cases against `AmpState`
    directly - persisted-real-ip-reconnects-once-broadcast-arrives,
    switching-persisted-selection-to-a-different-amp,
    persisted-explicit-None-does-not-resurrect-auto-select-even-once-an-
    amp-broadcasts, persisted-ip-for-a-since-gone-amp-stays-not-connected).
    Full workspace: 64/64 tests passing, clippy clean.
  - **Live verification against the real daemon and real amp
    (2026-08-27),** built as a release binary and run under the real
    systemd unit, all 4 confirmed via `busctl` + `journalctl` (real amp
    at `192.168.0.22`, "Devialet Expert 140 Pro"):
    1. `SelectAmp("192.168.0.22")`, confirmed persisted
       (`~/.config/devialet-remote-daemon/selected-amp-ip` contained the
       IP); `systemctl --user restart`; log showed `config: restoring
       persisted amp selection: "192.168.0.22"`; `Online` reflected
       `false` immediately at startup then flipped `true` (with
       `DeviceName` resolved) once the next real broadcast/mDNS
       resolution landed - genuine reconnection, not an assumed one.
    2. `SelectAmp("192.168.0.222")` (a second, non-broadcasting IP
       standing in for "amp B" - only one real amp was available on this
       network): persisted, restarted, confirmed `SelectedAmpIp` came
       back as `.222` (not `.22`) while the real amp remained visible
       and online in `KnownAmps` - the explicit selection of a different
       amp is what persists, not whatever else is on the network.
    3. `SelectAmp("")` while the sole real amp was actively broadcasting:
       config file confirmed empty; `systemctl --user restart`; log
       showed `config: restoring persisted amp selection: "<none>"`;
       after the restart, with the real amp still broadcasting and still
       the only entry in `KnownAmps`, `SelectedAmpIp`/`AmpIp` stayed `""`
       and `Online` stayed `false` - auto-select-if-alone did **not**
       resurrect a selection. This is the critical regression case from
       the phase brief and it held.
    4. Covered by the same run as case 2: the persisted `.222` IP, which
       never broadcasts on this network, stayed `Online=false` across
       the restart rather than being treated as connected just because
       it was the last selection.
    Selection was restored to the real amp (`192.168.0.22`) on the live
    system afterward so the widget isn't left disconnected.
  - Did not touch the widget/QML - daemon-only, per the phase's explicit
    scope (same as Phase 3.5).
- [x] **Phase 4.2.1 — Settings trigger: dots → gear icon.** Replaced the
      "⋯" text glyph with a proper gear icon per
      design/mockups/devialet_tray_gear_icon_mockup.html.
  - **Icon asset:** bundled the mockup's exact custom stroke-based
    outline gear (`plasmoid/contents/icons/settings_gear.svg`, Feather-
    style, matches the mockup's inline SVG spec exactly — viewBox,
    stroke width, notch count) rather than a system Breeze
    "configure" icon-theme name, so the brand-specific glyph is
    preserved. Same recoloring pattern as Phase 4.1's panel icon:
    `Kirigami.Icon { isMask: true; color: ... }`. Position/size/hover-
    background mechanics (24×24, `root.theme.radiusSm`, hover bg
    `surface2`) were already correct pre-existing structure — only the
    glyph itself changed.
  - **Click handler:** swapped the `// TODO(Phase 4.3)` no-op comment
    for `Plasmoid.internalAction("configure")?.trigger()`. The `?.`
    guard was added on the pre-implementation claim that
    `internalAction("configure")` returns a nullable `QAction*` until
    a `ConfigDialog` exists (cited against `BasicPlasmoidHeading.qml`'s
    own use of the same guard) - reasonable defensive coding, but see
    the correction below.
  - **Live verification (2026-08-29, real panel) surfaced a wrong
    pre-implementation assumption, not just confirmed the icon.**
    Idle/hover rendering matched the mockup exactly. But clicking the
    gear did **not** no-op as predicted — it opened a real, functioning
    `ConfigDialog` window ("Devialet Remote Settings") with baseline
    **Keyboard Shortcuts** and **About** pages. Root cause: Plasma
    auto-provides a default `ConfigDialog` for every installed applet
    regardless of whether it declares its own `config.qml`/`main.xml`
    - `internalAction("configure")` was never actually null here, so
    the click always did something, even before this phase existed.
    The `?.` guard is harmless but was guarding against a case that
    doesn't occur in a real installed Plasma 6 applet. Corrected in
    CLAUDE.md and carried into 4.3.0's scope below rather than left as
    a stale assumption.

- [x] **Phase 4.2.2 — Volume slider: widen the click/drag hit target.**
      Investigated before implementing, per the phase's own instruction:
      read `qquickslider_p.h` (Qt6 QtQuickTemplates2 header) and confirmed
      `QQuickSlider` overrides `mousePressEvent` directly on the control
      item itself — hit-testing is scoped to the control's own bounding
      box (driven by its `implicitHeight`), not to the background/handle
      delegate's drawn geometry (neither delegate has its own
      `MouseArea`/accepted-buttons, so presses fall through to the
      control). Also traced why the bug existed at all: this system's real
      QQC2 style for `Slider` is `qqc2-desktop-style`'s
      `/usr/lib/qt6/qml/org/kde/desktop/Slider.qml` (confirmed by locating
      it — Plasma always runs `org.kde.desktop`, not `Basic`, for a bare
      `import QtQuick.Controls`), whose `implicitHeight` binding
      recomputes off whatever `background`/`handle` delegates are
      assigned. Our `background` set `implicitHeight: 4`; our `handle` set
      `height: 15` but never `implicitHeight` (0 by default for a plain
      `Rectangle`); padding was 0 — so the control's actual on-screen
      height was exactly 4px, matching the visible line exactly. This is
      what made the hit area exactly as thin as the track.
  - **Fix:** `volumeSlider` (`FullRepresentation.qml`) gained
    `implicitHeight: 26`, matching the sibling `−`/`+` buttons' row
    height (26px chosen over the 20-30px native-convention default of 24,
    to make the whole control row visually uniform height). `background`
    (4px line) and `handle` (15×15) delegates are untouched — both
    already center via `topPadding + availableHeight/2 - height/2`, so
    they stay pixel-identical, just now centered within a taller
    invisible hit box. No MouseArea/DragHandler needed.
  - Step buttons, debounce logic (`onPressedChanged`,
    `volumeInteracting`, `lastVolumeSliderReleaseAtMs`), and the
    `Binding` to `root.volumeDb` untouched, as scoped.
  - **Verified live by you (2026-08-29):** pressing and dragging with the
    mouse noticeably above/below the thin visible line starts and tracks
    the drag correctly now; visible track appearance unchanged.

- [x] **Phase 4.2.3 — Power button hover: off → green.** When the
      amplifier is off (button shows "Power On"), hovering over the
      power button changes its border, icon, and text to green,
      signaling that clicking it will turn the amp on. Per
      design/mockups/devialet_tray_boot_state_mockup.html
      (`.action-btn.power-btn.state-off:hover`), which sets
      `border-color:var(--success)` (`#5fa374`) and
      `color:var(--success-bright)` (`#7bc796`) — nothing else
      (no background/size change), confirmed by reading the CSS
      directly before implementing.
  - **Investigated before implementing, per the phase's own
    instruction:** the power button (`FullRepresentation.qml`) is a
    plain QQC2 `Button` already reading its own `hovered` property
    directly (no `MouseArea`/`HoverHandler` needed — same pattern as
    the mute button and the volume step buttons). Before this phase,
    hover only drove `border.color`, unconditionally to `theme.danger`
    regardless of power state — there was no on/off branch at all, and
    icon/label color didn't respond to hover. "Amp is off" is already
    tracked via `root.power` (bool, sourced from the daemon's D-Bus
    `Power` property), the same property the button's own label text
    already gates off — no new flag needed.
  - **Fix:** added `theme.success` (`#5fa374`) and
    `theme.successBright` (`#7bc796`) to `Theme.qml`, matching the
    mockup 1:1 (same pattern as the existing `danger` port). Gave the
    power `Button` an explicit `id: powerBtn` and branched its
    `background.border.color` on `root.power` (`danger` when on,
    `success` when off, both only while hovered); added matching
    `powerBtn.hovered && !root.power` guards to the `Kirigami.Icon`
    and `Label` colors (`successBright`) inside `contentItem`, which
    previously never changed color on hover at all.
  - Scope held: on-state hover (border only, `theme.danger`, icon/text
    unchanged) is untouched — deferred to Phase 4.2.4 below. No change
    to click behavior, power toggle logic, or any other button.
  - **Verified live by you (2026-08-29):** hovering the power button
    while the amp is off shows a green border, icon, and "Power On"
    text, screenshot confirmed.

- [x] **Phase 4.2.4 — Power button hover: on → red.** When the
      amplifier is on (button shows "Power Off"), hovering over the
      power button changes its border, icon, and text to red. Per
      design/mockups/devialet_tray_boot_state_mockup.html
      (`.action-btn.power-btn.state-on:hover{border-color:var(--danger);
      color:var(--danger);}`) — border-color + color only, both the
      *same* `--danger` value (`#b5544a`), unlike 4.2.3's off-hover
      rule which used two shades (`--success` for border,
      `--success-bright` for text). Confirmed by reading the CSS
      before implementing.
  - **Investigated before implementing, per the phase's own
    instruction:** after 4.2.3, `background.border.color` on the power
    button (`FullRepresentation.qml`) already branched correctly
    (`theme.danger` when hovered+on, `theme.success` when hovered+off,
    `theme.divider` otherwise) — untouched by this phase. The gap was
    the `Kirigami.Icon`/`Label` `color` bindings inside
    `contentItem`, which 4.2.3 had only wired for the off+hovered case
    (`successBright`); on+hovered fell through to `theme.text`, so
    icon/label didn't redden on hover while the amp was on.
  - **Fix:** extended both the icon and label `color` bindings to a
    three-way branch: `powerBtn.hovered ? (root.power ?
    root.theme.danger : root.theme.successBright) : root.theme.text`.
    No new `Theme.qml` property needed — `theme.danger` already
    existed (added before 4.2.3, ported from the same `--danger` var).
  - Scope held: off-state hover (green border/icon/text) untouched;
    `border.color` logic untouched; no other button/element touched.
  - **Verified live by you (2026-08-29):** hovering the power button
    while the amp is on shows a red border, icon, and "Power Off"
    text, screenshot confirmed; off-state hover re-checked unchanged.

- [x] **Phase 4.2.5 — Panel icon: switch to Glow Dot variant.** Replaced
      the panel icon with
      `design/icon/A - Glow Dot/devialet_icon_A_filled.svg` (copper dot
      + translucent ring, `viewBox="0 0 34 34"`).
  - **Investigated before implementing, per the phase's own
    instruction:**
    1. **Inset/margin** — computed (not eyeballed) the artwork's own
       bounding box: outer ring extends to `r + stroke-width/2 = 12`
       from center `(17,17)`, giving a `[5,29]` bbox inside the
       `34×34` canvas — a 14.7% inset per side, already matching the
       Breeze symbolic convention (~13-14%) measured during Phase
       4.1's triangle-icon fix. No scale/margin correction needed,
       unlike Phase 4.1's original icon.
    2. **Color model** — the new SVG uses hardcoded hex fill/stroke
       (`#e3a06a`), not `fill="currentColor"`, structurally matching
       Phase 4.1's abandoned "Iteration 1" (`devialet_icon_filled.svg`)
       rather than the `currentColor_tray.svg` that `isMask:true` +
       `Kirigami.Theme.textColor` was built for. Flagged this as a
       real behavior decision rather than a pure asset swap: keeping
       `isMask:true` would flatten the copper color and the ring's
       0.35-opacity glow into one flat theme-color mask, likely
       defeating the point of this artwork. Asked and confirmed:
       render the SVG's own colors as-is.
  - **Fix:** added `plasmoid/contents/icons/devialet_icon_glow_dot.svg`
    (verbatim copy, no changes needed). `main.qml`'s `Plasmoid.icon`
    now points at it. `CompactRepresentation.qml`'s `Kirigami.Icon`
    changed to `isMask: false` with the `color:
    Kirigami.Theme.textColor` override removed, so the copper
    fill/opacity renders as designed. Trade-off noted in-code: this
    icon no longer adapts to a light panel theme — not yet verified
    against one. `metadata.json`'s `KPlugin.Icon`, click behavior, and
    the old unused icon files left untouched, per scope.
  - **Verified quantitatively, not just visually** (same technique as
    Phase 4.1): screenshotted the real panel (`spectacle`, native
    3840×2160) and measured pixel bounding boxes by diffing against
    background. New icon: 32×32px. Neighboring Breeze symbolic icons
    in the same systray: volume/speaker 35×34px, screen-share 33×33px
    — matches sibling icon sizing within measurement/glyph-shape
    noise, no repeat of Phase 4.1's original oversized-icon bug. One
    stray differing pixel above the icon was isolated and confirmed to
    be a wallpaper star, not part of the icon render, before being
    excluded from the measurement.
  - **Verified live by you (2026-08-29):** screenshot confirmed clean
    copper dot + glow ring at correct size next to sibling systray
    icons.

- [x] **Phase 4.3.0 — Power-on "booting" state: daemon-side.** Exposes
      a three-state `PowerState` (`"Off"`/`"Booting"`/`"On"`) over
      D-Bus, tracked per-amp, plus a new `BeginPowerOnBoot(ip)` method
      to start tracking a boot. Daemon-owned, matching this project's
      convention that long-lived state belongs in the systemd-
      supervised daemon, not the widget.
  - **Investigated before implementing, per the phase's own
    instruction:** found that the daemon never sends the power-on
    command at all — that's `devialet-ctl`, invoked directly by QML,
    which by design "never talks to the daemon or D-Bus" (CLAUDE.md).
    So there was no existing "where the power-on command is sent in
    the daemon" to show — the premise didn't hold. Resolved as: this
    phase adds the D-Bus surface for something to report a boot
    starting; nothing calls it yet (Phase 4.3.1, blocked on this
    phase, is what wires QML to call it — orthogonal to `devialet-ctl`,
    whose "never talks to D-Bus" boundary stays intact permanently).
  - **Shape:** `PowerState: String` is additive alongside the existing
    `Power: bool` (not a type change to it) — `Power` already has live
    QML bindings that would've broken from a wire-format change even
    though no QML is touched this phase. `TrackedAmp` gained
    `boot_deadline: Option<Instant>`, carried forward across
    re-ingestion exactly like `model_name` (a naive overwrite would
    wipe it on the amp's next ~1s broadcast). `BOOT_TIMEOUT` originally
    15s per spec — see live verification below for why it's now 20s.
  - **Timer:** no spawned task — `resolve_boot_deadlines()` (clears a
    deadline once `power_on` is confirmed true, or the deadline
    elapses) runs inside `recompute()`, which already fires on every
    real UDP packet *and* the receive loop's existing 1s `POLL_TICK`
    staleness tick, so the fallback is checked at least once a second
    with zero new plumbing. Confirmed disconnect/reconnect-safe: since
    `PowerState` is a real zbus property (not signal-only), any client
    querying mid-boot gets the live derived value directly via
    `Properties.Get`, not dependent on catching a specific signal.
  - **`BeginPowerOnBoot` double-call guard:** confirmed with you and
    implemented as proposed — no-ops (doesn't reset/extend the
    deadline) if a boot is already in progress for that amp, so
    repeated calls can't keep it reporting "Booting" indefinitely.
    Noted for 4.3.1: the widget disabling the power button during
    boot is the primary protection against spamming; this is
    defense-in-depth against races/stale clients.
  - **Fallback:** falls out of the derivation with no extra code —
    once `resolve_boot_deadlines` clears an expired deadline with
    `power_on` still false, `PowerState` is just `"Off"`. No retry, no
    distinct error state.
  - **Tests:** 5 new unit tests (`cargo test -p devialet-remote-daemon`,
    32/32 passing) covering Off/Booting/On derivation, deadline
    clearing on real confirmation, timeout fallback, and a non-primary
    amp's boot resolving independently of the primary one.
    `BeginPowerOnBoot` itself has no unit test, same constraint as the
    existing `select_amp` (async zbus method, no interface context in
    the test module) — covered by live verification instead.
  - **Verified live against the real amp (2026-08-29):** rebuilt the
    release daemon, restarted the systemd unit, `busctl --user monitor`
    while triggering a real boot. Real timeline: `BeginPowerOnBoot` at
    T+0 → `PowerState` "Booting" immediately; at **T+15.07s** the
    original 15s timeout fired with no confirmation yet → fell back to
    "Off"; at **T+16.07s** the amp's real UDP broadcast confirmed
    power-on → "On". This amp's real boot time (~16s) sits right past
    a 15s timeout, so an ordinary successful boot would flash "Off"
    before "On" — not a bug, but real evidence 15s was too tight.
    Raised `BOOT_TIMEOUT` to 20s (your call, ~4s headroom over the one
    real sample), rebuilt, retested (32/32), restarted the live daemon.
  - **Deliberately forced the pure-timeout path** (isolated from the
    real-boot race above): amp powered off for real, `BOOT_TIMEOUT`
    temporarily dropped to 4s, `BeginPowerOnBoot` called with **no**
    real power-on command sent — `PowerState` held "Booting" for the
    full window then fell back to "Off" and stayed there, confirming
    the failure path with no real (rare) boot failure needed. Reverted
    the constant to 20s afterward, rebuilt, retested, restarted the
    live daemon, and sent a real power-on to leave the amp back "On"
    (its state at the start of this verification).

- [x] **Phase 4.3.1 — Power-on "booting" state: widget-side.** Consumes
      the three-state `PowerState` from Phase 4.3.0 and drives the
      booting UI per
      design/mockups/devialet_tray_boot_state_mockup.html: spinner
      replacing the power icon, "Powering on…" label, pulsing amber
      amp-status dot, amp header sub-text "Booting…" — transitioning
      to the existing "on"/"off" visual states once the daemon reports
      one.
  - **Investigated before implementing, per the phase's own
    instruction:** the power button already had the exact right
    pattern to extend, not a new one - optimistic local set +
    400ms-debounce-guarded D-Bus property mirror (same shape already
    used for `Power`/`Muted`/volume). `BeginPowerOnBoot` is called via
    `Dbus.SessionBus.asyncCall` (same shape as the existing
    `SelectAmp` call in `selectAmpByIp`), synchronously first in the
    click handler, immediately before `runCtl("power on")` - both
    fire-and-forget dispatches issued back-to-back with no wait
    between them, so there's no window where the real command went out
    before the daemon knew a boot was starting. `PowerState` reads
    into a new local mirror `root.powerState` via the identical
    `onRefreshed`/`onPropertiesChanged` pattern as `Power`, sharing
    `Power`'s existing debounce timestamp (both driven by the same
    click, one guard is enough) - `root.power` itself is untouched,
    still what 4.2.3/4.2.4's hover colors key off.
  - **Button inertness - confirmed mechanism, not a new one:** the
    button already had `enabled: root.ampIp !== ""` (QQC2's
    `Control.enabled = false` blocks mouse/keyboard event delivery
    outright, the same mechanism CSS `pointer-events:none` achieves) -
    just extended to `&& root.powerState !== "Booting"`.
  - **Spinner:** implemented as a literal port of the mockup's arc
    technique via `QtQuick.Shapes` (`PathAngleArc`, static dim ring +
    rotating bright 90° arc), not a Rectangle-based approximation -
    per your correction that the corner-radius Known Issue's
    theme-dependency concern doesn't apply to self-drawn geometry with
    no external theme asset to match. Rendered cleanly at 13×13 with
    no QML errors (`journalctl` checked clean after install/restart).
  - Scope held: power-off stays immediate/unaffected; 4.2.3/4.2.4
    hover colors untouched (booting styling is unconditional, not
    hover-gated, matching the mockup's `.state-booting` having no
    `:hover` in its selector); daemon untouched except for the
    verification-only `BOOT_TIMEOUT` drops described below (reverted
    both times).
  - **Verified live (2026-08-29), all three checklist items:**
    1. Clicked Power On for real with the amp off - booting UI
       (spinner, "Powering on…", warning border/icon/label, pulsing
       amber dot, "Booting…" sub-text) appeared immediately
       (screenshot confirmed).
    2. Clicked the button again during the booting window - confirmed
       genuinely inert (no command sent, no state change), not just
       visually disabled.
    3. Confirmed it transitions to the normal "on" UI once the real
       amp finishes booting - including the case where `BOOT_TIMEOUT`
       had already fired and fallen back to "Off" first, then the
       amp's real confirmation arrived late and it silently corrected
       to "On" anyway (no stuck/error state).
    4. Forced the timeout/fallback path twice: temporarily dropped
       `BOOT_TIMEOUT` to 5s (rebuilt, restarted the daemon), called
       `BeginPowerOnBoot` with no real power-on sent - widget fell
       back to the normal "off" visual state correctly. Reverted to
       20s, rebuilt (`cargo test`: 32/32), restarted the daemon, and
       restored the real amp to "On" (its state before this
       verification pass).
  - **Found, triaged, and parked as a separate bug** (not folded into
    this phase): a stale-volume-display mismatch after power-on,
    confirmed unrelated to this phase's own work (reproduces on a
    completely normal boot too, and matches a symptom previously seen
    in the Kotlin Android app) - see "Not yet scoped / parked" below.

- [x] **Phase 4.4.0 — Settings page: add to the existing ConfigDialog.**
      Adds a "General" category to the `ConfigDialog` Plasma already
      auto-provides for every installed applet (Keyboard Shortcuts +
      About, confirmed live in Phase 4.2.1) — no dialog to create, no
      action to wire. The page itself is empty this phase per scope — just
      the brand header (icon mark + "Devialet Expert Remote" / "Widget
      Settings"), no settings content yet (that's Phase 4.4.1).
  - **Investigated before implementing, per the phase's own
    instruction:** confirmed by reading the shell's own
    `AppletConfiguration.qml` that our category always appears
    *alongside* Keyboard Shortcuts/About (separate `Repeater`s, no
    merge/suppress mechanism exists), and that no `metadata.json` key
    is involved at all — three real shipped Plasma 6 applets checked,
    none reference `config.qml` there. Confirmed the real KCM page
    convention (`KCM.SimpleKCM` root, checked its own source — plain
    `Kirigami.ScrollablePage`, no forced Breeze-form styling) against
    two real applets. See CLAUDE.md's "Settings ConfigDialog" section
    for the corrected/expanded writeup.
  - **A long live-debugging session, root-caused and documented so it
    never has to be rediscovered** (see CLAUDE.md's new
    `ConfigCategory.source` subsection for the permanent record): the
    page loaded fine as a bare file, `qmllint` clean, root type matched
    every working precedent — but every real click in the actual
    ConfigDialog produced a deep, misleading Kirigami `PageRow` crash
    ("Could not convert argument 1 ... to QQuickItem*"), which then
    broke page navigation for the rest of that dialog session (even
    Plasma's own Keyboard Shortcuts got stuck afterward). Ruled out in
    order, each confirmed live rather than assumed: page content
    complexity, the `../ui/Theme.qml` cross-directory import, a
    missing `org.kde.plasma.plasmoid` import, a legacy
    `X-Plasma-API: declarativeappletscript` key in `metadata.json`
    (removed anyway - matches real convention, 13/15 real installed
    plasmoids omit it). A local `PageRow.push()` repro (bare `qml6`,
    no shell) succeeded cleanly, proving the shell environment itself
    mattered. Two other real, independently-verified-live installed
    plasmoids (Panel Colorizer, Digital Clock) opening their own
    settings fine ruled out a general Plasma/Kirigami bug. The
    breakthrough: pointing our category at Panel Colorizer's own file
    worked, but an absolute path to *our own* file also worked while a
    relative one didn't - which led to the real cause, found in other
    installed plasmoids' own config.qml comments:
    **`ConfigCategory.source` resolves relative to `contents/ui/`, not
    to `config.qml`'s own location in `contents/config/`** - true for
    a bare string or an explicit `Qt.resolvedUrl()` call alike. Fixed
    with `source: "../config/ConfigGeneral.qml"`. Restored the
    `Theme.qml` reuse afterward (confirmed not the actual cause,
    no reason to keep the inlined-color workaround).
  - **Verified live by you (2026-08-29):** gear icon → General shows
    the brand header correctly, matching the mockup's style, alongside
    working Keyboard Shortcuts/About; re-verified again after the
    Theme.qml cleanup.

- [x] **Phase 4.4.1 — Settings page: full UI, all controls no-op.** Built
      the entire General page's visual layout in one pass, matching
      design/mockups/devialet_config_dialog_mockup_v3.html: Appearance
      (blur toggle, transparency toggle + 0-100% slider dimmed/disabled
      when the toggle is off), Volume (0.5/1/2 dB segmented control),
      Amplifiers ("Forget All (N)" button with the mockup's two-step
      confirm interaction, ~3s revert timeout), Startup (launch at
      login toggle) — all purely visual this phase, nothing wired.
  - **Investigated before implementing, per the phase's own
    instruction:** read every control's exact CSS (switch pill/thumb
    geometry and color transitions, slider gradient-fill + thumb,
    segmented control's active-state colors, danger button's
    `.confirming` state) and the mockup's own `handleForget()` JS for
    the precise two-step state machine, rather than assuming standard
    QQC2 styling would match. Confirmed the slider could reuse
    `FullRepresentation.qml`'s already-solved custom `background`/
    `handle` delegate pattern from the volume slider instead of
    reinventing it. Went with the real `KnownAmps` D-Bus count (not a
    placeholder) for "Forget All (N)", reusing the same
    `Plasma.DBusProperties` mechanism already proven in
    `FullRepresentation.qml`. Used one flat `ColumnLayout` (not
    `Kirigami.FormLayout`, wrong shape for this custom row style),
    matching the mockup's own flat DOM structure exactly — including
    the "divider on every row except the literal last one" detail.
  - **New reusable files** (`contents/config/`, 3 uses of the switch, 5
    of the row wrapper, 4 of the section label — real duplication
    otherwise): `SettingsSwitch.qml`, `SettingsRow.qml`,
    `SectionLabel.qml`. Added `theme.dangerBright` (`#d17165`) to
    `Theme.qml` for the confirm-state danger button, matching the
    mockup's `--danger-bright`. No control turned out genuinely fiddly
    - the slider reused an existing pattern, everything else was
    straightforward Rectangle+state QML plus one `Timer` for the
    confirm revert - so this stayed one combined task as scoped, no
    splitting needed.
  - **Two real bugs found and fixed live**, not scope creep - both
    needed for the page to work at all:
    1. `font.pixelSize` is an `int` in Qt, not a real number - I'd
       carried the mockup's fractional CSS `px` values over literally
       (`13.5`, `10.5`, `11.5`), which is a genuine QML type error
       ("Invalid property assignment: int expected"), invisible to
       `qmllint` (didn't catch it) and only surfaced as the same
       misleading whole-page/whole-session `PageRow` failure from
       Phase 4.4.0 (`SettingsRow` "unavailable"). Rounded all three to
       integers.
    2. `properties.KnownAmps` needed the same `{"value": [...]}`
       unwrap treatment already established in
       `FullRepresentation.qml` (Phase 2 finding) - skipping it meant
       `.length` was read off the wrapper object, not the array,
       silently coercing the `int` count property to 0. Fixed by
       reusing the same `unwrap()` helper shape. (This turned out not
       to be the cause of the "(0)" you first saw - that was the
       button's own correct terminal "done" state from testing the
       confirm flow twice - but it was still a real, worth-fixing bug:
       confirmed live afterward that the count is genuinely accurate,
       e.g. "Forget All (1)" with one real known amp.)
  - Scope held: every control confirmed no-op - no KConfig writes, no
    D-Bus calls beyond the read-only `KnownAmps` count. `config.qml`
    and `metadata.json` untouched; the existing brand header's content
    untouched, only wrapped in a new outer `ColumnLayout` (needed to
    stack the new sections beneath it).
  - **Verified live by you (2026-08-29):** full page screenshotted
    side-by-side against the mockup - "genuinely extremely close /
    identical in appearance." All four interactive checks confirmed:
    switches flip on click, the transparency slider dims/disables
    correctly when its toggle is off, the segmented control's active
    option changes on click, and Forget All correctly reverts to the
    real count after ~3s when not confirmed a second time.

- [x] **Phase 4.4.0.1 — Settings sidebar: General category icon.** The
      "General" entry in the ConfigDialog's sidebar now shows the
      widget's own copper glow-dot branding instead of a generic
      default icon.
  - **Investigated before implementing, per the phase's own
    instruction:** confirmed by reading the shell's own
    `AppletConfiguration.qml` again that Keyboard Shortcuts'
    (`"preferences-desktop-keyboard"`) and About's (`"help-about"`)
    icons are hardcoded inline in that file - a separate KPackage
    (`org.kde.plasma.desktop`), no property/hook exposed to override
    them from ours. Confirmed `ConfigCategory.icon`'s real behavior by
    tracing `ConfigCategoryDelegate.qml` (the actual sidebar delegate):
    it feeds straight into `Kirigami.Icon.source`, the same mechanism
    `Plasmoid.icon` already uses - an arbitrary resolvable path works,
    unlike `metadata.json`'s `KPlugin.Icon` (Phase 4.1: theme-name
    only). Went with the colored copper glow-dot variant (the "likely
    outcome" branch), reusing the exact SVG already bundled for the
    panel icon (`devialet_icon_glow_dot.svg`, Phase 4.2.5) rather than
    duplicating the asset.
  - **A real bug found and fixed live:** a bare relative string
    (`icon: "../icons/devialet_icon_glow_dot.svg"`) rendered as a
    broken-image placeholder. Unlike `source:` (a `QUrl`-typed
    property, auto-resolved against config.qml's own base URL at
    assignment time - see Phase 4.4.0's ROOT CAUSE finding), `icon:`
    appears to be a plain string passed through unresolved to
    `ConfigCategoryDelegate.qml`'s `Kirigami.Icon { source: model.icon
    }`, which then resolves a relative source against *its own*
    location in the shell's package, not ours. Fixed with an explicit
    `Qt.resolvedUrl()` call made inside config.qml - a genuinely
    absolute URL once computed, needing no further resolution
    regardless of which file later reads it.
  - **Verified live by you (2026-08-29):** sidebar icon renders
    correctly, no blur/scaling artifacts.
  - **Separate finding, not fixed here** (see the new Phase 4.4.0.2
    below): tracing this also surfaced that `AboutPlugin.qml` (the
    shell's own file) has undocumented special handling for
    `metadata.json`'s `KPlugin.Icon` - a value starting with `/` is
    treated as a path relative to the plasmoid's own `contents/`,
    unlike the "Add Widgets" list's use of the same field (Phase 4.1:
    theme-name only via `QIcon::fromTheme()`). The About page's own
    content still shows the generic `audio-speakers-symbolic`
    placeholder set at scaffold time - out of this phase's scope
    (sidebar icon only), and changing `KPlugin.Icon` to a `/`-prefixed
    path to fix it would risk breaking the "Add Widgets" list icon,
    which reads the same field differently - a real trade-off, not a
    free fix.
- [ ] **Phase 4.4.0.2 — About page: full polish, including its own icon.**
      The About page (Plasma-provided, `AboutPlugin.qml`, per the
      "Settings ConfigDialog" section of CLAUDE.md) still shows generic
      placeholder content from scaffold time - most visibly its own big
      icon, still the default `audio-speakers-symbolic` from
      `metadata.json`'s `KPlugin.Icon` rather than the widget's actual
      branding.
  - Icon: resolve the trade-off Phase 4.4.0.1 surfaced but didn't
    act on - `KPlugin.Icon` is read by at least two different
    consumers with different rules (`AboutPlugin.qml`'s special
    `/`-prefixed-path handling vs. the "Add Widgets" list's
    theme-name-only `QIcon::fromTheme()`, Phase 4.1). Changing it to
    fix the About page risks breaking the list icon there - confirm
    live whether that's actually a problem before deciding, rather
    than assuming either way; real hicolor icon-theme installation
    (avoiding the trade-off entirely) is deferred to real
    packaging work (Phase 4.5) per CLAUDE.md, so weigh a real fix now
    against that.
  - Everything else on the page Plasma auto-populates from
    `metadata.json`/`main.xml` (name/version, description, website,
    license, authors, "Get Help"/"Read License" links) - audit what
    actually shows today against what a real user should see, and
    fill in/correct anything missing or placeholder-looking (e.g. a
    real bug-report URL if one should exist, confirming the MIT
    license text actually resolves via "Read License", etc.) rather
    than assuming the scaffold-time values were ever revisited.
  - This is Plasma's own page (per CLAUDE.md, not ours to visually
    redesign) - scope is filling in real content via the metadata
    fields it already reads, not building custom QML for it.
  - **Addendum (mockup revised after this phase shipped):** the
    Appearance section's row order and Blur's description text
    described above reflect the mockup as it existed when this phase
    was built. The mockup was later revised to move Blur below
    Transparency and disable/dim it when Transparency is off - see
    Phase 4.4.2.1, which owns that reorder.

- [x] **Phase 4.4.2 — Volume step size wiring.** The settings page's
      "Step per scroll notch" segmented control (0.5/1/2 dB) now
      actually controls the volume step used by the main view's +/-
      buttons and slider, replacing the hardcoded 0.5dB from Phase 3.
  - **Investigated before implementing, per the phase's own
    instruction:** read the shell's own `AppletConfiguration.qml`
    (`open()`/`saveConfig()`/`isConfigurationChanged()`) directly
    rather than assuming a mechanism - confirmed the standard Plasma
    ConfigModule convention is a `cfg_<entryName>` property on the
    config page: the shell pushes the live KConfig value into it on
    dialog open and reads it back only on Apply/OK, also using
    `cfg_<entryName>Changed` to drive the Apply button's dirty state.
    Confirmed with you before implementing that this (Apply/OK-gated,
    matching every other stock Plasma settings page) was preferred
    over writing straight to `Plasmoid.configuration` from the click
    handler - the pattern later phases (4.4.3+) will reuse for the
    other controls.
  - `main.xml`: added `volumeStepDb` (`Double`, default `1.0` -
    matches the segmented control's Phase 4.4.1 mockup default).
  - `FullRepresentation.qml`: `volumeStepDb` now reads
    `Plasmoid.configuration.volumeStepDb` instead of a hardcoded
    literal - both existing consumers (`stepVolume()`, the slider's
    `stepSize`) already referenced `root.volumeStepDb`, so no other
    change was needed there.
  - `ConfigGeneral.qml`: added `cfg_volumeStepDb` and
    `stepValues: [0.5, 1, 2]`; `stepSegmented.activeIndex` is now a
    binding derived from `cfg_volumeStepDb` (`stepValues.indexOf(...)`)
    instead of a literal, and the click handler writes
    `cfg_volumeStepDb` instead of `activeIndex` directly, so the
    highlighted option follows automatically rather than needing two
    separate writes kept in sync.
  - **Verified live by you (2026-08-29):** all three of 0.5/1/2 dB
    move the amp's actual volume by exactly that amount via the +/-
    buttons; the settings dialog shows the correct previously-selected
    option after close/reopen; the step size survives a full
    `kpackagetool6`/`plasmashell --replace` reload. Bonus finding not
    originally in scope: dragging the volume slider itself also snaps
    to the configured step size per increment, confirming
    `stepSize: root.volumeStepDb` behaves the same way as the button
    handlers.

- [x] **Phase 4.4.2.1 — Appearance section: reorder Blur below
      Transparency, add dependent-row disable.** Per the mockup's
      revision (`devialet_config_dialog_mockup_v3.html`): "Blur
      background" now sits below Transparency (and its slider sub-row)
      instead of above it, its description text is now "Glassy
      vibrancy behind the flyout. Requires transparency to enable.",
      and its row dims/disables whenever the Transparency switch is
      off. Still purely visual/no-op, same as the rest of Phase
      4.4.1 - both toggles remain local UI state only, nothing wired to
      real KConfig or background rendering yet.
  - **Investigated before implementing, per instruction:** read
    `SettingsRow.qml`/`SettingsSwitch.qml` directly rather than
    assuming a disable mechanism existed. Confirmed `SettingsRow`'s
    root is a bare `ColumnLayout` (an `Item` subclass) with no
    `opacity`/`enabled` alias of its own - none was needed, since Qt
    Quick's `opacity` and `enabled` are both documented as cascading
    down an item's entire child subtree automatically (`Item.enabled`'s
    own doc: a disabled ancestor disables all descendants regardless of
    their own `enabled` value). This is the same mechanism the existing
    Transparency slider sub-row already relied on
    (`ConfigGeneral.qml`'s bare `RowLayout` with
    `opacity`/`enabled`/`Behavior on opacity` bound to
    `transSwitch.checked`) - so Blur's `SettingsRow` instance just
    needed the identical three bindings added directly on it, no change
    to `SettingsRow.qml`/`SettingsSwitch.qml` themselves.
  - `ConfigGeneral.qml`: moved the Transparency `SettingsRow` + its
    slider sub-row above Blur's `SettingsRow`; updated Blur's `desc`;
    added `opacity: transSwitch.checked ? 1.0 : 0.35`,
    `enabled: transSwitch.checked`, `Behavior on opacity` to Blur's
    `SettingsRow`.
  - **Verified live by you:** all four checks confirmed - Blur's row
    fully interactive with Transparency on; dims and becomes
    unclickable immediately when Transparency is switched off; re-
    enables immediately when switched back on; row order matches the
    mockup exactly (Transparency + slider sub-row, then Blur beneath).

- [x] **Phase 4.4.3 — Transparency on/off wiring.** Toggle's value now
      lives in `plasmoid.configuration` (KConfig), persists across
      dialog closes and widget reloads, and actually drives a fixed
      alpha on the flyout's own content background when on (fully
      opaque when off) — the slider's own live value is still Phase
      4.4.4's job, this phase only needed *some* fixed on-level.
  - `main.xml`: added `transparencyEnabled` (`Bool`, default `true` —
    matches the toggle's existing default-on state from Phase
    4.4.1/4.4.2.1).
  - `FullRepresentation.qml`: added `root.transparencyEnabled`, reading
    `Plasmoid.configuration.transparencyEnabled` directly (same live-
    read pattern as Phase 4.4.2's `volumeStepDb`, no manual re-fetch
    needed). The panel background gradient's two `GradientStop` colors
    (`FullRepresentation.qml:725-739`) now build their color via
    `Qt.rgba(theme color's r/g/b, transparencyEnabled ? 0.82 : 1.0)`
    instead of reading the theme colors' baked-in alpha directly - RGB
    still comes from `Theme.qml` unchanged, only alpha is substituted
    at render time. 0.82 is the exact value already shipping pre-phase
    (no visual change for a fresh/default install); off is fully
    opaque (1.0), as confirmed before implementing.
  - `ConfigGeneral.qml`: added `cfg_transparencyEnabled` (same
    cfg_/Apply-OK-gated convention as `cfg_volumeStepDb`).
    `transSwitch`'s `checked` binds to it; `onCheckedChanged` writes
    back, since `SettingsSwitch` self-toggles internally (its own
    `MouseArea` assigns its own `checked`, which severs the external
    binding after the first click in a given dialog session - flagged
    and confirmed acceptable before implementing, since
    `onCheckedChanged` keeps `cfg_transparencyEnabled` in sync from
    then on regardless, and a dialog reopen creates a fresh
    `SettingsSwitch` instance with an unbroken binding).
    `SettingsSwitch.qml` itself untouched.
  - **Verified live, measured rather than eyeballed** (matching or
    exceeding the phase's own request, since a same-wallpaper on/off
    screenshot pair looked visually indistinguishable to you at first
    glance): pixel-diffed the two real screenshots. Differing pixels
    were confined exactly to the flyout's own bounds (x 1623-1954,
    y 45-457), confirming the change is scoped correctly. Sampling flat
    background areas of the panel (avoiding text/icons): on-values
    consistently ~2-5/255 higher than off-values, blue channel shifting
    most (+3 to +5) - exactly the expected direction for an 18%
    wallpaper blend through a dark, blue-leaning starfield background.
    Grid-averaged diff across the whole panel background: **+1.7, +1.7,
    +3.3** (R, G, B). "Off" measured within 1-2/255 of the flat theme
    color (23,23,26)/(18,18,20) - i.e. genuinely opaque, not just
    visually close. Confirms the toggle is compositing a real 0.82-
    alpha blend, not a no-op - the effect is small enough to be
    imperceptible by eye at this specific wallpaper region (dark
    starfield behind the panel, similar luminance to the panel itself)
    but is real and directionally consistent with the intended alpha
    value; expected to be far more visible against a brighter part of
    a wallpaper, or once Phase 4.4.4's slider allows a lower alpha.
    Reload (`kpackagetool6 --upgrade` + `plasmashell --replace`)
    confirmed the setting survives a full widget restart.
  - **Addendum — Transparency removed from main in `e084543`.** Real
    desktop transparency was investigated on `experiment/real-
    transparency` and found infeasible: the widget's actual popup
    window class (`PlasmaWindow`, not `Dialog` as originally assumed)
    has no background-removal option at all on this Plasma version,
    and transparency visible under other themes (e.g. Ant-Dark) on
    other widgets comes from that theme's own frame asset, not
    anything an applet can control. See CLAUDE.md's Known Issues entry
    for the full investigation. Branch deleted - this note plus
    CLAUDE.md's entry is the complete record; there is no further
    history to recover.
  - **Verified live by you:** with this removal in place, all
    appearance-based settings are now gone from the widget - Blur
    (Phase 4.4.2.2, already removed earlier) and Transparency (toggle
    + slider, this removal) alike. Settings dialog's General page goes
    straight from the brand header to the Volume section, no Appearance
    label, no orphaned gap.

- [x] **Phase 4.4.2.2 — Remove Blur background setting.** Per revised
      design/mockups/devialet_config_dialog_mockup_v4.html: the
      Appearance section now shows Transparency only, no Blur row.
      Blur is dropped as a feature entirely - real desktop
      transparency requires `Plasmoid.backgroundHints = NoBackground`
      (Phase 4.4.X, next), which removes the same system frame that
      provides KWin blur-behind eligibility, so a Blur toggle could
      never do anything useful once transparency actually works. Pure
      removal: Phase 4.4.2.1 had added Blur's row styling and its
      dependent-disable-on-Transparency logic, but no `main.xml` entry
      or `backgroundHints` wiring was ever added (Blur wiring was
      never reached) - nothing else to unwire.
  - **Investigated before implementing, per instruction:** confirmed
    the Blur `SettingsRow` block (`ConfigGeneral.qml`) was the only
    place referencing it - grepped the whole `plasmoid/` tree for
    "blur"; the only other hits were the Transparency slider's own,
    separate dependent-disable sub-row (unrelated, stays), and the
    real KWin blur-behind backdrop effect in `FullRepresentation.qml`/
    `Theme.qml` (a different, still-live feature, not the config-page
    toggle). Confirmed `main.xml` had no `blur` `<entry>` to remove -
    Blur wiring was never reached, exactly as expected.
  - `ConfigGeneral.qml`: removed the Blur `SettingsRow` (name, desc,
    `SettingsSwitch`) and its `opacity`/`enabled`/`Behavior on opacity`
    dependent-disable bindings, in full. Transparency's own switch and
    slider sub-row untouched.
  - `main.xml`: trimmed the stray "blur" mention from the Phase 4.4.0
    doc comment listing future `<entry>` elements (doc-only, no
    functional change).
  - **Verified live by you:** settings page's Appearance section shows
    only Transparency with its slider, no Blur row, no leftover gap.
    Matches the mockup exactly.

- [x] **Phase 4.5.1 — Scroll over volume slider to adjust volume.**
      Investigated before implementing, per the phase's own instruction.
  - **QQC2 wheel handling, investigated rather than assumed:** the real
    QQC2 style for `Slider` on this system, `org.kde.desktop`'s
    `Slider.qml`, does ship built-in wheel handling — but it lives
    inside a `MouseArea` nested in the style's own `background:`
    delegate, and `volumeSlider` (`FullRepresentation.qml`) already
    replaces `background:` entirely with a custom copper-track
    `Rectangle` (Phase 4.0), which discards that `MouseArea` along with
    everything else the style put there. The style's handler also only
    calls `controlRoot.increase()`/`decrease()` (moves the Slider's own
    `value`), not this app's actual commit path — so it couldn't have
    been reused as-is even if `background:` were untouched. Confirmed
    via `grep` that no `onWheel`/`WheelHandler` existed anywhere in
    `FullRepresentation.qml` before this phase.
  - **Direction confirmed** against the style's own convention:
    `wheel.angleDelta.y` positive (scroll up) = volume up, using
    `wheel.inverted` to auto-correct for the user's OS-level "natural
    scrolling" setting rather than special-casing it.
  - **Drag-interaction behavior, proposed and confirmed before
    implementing:** scroll is blocked entirely while
    `volumeSlider.pressed` is true. Reasoning: the Slider's `value`
    binding is suppressed while pressed and release unconditionally
    overwrites `root.volumeDb` with the drag position, so a wheel step
    applied mid-drag would be sent to the amp and then silently
    clobbered the moment the drag ends — blocking during drag avoids
    that race, consistent with how `root.volumeInteracting` already
    treats an active drag as an exclusive-input state elsewhere in this
    file.
  - **Implementation:** added a `MouseArea` (`acceptedButtons:
    Qt.NoButton`, so press/drag still passes through to the Slider
    untouched — the same technique the style's own handler uses)
    inside `volumeSlider`, accumulating `angleDelta` into 120-unit
    notches (matching `org.kde.desktop`'s own convention, since
    trackpads/high-resolution wheels send many small-delta events per
    gesture) and calling `root.stepVolume(1)`/`root.stepVolume(-1)` per
    notch — reusing the exact same commit path (optimistic update,
    debounce timestamp, `devialet-ctl` invocation) the +/- buttons
    already use, rather than a new parallel code path.
  - **Verified live by you:** scrolling over the slider changes the
    volume by exactly one `volumeStepDb` step per notch in both
    directions, confirmed across multiple different configured step
    sizes; scrolling while dragging the thumb does nothing.

- [x] **Phase 4.5.0 — Scroll over panel icon to adjust volume, with
      on-screen volume indicator.** Renamed from "scroll-over-tray-icon"
      (panel-pinned, not tray-hosted) — scope unchanged. Investigated
      before implementing, per the phase's own instruction.
  - **Real Volume applet precedent, pulled from `invent.kde.org`'s
    `plasma-pa` source directly (not assumed):** its own custom
    `compactRepresentation` `MouseArea` (`applet/main.qml:209-267`)
    already does the identical 120-unit-notch wheel accumulation this
    project's own 4.5.1 slider scroll uses. Its hover text is driven
    entirely by `PlasmoidItem.toolTipMainText`/`toolTipSubText` — no
    custom tooltip popup exists in its QML at all. Its transient toast
    isn't custom either: `config.volumeOsd` is just a flag: the actual
    OSD is a **shared system service**, `org.kde.plasmashell`'s
    `/org/kde/osdService` (`org.kde.osdService`), reached via
    `GlobalService::volumeUp()` → a `kglobalaccel` shortcut → a `kded`
    module → that service (`src/qml/globalservice.cpp`).
  - **Confirmed live, not just read:** called `org.kde.osdService`
    directly over D-Bus and screenshotted the result — `showText(icon,
    text)` accepts an arbitrary resolvable icon path (rendered this
    project's own SVG correctly, not just icon-theme names) and gives
    full text control, unlike `volumeChanged(percent, max)` which
    renders the literal system-volume-style progress bar (ruled out —
    risks being mistaken for real OS/PC volume, which the phase brief
    explicitly warned against). Its real dismiss timeout is a fixed
    **1800ms** (`OsdItem.qml:19`, confirmed on-disk on this system —
    not the brief's own rough "~1s"). Its rapid-repeat behavior
    (`plasma-workspace`'s `shell/osd.cpp`, `showOsd()`): every call
    stops the pending dismiss timer, snaps content to the new value
    instantly, restarts the same fixed timeout — reset-and-replace, no
    queueing.
  - **Architecture decision, confirmed with you before implementing:**
    `CompactRepresentation.qml` gets its **own independent** D-Bus
    mirror (`AmpIp`/`DeviceName`/`VolumeDb`) and its own `stepVolume()`,
    not a refactor to share `FullRepresentation`'s much richer one.
    Reason, confirmed by reading `libplasma`'s `appletquickitem.cpp`:
    `fullRepresentationItem` is only *opportunistically* preloaded in
    the background per an adaptive weight/policy (`AppletQuickItem::
    init()`), not guaranteed to exist by the time a user first hovers
    the icon. Real precedent for this split: the real Volume applet's
    own compact `MouseArea` and its `VolumeSlider.qml` also implement
    wheel-to-volume independently, sharing no function between them.
  - **Hover indicator:** `main.qml`'s `PlasmoidItem.toolTipItem` (a
    real, less-known property alongside `toolTipMainText`/`SubText` —
    confirmed in `libplasma`'s `plasmoiditem.cpp`) set to a new custom
    `VolumeHoverTooltip.qml`, chosen over plain text per your call for
    a copper-styled indicator instead of generic tooltip text — still
    rendered inside the shell's own native, already-solved tooltip
    dialog, avoiding this project's past QQC2-popup-outside-a-genuine-
    Window issues entirely.
  - **Toast:** new `VolumeToast.qml`, a `PlasmaCore.Dialog` with `type:
    OnScreenDisplay` — confirmed via `libplasma`'s `dialog.cpp` that on
    Wayland this calls the *identical* `PlasmaShellWaylandIntegration::
    setRole(role_onscreendisplay)` the real OSD's own window uses, and
    that `Dialog` deliberately skips its own manual `setPosition()` call
    for this type specifically (the compositor places it, matching the
    real OSD exactly — not an icon-anchored popup like the flyout, a
    faithful reskin means matching where the native OSD already
    appears). `backgroundHints: NoBackground` made the fully custom
    copper pill possible — confirmed this is a *different* class than
    the "real transparency" investigation's dead end (that was
    `PlasmaWindow`, the flyout's own window class, whose restricted
    `BackgroundHints` enum has no such value; `PlasmaQuick::Dialog`,
    built directly by this file, genuinely has one). 1800ms `Timer`,
    `restart()` on every `show()` call — same stop/update/restart shape
    as the real `showOsd()`.
  - **Real bug found and fixed, via `journalctl` (not guessed):**
    `PlasmaCore.Dialog`'s default property `mainItem` is a single
    `QQuickItem*`, not a list — a bare `Timer` declared as a sibling of
    the explicit `mainItem: Rectangle {...}` was *also* being implicitly
    assigned to it, throwing `"Cannot assign object of type Timer to
    property of type QQuickItem*"` and silently breaking the whole
    applet's load (confirmed nothing rendered — `com.ekmanch.
    devialetremote` was missing from the panel entirely; `journalctl`
    showed the real error line). Fixed by nesting the `Timer` inside the
    `Rectangle` instead.
  - **Also fixed, found along the way:** `~/.local/bin/devialet-ctl`
    was a stale symlink pointing at a pre-`own/`-subdirectory-move repo
    path — broken regardless of this phase, silently blocking every
    `devialet-ctl` invocation. Relinked to the real build output.
  - **Verified myself:** applet reloads with no new QML load errors
    (`journalctl`, before/after comparison); the panel icon still
    renders at its correct position and color (pixel-scanned a live
    `spectacle` screenshot for its distinctive copper RGB values rather
    than eyeballing — same technique Phase 4.11 used).
  - **Could not verify myself, confirmed by you instead:** the actual
    hover/scroll/toast interaction. Tried synthesizing mouse input via
    a virtual `uinput` device (absolute-positioning "tablet" device,
    then a plain relative-motion "mouse" device) to test this without
    you — unreliable on your live, shared desktop; synthetic cursor
    positioning kept landing nowhere near the target, most likely real
    concurrent mouse activity on your end interfering, confirmed via a
    KWin script reading `workspace.cursorPos` mid-test. Abandoned rather
    than keep burning time on it; you confirmed hover/scroll/toast/
    click-regression all work live instead.
  - **Incidental finding, not investigated further:** a screenshot taken
    during verification happened to capture a separate, already-open
    Claude conversation of yours with richer tooltip/OSD mockups
    (`devialet_tray_tooltip_mockup_v4.html`, `devialet_volume_osd_
    mockup_v3.html` — device name + dB + copper progress bar + hint
    lines) — this directly matches Phase 4.5.3 below, which already
    scopes exactly that redesign. Flagged to you rather than acted on.
  - Toast/tooltip visuals shipped here are a deliberate placeholder
    (plain copper pill, amp glow-dot icon, dB text) — Phase 4.5.3 below
    already owns the real mockup-matched design.

- [x] **Phase 4.5.2 — Middle-click panel icon to mute.** Investigated
      before implementing, per the phase's own instruction.
  - **Confirmed:** `CompactRepresentation`'s `MouseArea` had no
    `acceptedButtons` override at all before this phase — defaulted to
    `Qt.LeftButton` only, so middle-click previously did nothing, not
    even firing an unhandled signal.
  - **Real Volume applet precedent** (`applet/main.qml:209-233`, same
    source pulled for 4.5.0): `acceptedButtons: Qt.LeftButton |
    Qt.MiddleButton`, with middle-click-mute firing in `onPressed` (not
    `onClicked`), and left-click using a capture-on-press/apply-on-
    release (`wasExpanded`) dance specific to that applet's own hover-
    preview complexity — which this project's simpler compact
    representation doesn't have, so that dance wasn't ported. Confirmed
    with you before implementing: kept everything in one `onClicked`
    handler branching on `mouse.button`, for consistency with this
    file's existing single-handler style, rather than splitting mute
    into `onPressed`.
  - **Confirmed there's no extracted method to "call the same one
    as."** The flyout's own Mute button's toggle logic
    (`FullRepresentation.qml`, `onClicked` ~line 1451) is inline, not a
    named function, and uses that file's own `root` — unreachable from
    `CompactRepresentation` for the same reason `stepVolume()` was
    reimplemented independently in 4.5.0, not shared. Replicated the
    identical logic and command shape (`devialet-ctl ... mute on|off`,
    same 400ms debounce window) independently in
    `CompactRepresentation`'s own mirror, extending its existing D-Bus
    subscription with a `Muted` property the same way `VolumeDb`
    already works.
  - Toast on middle-click-mute: confirmed with you to show ("<amp>:
    Muted"/"Unmuted"), reusing the exact same placeholder pill/icon
    already shipped for volume-step toasts in 4.5.0 — no new visual
    state, per your explicit call to leave real mute styling for
    4.5.3's mockup-matched redesign.
  - **Verified myself:** the exact command path `toggleMute()` invokes,
    run directly against the real amp — `devialet-ctl --ip 192.168.0.22
    mute on` flipped the real `Muted` D-Bus property to `true`; `mute
    off` flipped it back to `false`; confirmed both directions via
    `busctl`. No new QML load errors after reinstall; icon still
    renders correctly (same regression check as 4.5.0).
  - **Verified live by you:** middle-click toggles mute both directions
    against the real amp; left-click flyout-toggle and 4.5.0's
    scroll-to-volume both still work with no regression; the toast
    shows correctly on middle-click.

- [x] **Phase 4.5.3 — Tooltip/OSD visual polish + positioning.** Landed
      over several rounds - the initial mockup-matching pass, then a
      series of real bugs found via direct live measurement rather than
      assumed fixed. Final state: tooltip and OSD both mockup-matched,
      icon thresholds sourced from the real Audio Devices applet, OSD
      positioning fixed, and four real tooltip bugs found and fixed
      (one of which explains a second, separately-reported bug as a
      side effect).
  - **Parts A/B (styling, direct mockup match, no open questions):**
    `VolumeToast.qml` restyled to `devialet_volume_osd_mockup_v3.html`
    (icon + name/value row + copper bar + source line, copper
    border/glow + dimmed fill for muted, word-sized copper text for
    "Muted"); `VolumeHoverTooltip.qml` restyled to
    `devialet_tray_tooltip_mockup_v4.html` (dot + name row, source/dB
    stat row, copper bar, plain-text hints).
  - **Part C (OSD positioning) root-caused, not guessed:** the toast's
    own `flags: Qt.ToolTip` (added in 4.5.0 without strong
    justification) was fighting `Dialog`'s `OnScreenDisplay` handling -
    confirmed in `libplasma`'s `dialog.cpp`: `applyType()` gates several
    behaviors on `!flags().testFlag(Qt::ToolTip)`, with a comment
    stating "an OSD can't be a Dialog, as qt xcb would attempt to set a
    transient parent for it" - `Qt::ToolTip` is the same transient-
    parent-seeking category of flag. The real `OsdWindow`
    (`plasma-workspace`'s `shell/osdwindow.cpp`) sets only
    `Qt::WindowDoesNotAcceptFocus` + `Qt::WindowTransparentForInput`, no
    `Qt::ToolTip` at all. Matched those flags exactly (`outputOnly: true`
    for the second one, since `Dialog`'s own code ties that flag to
    `outputOnly` specifically for `OnScreenDisplay`). Confirmed live:
    the toast now lands in the same screen position (same horizontal
    center, same vertical band) as the real native OSD, tested by
    triggering both and comparing pixel positions directly.
  - **Part D (icon thresholds), matched to real precedent:** found
    `AudioIcon::forVolume()` in `plasma-pa`'s `src/audioicon.cpp/.h` -
    muted or ≤0% → mute, ≤25% → low, ≤75% → medium, ≤100% → high (its
    further 101–125%/>125% "warning"/"danger" tiers have no equivalent
    icon and no meaning here, since `volumeFraction` is hard-clamped to
    0..1 with no PulseAudio-style overdrive concept). Centralized as
    `Theme.qml`'s `volumeIconSources`/`volumeIconKindForFraction`, used
    by `VolumeToast.qml`'s icon box.
  - **Bug found and fixed: OSD volume icon never rendered.** Root cause:
    the four `design/icons/audio_volume_icons/*.svg` files were never
    copied into `plasmoid/contents/icons/` - `design/` is a source-only
    location outside the KPackage payload (same rule as Phase 4.0's
    fonts/Phase 4.11's icons), so the resolved URL pointed at a
    nonexistent file. Fixed by bundling the SVGs properly; the
    `Kirigami.Icon` + `isMask: true` + `color` approach itself was
    already correct (proven elsewhere in this codebase for other
    `currentColor` SVGs).
  - **Bug found and fixed: OSD layout shifted between muted/unmuted.**
    Root cause: the icon+body `RowLayout` used `anchors.centerIn: parent`
    inside a card whose `implicitWidth` floors at `Math.max(340,
    row.implicitWidth + 36)` - a short "Muted" value made `row` narrower
    than 340, centering it inside the wider card and shifting everything
    inward; a wide numeric dB reading kept `row` close to 340, looking
    flush by comparison. Fixed with fixed left/right anchors margins
    (16/20, matching the mockup's own `padding` values) instead of
    centering - matches the mockup's actual flexbox model, where the
    icon is fixed-size and the body is `flex:1`, not centered content.
  - **Bug investigated, real limitation confirmed (not fixed, since it
    can't be): tooltip's own background had a visible double border.**
    `PlasmoidItem.toolTipItem` hands content to the shell's own
    `ToolTipDialog` (`PopupPlasmaWindow → PlasmaWindow`), whose
    `BackgroundHints` enum (confirmed in `libplasma`'s `plasmawindow.h`)
    has no `NoBackground` value at all - the same limitation CLAUDE.md's
    own real-transparency investigation already found for the flyout's
    popup. Mitigated short-term by dropping the tooltip's own competing
    border (a second, differently-colored stroke was what turned an
    otherwise-faint, unavoidable edge into a visible double border) -
    later fully superseded (see below) by rebuilding the tooltip as our
    own Dialog entirely, which sidesteps the limitation instead of just
    softening it.
  - **Follow-up round 1 - real bug: the shell's native tooltip kept
    appearing alongside the custom one**, showing `metadata.json`'s
    Name/Comment. Root-caused via `libplasma`'s `plasmoiditem.cpp`:
    `toolTipMainText()`/`toolTipSubText()` fall back to `applet()->
    title()`/`pluginMetaData().description()` whenever the backing
    string is *null* (the default) - merely leaving the binding unset
    never clears that, only an explicit empty-string assignment does
    (the setter's own comment explains the null-vs-empty distinction is
    intentional). Fixed in `main.qml` with explicit `toolTipMainText: ""`
    / `toolTipSubText: ""`.
  - **Follow-up round 1 - architecture change: rebuilt the tooltip as
    its own `PlasmaCore.Dialog`** (`type: Tooltip`, matching the real
    `role_tooltip` Wayland role, `backgroundHints: NoBackground`,
    `location: Plasmoid.location` for automatic `visualParent`-relative
    placement via `Dialog::popupPosition()`) instead of going through
    `PlasmoidItem.toolTipItem` at all - this is what actually solves the
    double-border limitation above for real, the same way `VolumeToast.
    qml` already solves it for the OSD (`PlasmaQuick::Dialog`'s
    `BackgroundHints` enum, confirmed in `libplasma`'s `dialog.h`, does
    include a real `NoBackground`, unlike the shell's fixed
    `PlasmaWindow`-based `ToolTipDialog`). Show/hide timing replicates
    `ToolTipArea`/`ToolTipDialog`'s own real behavior, read from source
    rather than invented: `Kirigami.Units.toolTipDelay` (700ms) before
    first showing, a 200ms grace period before hiding (matching
    `ToolTipDialog::dismiss()`'s own hardcoded value) - both timers now
    live in `CompactRepresentation.qml`'s hover handlers.
  - **Follow-up round 1 - bug found and fixed: tooltip didn't reflect
    Muted state**, showing a stale dB reading instead of "Muted" the way
    `VolumeToast.qml` already did. Root cause: the `muted` property was
    simply never wired into the new tooltip at all. Fixed by adding the
    binding, sourced from the same `Muted` D-Bus mirror
    `CompactRepresentation` already had for other purposes - confirmed
    live it updates instantly even while already hovering, no need to
    re-trigger.
  - **Follow-up round 1 - bug found and fixed: tooltip stayed open over
    an already-opened flyout** if the mouse was still hovering when it
    opened. Fixed with a `Connections` block watching `expanded` and
    force-hiding the tooltip - target had to be `root.plasmoidItem`
    directly, not the `Plasmoid` attached property, since the latter
    produced the exact same "no signal matches" warning already present
    (and never fixed) at `FullRepresentation.qml:216` - fixed that
    warning here rather than reproducing it.
  - **Follow-up round 2 - bug found and fixed: tooltip could still
    re-appear over an open flyout.** The round-1 fix only reacted to the
    `expanded` *transition*; leaving and re-entering the icon while
    already expanded restarted the show timer with nothing to stop it.
    Fixed by checking `root.plasmoidItem.expanded` at both trigger
    points - `onEntered` (before starting the show timer) and the
    timer's own `onTriggered` (in case `expanded` flips true during the
    pending delay) - not just once on the open transition. Verified live
    across 4 leave/re-enter cycles with the flyout open: tooltip never
    reappeared.
  - **Follow-up round 2 - investigated, no bug found: tooltip/OSD
    background opacity "mismatch."** Measured by you at ~(24,22,23) vs.
    ~(31,24,24), a real, consistent, larger-than-noise difference.
    Confirmed via `libplasma`'s `dialog.cpp` that `backgroundHints:
    NoBackground` explicitly disables `KWindowEffects::enableBlurBehind`/
    `enableBackgroundContrast` for *both* windows identically; confirmed
    KWin's Translucency effect (which does have per-window-type opacity)
    isn't even loaded on this system; confirmed `diminactive`'s own
    source treats `Tooltip`/`OnScreenDisplay` identically (neither
    qualifies for dimming). Settled empirically: opened both windows
    over a reversed-brightness backdrop (dark tab bar vs. white page)
    and the relative brightness relationship flipped, with both
    windows' fill pixels matching their shared `Theme.qml` gradient
    values almost exactly - the original measurement was a real but
    backdrop-position artifact of comparing two windows at different
    screen locations over a non-uniform wallpaper, not a rendering
    discrepancy. No code changed.
  - **Follow-up round 2 - reverted a mistake: OSD-style volume icon
    added to the tooltip.** The approved v4 mockup only ever used a
    small status dot next to the amp name, never a full icon box -
    adding one was a misreading of an earlier instruction, not something
    the approved design called for. Reverted to the dot in both normal
    and muted states; kept the "Muted" text-swap (that part was
    correct) and the OSD-matched background/radius/border.
  - **Follow-up round 3 - real bug found and fixed: "Optical 1" and the
    dB value/"Muted" weren't sharing a baseline.** Reported as "Optical
    1 sitting over the volume number"; confirmed live via screenshot.
    Root cause: the value+unit pair was nested inside its own
    `RowLayout`, and `Qt.AlignBaseline` doesn't work on a *nested*
    layout - a generic layout container has no real font-metric
    `baselineOffset` the way a `Label` does, so the outer `statRow` was
    baseline-aligning "Optical 1" to a real text baseline while aligning
    the wrapped value+unit pair to effectively nothing. Fixed by
    flattening the source/value/unit labels into direct siblings of
    `statRow`, each individually baseline-aligned. This same bug is also
    what explained the separately-reported "Optical 1's height shifts
    between muted and unmuted" report below.
  - **Follow-up round 3 - resolved with direct evidence: "Optical 1"
    vertical position reportedly shifting between muted/unmuted.**
    Requested controlled before/after screenshots rather than leaving it
    as an unconfirmed report. Root cause was the same nested-`RowLayout`
    baseline bug above - hiding the "dB" unit label in the muted state
    changed the inner (fake-baseline) container's own content, plausibly
    shifting its computed position between states. Captured muted vs.
    unmuted screenshots this session and diffed row band positions
    directly: after the baseline fix, positions match within ~2px
    (consistent with antialiasing noise) across every row. Resolved as a
    side effect of the round-3 structural fix, not a separate change.
  - **Follow-up round 3 - row-rhythm investigation: literal mockup CSS
    values don't reproduce the mockup's own rendering.** Requested to
    pull `.tt4-name-row`/`.tt4-stat-row` `margin-bottom` (5px/6px) 1:1 -
    confirmed those were already applied verbatim, yet rendered nearly
    equal gaps rather than the mockup's own ~65:100 (stat-row hugging
    the bar) rhythm. Rendered the actual mockup file in a real browser
    and measured its pixel gaps directly (~34px/24px, matching the
    reported ~64:100 ratio) - confirmed the mockup's own numbers don't
    mechanically produce its own rendered ratio either, most likely
    because its Google Fonts links don't resolve from a bare `file://`
    page, so its real rendering runs on fallback-font line-height
    metrics the declared px values don't capture (QML doesn't share this
    accidental effect, since it correctly loads the real bundled fonts).
    Tuned `nameRow`/`statRow` margins empirically instead (7/4),
    verified by the same pixel-band measurement technique, converging on
    a measured 65:100 gap ratio.
  - **Follow-up round 4 - real bug found and fixed: amp name row
      ("Devialet Expert 140 Pro") shifted vertically between muted/
      unmuted states.** Reported with two same-position screenshots;
      diffed them directly (row-band pixel counts, not eyeballing) and
      confirmed a real, exact +2px shift, not noise - the two states'
      row profiles matched pixel-for-pixel once offset by 2. Initial
      hypothesis (same nested-RowLayout baseline bug as statRow) didn't
      hold up on inspection - `nameRow` has no nested layout and no
      `Qt.AlignBaseline` at all, just a dot `Rectangle` and one `Label`
      as direct siblings. Root-caused instead with live
      `onYChanged`/`onHeightChanged` logging (via `journalctl`, values
      confirmed in logical px: `nameRow.y` measured 0 unmuted vs. 1
      muted, exactly matching the reported +2 physical-px shift at this
      system's 2x scale) - it wasn't `nameRow` itself: `statRow`'s own
      `implicitHeight` differs by 2px between states (16 muted / 18
      unmuted), because its "dB" unit `Label` is excluded from layout
      entirely via `visible: false` when muted (QtQuick Layouts drops
      invisible children from sizing, not just rendering) - and that
      swing was perturbing `ColumnLayout`'s positioning of `nameRow`,
      which comes *before* `statRow`, a QtQuick Layouts stacking
      artifact rather than a bug in nameRow's own structure. Fixed by
      pinning `statRow.Layout.preferredHeight: 18` (the taller,
      unmuted, natural height) so its contribution to the column can no
      longer fluctuate - removes the trigger at its source rather than
      patching nameRow for a problem that wasn't really there. Verified
      exactly like the statRow fix: controlled before/after screenshots
      at the same cursor position, row-band pixel-count diff - nameRow
      now matches pixel-for-pixel (0px difference) between states,
      confirmed by a whole-image diff showing zero remaining deviation
      outside the statRow/bar region where content is expected to
      legitimately differ.
  - **Verification methodology note:** this phase is also where a
    session-long testing blocker got root-caused - this system runs at
    2x display scale (logical 1920×1080, physical 3840×2160
    screenshots), which had been silently sending every synthetic
    hover/scroll/click coordinate to roughly double the correct
    position across every phase back through 4.5.0. Once corrected,
    synthetic `uinput`-driven mouse testing (hover, scroll, middle-click,
    multi-cycle re-entry) became reliable enough to verify all of the
    above directly rather than relying on you for every check.

- [x] **Bug fix — "Optical 1" shifts vertically between muted/unmuted
      states in VolumeHoverTooltip.qml (Phase 4.5.3 follow-up round
      5).** Discovered after fixing the nameRow shift (round 4) -
      nameRow and the progress bar held perfectly steady between
      states, but "Optical 1" itself still visibly moved a few pixels
      vertically depending on mute state, confirmed via side-by-side
      gridded screenshot comparison. Third instance of this exact
      symptom class in this same tooltip (statRow's own baseline bug,
      nameRow's ColumnLayout-positioning bug, now this) - each previous
      fix had only addressed the specific element that was visibly
      wrong at the time, not the underlying pattern. Scoped explicitly
      to check every element in the tooltip in one pass, not just
      "Optical 1" in isolation, so it wouldn't come back a fourth time
      as some other row.
  - **Actual root cause: `Qt.AlignBaseline` itself, not any remaining
    container-sizing leak.** Prior rounds 3/4 fixed a nested-layout
    baseline bug and an outer-height leak, but left `statRow`'s three
    children (`sourceName`, the value Label, the "dB" unit Label) on
    `Qt.AlignBaseline`. That alignment computes one shared baseline
    offset *within* the row from the font metrics of whichever children
    currently participate - and that still varied by mute state even
    with a pinned row height: the value Label swaps
    `font.family`/`pixelSize`/`weight` between the numeric and "Muted"
    forms (different glyph ascent), and the "dB" Label drops out of the
    row's sizing/baseline computation entirely via `visible: false`
    when muted. So every baseline-aligned sibling - including
    `sourceName` ("Optical 1"), whose own font never changes - got
    repositioned along with the shifting computed baseline. Fixed by
    switching all three to `Qt.AlignVCenter`, which positions each
    Label from its own height only, with no dependency on sibling
    content/fonts/visibility - the actual pattern behind all three
    rounds (round 3, round 4, and this one) is "don't let one element's
    position be computed from another element's current content";
    `Qt.AlignVCenter` in a pinned-height row satisfies that
    unconditionally, `Qt.AlignBaseline` never did.
  - **Verified exhaustively, every element, not just "Optical 1"** -
    real amp, hover via synthetic uinput mouse (calibrated against
    `workspace.cursorPos` through a KWin script, since this system's 2x
    scale plus this device's pointer-acceleration curve otherwise
    overshoots), middle-click to toggle mute, `spectacle -f` captures
    at each state, restored to unmuted afterward (confirmed via
    `busctl get-property … Muted` → `false`).
    - Control capture (same state, re-shot): **0 differing pixels**
      across the full card - rules out screenshot/render noise before
      trusting any other measurement.
    - Unmuted vs. muted, whole-card pixel diff: differences confined to
      a single bbox, x[184,486] y[133,174] in the capture's own
      coordinates - exactly the value/unit text glyphs (legitimately
      different content) and the volume-bar fill color (legitimately
      mute-indicating). Zero differing pixels anywhere outside that
      box.
    - Row-band detection (per-row pixel std-dev across the card's full
      interior width, independent of the diff above) found 8 bands and
      every single one landed at the **identical y-range in both
      states**: card top edge (40-52), status dot (64-72), amp name
      text (88-107), statRow text row (128-153), progress bar
      (170-174), hint line 1 "Scroll to adjust" (194-211), hint line 2
      "Middle-click to mute" (222-236), card bottom edge (252-259).
      0px shift, not "within noise" - exact.
    - Conclusion: no element in the tooltip moves between mute states,
      confirmed quantitatively for every row, not assumed from
      "Optical 1" alone.

## Up next

- [ ] **Phase 5.0.0 — Daemon-owned pending-command state: VolumeDb/
      Muted.** First chunk of a 4-chunk phase fixing the "Bug:
      FullRepresentation lags behind CompactRepresentation" entry
      above (see that entry for the investigated root cause). Branch:
      **a dedicated branch off main, not bundled with any other
      in-flight work** — do not implement any part of Phase 5.0
      directly on main.
  - **Architecture decision, arrived at after evaluating alternatives
    (not defaulted to):** "the PC just issued a command and its value
    is authoritative until the amp confirms it or a timeout elapses"
    becomes daemon-owned state, mirroring `BeginPowerOnBoot`/
    `boot_deadline`'s already-proven shape exactly, rather than being
    reimplemented independently inside each QML representation (today's
    bug) or as a QML-only shared object. Rejected alternatives:
    - A QML-only shared singleton/object holding the pending value
      (no daemon changes) - technically viable (a root-anchored shared
      object, see Phase 5.0.2, IS part of this design) but rejected as
      the place for the *resolution logic itself* specifically because
      this project has zero QML test infrastructure - the
      confirmed-vs-expired logic would be untestable JS, whereas the
      identically-shaped `BeginPowerOnBoot` logic already has direct
      `cargo test` coverage this can copy the pattern of.
    - `pragma Singleton` for the shared object - investigated and
      rejected: this KPackage has no qmldir/module registration set up
      (confirmed - see `Theme.qml`'s own header comment, which already
      made this exact call for the same reason), and a true QML
      singleton is scoped to the `QQmlEngine`, which Plasma very likely
      shares across the whole shell process (not independently
      confirmed by reading libplasma source, flagged honestly) - risking
      state leaking between two instances of this widget if ever added
      to two panels at once. Root-anchored state (Phase 5.0.2) doesn't
      have this risk: it's naturally per-applet-instance.
    - Full consolidation of every mirrored D-Bus property (Sources,
      KnownAmps, Online, DeviceName, etc.) into one shared subscription
      - genuinely lifecycle-safe once anchored to root (confirmed: root
      is what *creates* both representations, so it strictly outlives
      either), and a legitimate future destination, but explicitly
      **out of scope for this phase** - larger blast radius than the
      reported bug, touches already-subtle logic (`Sources`/
      `KnownAmps`'s "delta payload isn't trustworthy, re-fetch instead"
      workaround) unrelated to it. This phase's new shared object
      (5.0.2) is sized to exactly `AmpIp`/`VolumeDb`/`Muted` and is a
      compatible first step toward that fuller consolidation later, not
      a competing direction - nothing built here would need reworking
      if that's ever separately decided.
  - **This chunk's scope, Rust only, no QML changes yet:**
    - `TrackedAmp` gains `pending_volume_db: Option<(f64, Instant)>`
      and `pending_muted: Option<(bool, Instant)>`, alongside the
      existing `boot_deadline` field.
    - New `resolve_pending_commands()`, called from `recompute()`
      alongside the existing `resolve_boot_deadlines()` - reuses the
      exact same trigger path (every real UDP packet via
      `ingest_status`, plus the 1s `POLL_TICK` fallback via
      `recompute_staleness`) with no new timer/task, exactly like
      `boot_deadline` today.
    - `recompute()`'s `Some(amp)` branch prefers the pending value over
      `amp.status.*` while it's live (not yet confirmed or expired).
    - Two new D-Bus methods, shaped exactly like `begin_power_on_boot`:
      `NotifyVolumeCommand(ip: String, db: f64)` and
      `NotifyMuteCommand(ip: String, muted: bool)` - no-op on an
      unknown `ip` (same guard style), otherwise set the pending
      field + deadline, `recompute()`, `emit_all()` if
      `!states_equal(before, self)`.
    - **Expiry window: 400ms.** Settled input, not re-derived here -
      already proven across three independent client implementations
      (Kotlin Android app, Flutter port, this widget's own existing
      `debounceMs`) as the window that prevents a stale in-flight
      broadcast from contradicting a command the PC just sent. Reuse
      it as-is for `resolve_pending_commands()`'s deadline.
    - Confirmation matching is exact, no epsilon: `Status::volume_db()`
      is `(volume_raw - 195) / 2.0`, an exact linear integer→0.5dB-step
      formula, so compare the expected `volume_raw` byte (or the
      pending dB value directly, always an exact 0.5dB step) for an
      exact match; `Muted` is a plain bool.
    - Note for later chunks, not this one: outbound command *pacing*
      during a continuous drag/scroll/held-button gesture (roughly
      100-200ms, a genuinely different concern from the 400ms trust
      window above) already exists client-side today (the `±` buttons'
      `autoRepeatInterval: 100`, the wheel's 120-unit notch
      accumulation, the slider's send-only-on-release) and needs no
      new constant here - each paced tick just becomes one more
      `NotifyVolumeCommand` call that replaces the prior pending value
      and re-arms its 400ms deadline, which is also why
      `volumeInteracting` becomes redundant later (Phase 5.0.3): a
      sustained gesture keeps re-arming the window continuously, so
      there's never a gap for a stale broadcast to land in.
  - **Test coverage, mirroring `BeginPowerOnBoot`'s existing test
    shape** (`power_state_is_booting_while_a_deadline_is_pending`,
    `..._resolves_to_on_once_a_real_broadcast_confirms`,
    `..._falls_back_to_off_once_the_deadline_elapses`) - at minimum:
    - Pending value is reported (not the amp's last real value) while
      not yet confirmed or expired.
    - A real broadcast whose `volume_raw`/`muted` matches the pending
      value clears it (confirmed path) and `states_equal` correctly
      reflects the field settling.
    - The deadline elapsing with no confirmation clears it and falls
      back to the amp's real last-known value (timeout path) - the
      `BeginPowerOnBoot`-equivalent of the boot-timeout-fallback test.
    - A second `Notify*` call before the first's deadline replaces the
      pending value *and* resets the deadline - covers rapid
      multi-step scrolling correctly superseding itself (matches what
      was actually observed live during this bug's investigation: a
      5-step rapid scroll settled on the latest value, skipping
      already-superseded intermediate ones).
    - Unknown `ip` is a no-op (matches `begin_power_on_boot`'s existing
      unknown-ip guard test).
  - **Independently mergeable** - no QML consumer exists yet. Verify
    via `cargo test` plus manual `busctl call` against the real running
    daemon (`NotifyVolumeCommand`/`NotifyMuteCommand`, then
    `busctl get-property … VolumeDb`/`Muted` before/after the 400ms
    window) before moving to 5.0.1.

- [ ] **Phase 5.0.1 — Shared, root-anchored QML consumer for VolumeDb/
      Muted.** Depends on 5.0.0 being merged.
  - New QML object (e.g. `PendingAmpState.qml`), instantiated once in
    `main.qml` and handed to **both** representations via the same
    `plasmoidItem: root` handoff `CompactRepresentation` already uses
    today - added identically to `FullRepresentation`, which has no
    such reference currently (`fullRepresentation: FullRepresentation
    {}` takes no property today; becomes
    `FullRepresentation { plasmoidItem: root }`, matching
    `CompactRepresentation`'s existing wiring exactly).
  - Owns its own `Dbus.Properties` subscription to the daemon
    interface. Because that subscription is interface-level, not
    per-property, it will unavoidably also receive `Online`/
    `DeviceName`/`Sources`/etc. - **explicitly ignore every key except
    `AmpIp`/`VolumeDb`/`Muted`.** Do not process or expose anything
    else here - that boundary is what keeps this chunk out of
    full-mirror-consolidation territory (see 5.0.0's rejected-
    alternatives note).
  - Exposes the resolved `volumeDb`/`muted` as plain properties
    (already reflecting whatever the daemon currently reports, pending
    or confirmed - no client-side re-implementation of the
    confirmed-vs-expired logic, that stays in the daemon per 5.0.1),
    plus `notifyVolume(db)`/`notifyMute(muted)` methods wrapping the
    two new D-Bus calls.
  - Wire this into `FullRepresentation` **only as a new, additional
    capability at this stage** - expose it for comparison/testing
    alongside `FullRepresentation`'s existing `volumeDb`/`muted`
    handling, but do not remove or rewire anything yet.
    `CompactRepresentation` similarly gets a reference but isn't cut
    over yet either. The goal of this chunk is proving the shared
    object itself behaves correctly under both representations'
    independent lifecycles before either one actually depends on it.
  - **Verify, proving lifecycle independence rather than assuming it
    from the design:**
    1. With only the panel icon present (flyout never opened),
       confirm the shared object initializes and updates correctly
       from real D-Bus signals.
    2. Open the flyout (both representations now loaded) and confirm
       the shared object reports consistently to both.
    3. Close the flyout (`FullRepresentation` unloaded again) and
       confirm `CompactRepresentation`'s reference keeps working
       completely unaffected.

- [ ] **Phase 5.0.2 — Migration: cut over, then delete what's
      redundant.** Depends on 5.0.1 being verified solid. Two
      sequenced steps, not simultaneous - each its own commit.
  - **Step A - cut over.** Change
    `CompactRepresentation.stepVolume()`/`toggleMute()` and
    `FullRepresentation`'s volume-slider-release/button-step/mute-
    button click handlers to also call the shared object's
    `notifyVolume()`/`notifyMute()` (alongside their existing
    `runCtl()`/`exec.connectSource()` UDP dispatch, unchanged), and
    switch each representation's *displayed* `volumeDb`/`muted` to
    read from the shared object instead of their own local optimistic
    copies. Leave the old local debounce/optimistic code in place but
    unused at this step - don't delete yet, so this diff stays
    reviewable and revertible in isolation from Step B.
  - **Step B - delete redundant code, only once Step A is verified
    live and solid.** `CompactRepresentation`'s `lastIconStepAtMs`,
    `lastMuteChangeAtMs`, and the local `root.volumeDb =`/
    `root.muted =` assignments; `FullRepresentation`'s
    `lastVolumeButtonStepAtMs`, `lastVolumeSliderReleaseAtMs`,
    `lastMuteChangeAtMs`, and the `volumeInteracting` gating in
    `onPropertiesChanged`'s `VolumeDb`/`Muted` branches (see 5.0.1's
    pacing note for why continuous re-notification during a held
    interaction already subsumes `volumeInteracting`'s job).
  - **Explicitly do not touch:** `FullRepresentation`'s slider
    drag-in-progress local visual feedback (the `Binding`'s
    `when: !volumeSlider.pressed` suppression, and the drag handle's
    own live position). That's pure local UI feedback during an active
    drag with no cross-representation consistency concern at all, and
    stays exactly as it is today.

- [ ] **Phase 5.0.3 — Live verification across every consumer.**
      Depends on 5.0.2. Real amp, every item below individually
      confirmed and reported - not a pass/fail summary:
  1. Scroll the panel icon with the flyout open - the flyout's slider
     updates with **no perceptible lag**, not just "faster than
     before." Compare directly against the OSD toast's own timing.
  2. Middle-click to mute/unmute with the flyout open - the Mute
     button's state updates with no perceptible lag.
  3. Trigger changes from the flyout's own controls (slider release,
     Mute button) and confirm the tooltip/OSD toast
     (`CompactRepresentation`-driven) reflect them correctly too - the
     fix must be symmetric (Full→Compact), not just the originally-
     reported Compact→Full direction.
  4. **Actually drag the flyout's own volume slider - don't assume
     from the design.** Confirm no regression: the live drag position
     is never perturbed by an incoming signal mid-drag, and the
     released value sticks correctly, now that `volumeInteracting`'s
     guard is gone and the daemon's own re-armed pending-deadline is
     what protects this window instead.
  5. Rapid multi-step scroll (several quick notches in succession) -
     confirm the daemon-reported value settles on the *last* value
     sent, not a superseded intermediate one (matches what this bug's
     investigation already observed live).
  6. Check the parked "hover tooltip defaults to Muted on initial
     load" bug (see Bugs section) as a side observation only.
     **Do not mark it fixed based on this phase's architecture alone**
     - it has never been root-caused, and this design is a plausible
     structural prevention for that whole *class* of bug (one
     synchronously-initialized shared object can't race two
     independent initializations against each other), not a confirmed
     fix for that specific ticket. If it genuinely no longer reproduces
     during this pass, say so explicitly with what was observed, and
     only then consider closing it on that evidence - not preemptively.

- [ ] **Phase 6.0.0 — devialet-ctl build + PATH placement.** Decide the
      real install location for the `devialet-ctl` binary (system-wide
      `/usr/local/bin`, user `~/.local/bin` placed by the script rather
      than the current manual symlink, or `cargo install` into
      `~/.cargo/bin`) and build/place it as part of the install script.
      Currently a manual `~/.local/bin` symlink per README — fine for
      dev, not a real install path.
  - Verify: `devialet-ctl` is invocable from a fresh shell with no
    manual step, on a machine that hasn't had it built/placed before.
- [ ] **Phase 6.0.1 — Plasmoid install step.** Wrap the `kpackagetool6`
      install/upgrade logic the script needs — including handling the
      "already installed, needs upgrade not install" case cleanly when
      the script is re-run on a system that already has the widget.
  - Verify: widget installs cleanly on a fresh system; re-running the
    script on an already-installed system upgrades cleanly with no
    `kpackagetool6` errors.
- [ ] **Phase 6.0.2 — Systemd user unit install.** Copy the Phase 3.6
      systemd unit file to `~/.config/systemd/user/`, `daemon-reload`,
      `enable --now` as part of the script.
  - Verify: `systemctl --user status` shows the daemon running
    immediately after install; survives a logout/login.
- [ ] **Phase 6.0.3 — Combined install.sh.** Sequence 4.6.0/4.6.1/4.6.2
      into one script a user runs after cloning the repo. Must be
      idempotent — safe to re-run on an already-installed system
      without duplicating units, breaking an existing install, or
      erroring out. Sensible failure messages if a step fails partway
      (don't leave the system in a half-installed state silently).
  - Verify: a clean clone → run script → fully working widget + daemon
    + CLI, end to end, no manual steps outside the script.
  - Note for packaging/install script phase: both the devialet-ctl
      symlink and the devialet-remote-daemon systemd unit's ExecStart
      have independently gone stale against pre-own/-move paths on
      this machine. The install script should generate/verify these
      paths against wherever the repo actually lives at install time,
      rather than leaving them as manually sed-substituted
      placeholders per the current README instructions - this class of
      bug will keep recurring otherwise.
- [ ] **Phase 6.0.4 — Uninstall script (decide scope first).** Decide
      deliberately whether an uninstall script is in scope for v1.0.0
      or explicitly deferred — don't let it default to "skipped"
      silently. If in scope: reverse of 4.6.3 (disable/remove the
      systemd unit, remove the plasmoid via `kpackagetool6 --remove`,
      remove the `devialet-ctl` binary from wherever 4.6.0 placed it).
  - Verify (if implemented): a full uninstall leaves no systemd unit,
    no installed plasmoid, and no leftover binary.
- [ ] **Phase 6.0.5 — README install instructions.** Replace the
      current manual multi-step install instructions with "clone the
      repo, run install.sh." Keep the manual steps documented separately
      only if 4.6.4's uninstall is deferred and manual removal
      instructions are still needed.

## Bugs

- [ ] **Bug: volume icon on flyout mute button does not update
      depending on mute/unmute state**

- [ ] **Bug: hover tooltip defaults to "Muted" on initial load, even
      when the amp isn't muted.** Observed right after
      plasmashell/widget reload: the tooltip shows "Muted" on first
      hover, while the OSD toast (reading the same underlying Muted
      D-Bus property) correctly shows the real unmuted state and
      current dB value at the same time. Suggests the tooltip's own
      Muted property mirror in CompactRepresentation.qml starts from
      an incorrect default (e.g. true, or uninitialized) and doesn't
      get corrected until an actual mute-state-changing event occurs,
      rather than being populated from a real Get call against the
      Muted D-Bus property on first load/first hover - the same
      "explicit Get on every property, don't trust an assumed default"
      principle already applied elsewhere in this project's D-Bus
      handling. Investigate CompactRepresentation's Muted mirror
      initialization specifically and fix so the tooltip's first-ever
      hover after a reload reflects the amp's actual real-time mute
      state, not a hardcoded/stale default.

- [ ] **Bug: FullRepresentation lags behind CompactRepresentation on
      amp-state changes triggered via the panel icon.** Observed while
      the flyout was open at the same time as interacting with the
      panel icon directly (Phase 4.5.0/4.5.2 scroll-to-volume and
      middle-click-to-mute).
  - Scrolling on the panel icon changes volume immediately (confirmed
    against the real amp, and the OSD toast reflects it instantly),
    but the flyout's own volume slider visibly lags before catching up
    to the new value - a noticeable delay, not an instant reflection.
  - Same pattern with mute: middle-clicking the panel icon toggles
    mute immediately (OSD toast updates instantly), but the flyout's
    Mute button state takes a visible moment before it shows the
    correct on/off state.
  - **Investigated (live, real amp): root-caused, not fixed yet.**
    None of the originally-listed candidates panned out -
    `FullRepresentation`'s `blocked` gating only ever checks its OWN
    timestamps (never touched by `CompactRepresentation`, confirmed via
    live logging: `blocked=false` on every observed signal), and its
    QML-side signal consumption is essentially instantaneous
    (sub-millisecond after the D-Bus signal's own timestamp). The
    actual cause: the amp only confirms a command via its own next
    periodic status broadcast (measured live at roughly 60-200ms+ per
    step, occasionally more), and `CompactRepresentation`'s OSD toast
    "looks instant" only because it echoes its OWN local optimistic
    value synchronously, with zero D-Bus wait - it isn't reading
    confirmed state at all. `FullRepresentation` has no such optimistic
    echo for a change it didn't itself originate, so it must wait for
    the real (broadcast-latency-bound) signal. This is exactly the
    same class of thing `BeginPowerOnBoot`/`boot_deadline` (Phase
    4.3.0) already solves for `Power` - just not yet extended to
    `VolumeDb`/`Muted`, and not yet shared by both representations. See
    **Phase 5.0.1-5.0.4 in "Up next"** for the scoped fix (daemon-owned
    pending-command state, consumed by both representations via one
    new shared object) - not implemented yet, dedicated branch, do not
    close this bug until that phase's live verification confirms it.
  - Distinct from the existing parked bug above ("widget doesn't
    reflect amp-initiated volume changes it didn't itself send") - that
    one describes a divergence that persists indefinitely until
    touched; this one is a delay that does eventually resolve on its
    own. Confirmed genuinely distinct, not the same root cause - the
    live investigation above is fully explained by amp-broadcast
    latency plus asymmetric optimism, with no connection found to the
    amp-initiated-change bug's mechanism.
- [ ] **Bug: widget doesn't reflect amp-initiated volume changes it
      didn't itself send.** Observed during Phase 4.3.1's live
      verification: after a real power-on (both via timeout-forced
      fallback and normal boot), the amp reports its actual post-boot
      default volume (-40dB, set in the Devialet configurator) but the
      widget continues showing whatever it displayed pre-power-off
      (e.g. -44.5dB) instead of updating to match. The mismatch
      persists indefinitely until the volume slider/step buttons are
      touched in the widget itself - at which point it starts tracking
      correctly again. Neither side appears to overwrite the other
      incorrectly; they just silently diverge and stay diverged.
  - Also reproduces on a completely normal boot (no timeout/fallback
    involved) - the widget shows its own stale pre-boot value (e.g.
    -42dB) while the amp is actually at its real -40dB default. Not
    specific to the Phase 4.3.0/4.3.1 boot-state work at all.
  - Same symptom previously observed in the Kotlin Android app - not
    new to this port, likely a pre-existing protocol/reactivity gap
    (amp-initiated volume changes not picked up unless the widget/app
    has sent a volume command at least once itself) rather than
    something specific to this widget's implementation.
  - Not investigated yet - root cause could be in the daemon (not
    picking up/re-broadcasting an amp-initiated UDP volume change) or
    the widget (not reacting to a D-Bus property it does receive).
    Likely also affects volume changes from the amp's own front panel
    or another remote, not just power-cycling - worth confirming.

## Not yet scoped / parked

- [ ] **Settings: OSD/tooltip background opacity slider.** Add a
      shared KConfig value (e.g. osdOpacity) controlling both
      VolumeToast.qml's and VolumeHoverTooltip.qml's background
      opacity, exposed as a slider in ConfigDialog's General section,
      following the same pattern as volumeStepDb (Phase 4.4.2). A
      touch more transparency than the current fixed value would look
      better by default, but making it a setting means it doesn't need
      to be re-litigated - the person can just tune it. Low priority,
      not blocking any current phase.
- [ ] **Future investigation: rebuild the flyout as a custom
      PlasmaCore.Dialog instead of the shell's managed
      expanded-representation popup.** Same underlying idea that
      solved the tooltip's double-border problem (Phase 4.5.3) - the
      flyout's current popup is backed by PlasmaWindow, which has no
      NoBackground option, the same root constraint. Building it as
      our own Dialog (like VolumeToast.qml/VolumeHoverTooltip.qml)
      would open up real background/transparency control on the
      flyout too.
  - Substantially higher risk than the OSD/tooltip work: FullRepresentation.qml
    is by far the largest, most heavily-tested surface in this
    codebase, with a draggable slider, buttons, expandable amp/source
    lists, and carefully-tuned drag-vs-scroll interaction rules
    (Phase 4.5.1's volumeInteracting gating). A hand-built Dialog needs
    to correctly reimplement dismiss-on-click-outside, focus handling,
    and screen-edge-aware positioning that currently come for free
    from being the shell's managed popup.
  - Requires its own dedicated investigation phase and a dedicated
    branch before any implementation, per this project's usual
    practice for risky/uncertain work - not something to attempt as
    part of routine OSD/tooltip polish.
  - **Scoping note carried over from VolumeHoverTooltip.qml's
    "Optical 1" bug (Phase 4.5.3 round 5, see Done) - watch for this
    pattern proactively here, don't rediscover it the same way.**
    That tooltip went through three separate rounds of the same
    underlying bug class before it was closed out: an element's screen
    position silently depending on a sibling's current content/
    visibility, rather than being fixed. `Qt.AlignBaseline` was the
    repeat offender - it computes a shared row-internal baseline
    offset from the font metrics of whichever children currently
    participate, so changing a sibling's font, text length, or
    visibility (e.g. a "Muted" label swapping font weight/size, a unit
    label toggling `visible: false`) silently repositioned OTHER
    elements in the same row that never themselves changed. Each round
    only fixed the specific element that happened to be visibly wrong
    at the time, not the underlying mechanism, which is why it kept
    resurfacing as a different element each round. The flyout is a
    much larger surface with far more dynamic content (amp list,
    source list, volume slider, multiple button states), so this is
    more likely to bite here, not less:
    - Be wary of `Qt.AlignBaseline` specifically, and generally of any
      Layout behavior (implicit sizing, baseline computation) that
      depends on which children currently exist/are visible/have which
      content, when that content is dynamic (mute state, amp name
      length, connection status, etc.).
    - Prefer fixed heights/widths and explicit anchors for rows
      containing dynamic text, rather than letting the layout
      auto-compute from current content - so a value changing never has
      a side effect on an unrelated sibling's position.
    - When something in the flyout is reported as "jumping" or
      "shifting" between states, check for this pattern specifically (a
      sibling's content-dependent layout property) before assuming it's
      a margin/padding/anchor value that just needs tuning - tuning
      margins was a dead end in all three rounds on this tooltip, since
      the real problem wasn't spacing, it was a computed value silently
      changing.
    - Not a strict rule to avoid `AlignBaseline`/Layouts entirely - just
      a known failure mode worth checking for early given how much more
      dynamic content the flyout has compared to this tooltip.
- [ ] **Phase 4.4.6 — Launch at login wiring.** Reading the toggle's
      displayed state must query actual systemd state
      (`systemctl --user is-enabled`), not a stored bool; toggling it
      calls `systemctl --user enable`/`disable` directly. Investigate
      the correct way to shell out to systemd from QML (likely the same
      `Plasma5Support.DataSource` executable-engine pattern already
      used for `devialet-ctl` invocations) and handle query/toggle
      failure explicitly rather than assuming success. Verify live:
      toggle it, confirm via `systemctl --user is-enabled` independently
      that it actually changed, not just that the UI shows a different
      state; restart the widget and confirm the toggle reflects real
      systemd state on load, not a remembered UI value.
- [ ] **Phase 4.4.7 — Forget remembered amps wiring.** Per the mockup:
      clears saved/known amp IPs so the daemon rediscovers via mDNS/UDP,
      and explicitly does **not** disconnect or forget the currently
      active/selected amp. Investigate before implementing: known amps
      are daemon-owned persisted state (Phase 4.2's architecture), so
      this needs a new daemon-side D-Bus method (e.g. `ForgetAllAmps`)
      — there is no existing way to clear this from outside the daemon
      today. Confirm exactly what "does not disconnect the active amp"
      means in terms of daemon state: does the active amp get
      re-added to `KnownAmps` immediately (since it's still
      broadcasting), or does it stay disconnected-but-not-forgotten
      until its next broadcast is naturally re-ingested? Decide and
      implement the button's real confirm-click behavior (currently
      just a visual mock from Phase 4.4.1) to actually call the new
      method on the second click. Verify live: forget all amps with
      one connected and playing, confirm the connection is undisturbed
      (volume/mute/source controls keep working) while the amp list
      empties out and repopulates only as amps re-broadcast.
- [ ] **phase 4.5.4 — add Audio Devices noise when changing volum**

## Tasks to complete outside repo

- [ ] **Scroll-over-mpv-window volume control.** Separate MPV
      Lua script to redirect scroll events over active MPV windows to the 
      amp instead of MPV's own volume. Independent of the plasmoid itself 
      — not blocked on any of the phases above, can happen in parallel 
      whenever.
- [ ] **Add package to the AUR for easier install**
      Self-explanatory. The AUR (Arch User Repository) has packages
      uploaded by users of Arch / Arch-based distros (e.g. CachyOS).
      The devialet-expert-remote-widget would be nice to have uploaded
      there for easier install and sharing to other users.
