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

- [x] **Phase 5.0.0 — Daemon-owned pending-command state: VolumeDb/
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
  - **Implemented on `feature/daemon-pending-state` (not main).** Exactly
    the fields/methods/tests specified above - `pending_volume_db`/
    `pending_muted` on `TrackedAmp`, `resolve_pending_commands()` wired
    into `recompute()` alongside `resolve_boot_deadlines()`,
    `NotifyVolumeCommand`/`NotifyMuteCommand` mirroring
    `begin_power_on_boot`'s shape, `PENDING_COMMAND_TIMEOUT = 400ms`.
  - **Test coverage note:** the unknown-`ip` no-op guard on
    `notify_volume_command`/`notify_mute_command` themselves has no
    `cargo test` coverage, for the same reason `begin_power_on_boot`'s
    own already-booting/unknown-ip guard doesn't either - both are
    async zbus methods needing a live interface context this test
    module doesn't set up. Confirmed live instead (see below), matching
    that existing precedent exactly rather than inventing a new one.
  - **`cargo test --workspace`: 37 protocol + 39 daemon (9 new for this
    phase) = 76/76 passing. `cargo clippy --workspace --all-targets`:
    zero warnings.**
  - **Verified live, real amp (`192.168.0.22`), via `busctl call`/
    `busctl get-property` against the running daemon rebuilt from this
    branch** (state restored to -25.0dB/unmuted afterward, matching
    what was there before this verification pass):
    - Pending-then-expire, volume: `NotifyVolumeCommand … -33.0` (no
      real command sent) → `VolumeDb` read `-33` immediately, then
      `-25` (the real value) again after 600ms with no confirmation.
    - Pending-then-confirmed, volume: `NotifyVolumeCommand … -20.0`
      immediately followed by a real `devialet-ctl volume -20.0` →
      `VolumeDb` read `-20` immediately (pending) and still `-20` a
      full second later (now genuinely confirmed-real, not just an
      about-to-expire pending value that happened to match).
    - Pending-then-expire, mute: `NotifyMuteCommand … true` (no real
      mute sent) → `Muted` read `true` immediately, then `false` (the
      real value) again after 600ms.
    - Unknown ip: `NotifyVolumeCommand` against `10.99.99.99` returned
      successfully (exit 0, no D-Bus error) with zero effect on
      `VolumeDb`/`AmpIp` - confirmed no-op, not silently erroring or
      creating a phantom tracked amp.

- [x] **Phase 5.0.1 — Shared, root-anchored QML consumer for VolumeDb/
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
  - **Implemented on `feature/daemon-pending-state`.** New
    `plasmoid/contents/ui/PendingAmpState.qml` (plain `QtObject`, same
    "not `pragma Singleton`" precedent as `Theme.qml` - confirmed no
    qmldir exists in this KPackage). One correction from the original
    design sketch, caught during design review before implementing, not
    after: a bare `Dbus.Properties { ... }` child does not work directly
    under a `QtObject` root - `QtObject` has no `data` default property
    in Qt6 (that's an `Item`/`QQuickItem` thing, confirmed against this
    machine's actual installed `qmltypes`; the two existing bare-child
    precedents in this codebase, `CompactRepresentation`/
    `FullRepresentation`, are both `Item`-derived roots). Fixed by
    assigning it via a named property instead
    (`readonly property Dbus.Properties ampProps: Dbus.Properties
    {...}`), the same pattern `Theme.qml` already uses for its own
    `QObject`-derived `FontLoader` children under a `QtObject` root - no
    need to switch `PendingAmpState`'s root type to `Item`.
    `main.qml` instantiates it once (`PendingAmpState { id:
    pendingAmpState }`) and hands it to both representations via a new
    `required property PendingAmpState pendingAmpState` on each
    (`required property`, not an alias through `plasmoidItem` - matches
    the only existing precedent for this kind of handoff and fails
    loudly at load time if ever left unwired, worth more than saved
    boilerplate given this project has zero QML test infrastructure).
    `FullRepresentation` also gained `required property PlasmoidItem
    plasmoidItem` alongside it (no new import needed, `org.kde.plasma.
    plasmoid` already present) - unused by anything else this phase,
    added purely for consistency with `CompactRepresentation`'s existing
    wiring. Neither representation's existing `volumeDb`/`muted`
    handling, debounce timestamps, or `onPropertiesChanged` branches
    were touched - both files gained only the one new required-property
    line (two for `FullRepresentation`), confirmed via `git status`
    showing no other changes to either file.
  - **Verified live, real amp (`192.168.0.22`, real daemon rebuilt with
    Phase 5.0.0 already on this branch)**, via a temporary
    `debugLogging` flag on the new object (flipped back to `false`
    before finishing) logged through `journalctl _COMM=plasmashell`,
    plus the same synthetic-scroll tooling used for the Phase 4.5.0
    FullRepresentation-lag investigation:
    - **Panel icon only, flyout never opened**: exactly one
      `onRefreshed` fired at startup with the real values
      (`192.168.0.22 -42 false`, matching a direct `busctl
      get-property` check at the same moment); a real scroll produced
      an `onPropertiesChanged` with the updated confirmed value
      (`-42` → `-41`).
    - **Flyout opened** (both representations now loaded): **zero**
      log lines fired around the open event itself - no
      re-initialization, proving a single shared instance, not a
      second one spun up for `FullRepresentation`. A further scroll
      with the flyout open still updated correctly (`-41` → `-40`),
      confirmed visually too (flyout screenshotted mid-test, showing
      the matching `-41.0dB`).
    - **Flyout closed again**: a further scroll still updated
      correctly (`-40` → `-39`), proving `CompactRepresentation`'s
      reference keeps working completely unaffected by
      `FullRepresentation`'s unload.
    - Across the entire session (startup through open/close/multiple
      scrolls), **`onRefreshed` fired exactly once, total** - every
      subsequent update arrived via `onPropertiesChanged` on the same
      live subscription, the direct evidence for lifecycle
      independence this chunk exists to establish.
    - Amp volume restored to `-42.0dB` (its value before this
      verification pass) afterward; `cargo test --workspace` (76/76)
      and `cargo clippy --workspace --all-targets` (zero warnings)
      reconfirmed unaffected, since this chunk is QML-only.

- [x] **Phase 5.0.2 — Migration: cut over, then delete what's
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
  - **Step A implemented on `feature/daemon-pending-state`.** Both
    files gained a `notifyVolume()`/`notifyMute()` call immediately
    after their existing UDP dispatch, in every handler named above.
  - **One deliberate deviation from the literal "switch every display"
    instruction, found during design review before writing any code -
    a real regression risk, not a style choice:**
    `FullRepresentation`'s slider `Binding.value:` (and its paired dB
    label's `!== undefined` gate) were **kept on `root.volumeDb`**,
    not switched to `pendingAmpState.volumeDb`. On release,
    `root.volumeDb = volumeSlider.value` is set synchronously in the
    same tick the `Binding`'s `when: !volumeSlider.pressed` re-arms -
    today that re-application is a no-op. `pendingAmpState.volumeDb`
    only updates via `notifyVolume()`'s real (if fast) D-Bus round
    trip, so at that exact instant it still holds the pre-drag value -
    switching the Binding's source would have made the handle snap
    back to the stale position, then snap forward again once the round
    trip resolved. Every *other* switched binding in this phase
    degrades to "a bit more latency" (the intended, accepted
    trade-off, matching Phase 5.0.3's own "no perceptible lag"
    framing); this one alone would have degraded to a visible
    *reversal* instead, for zero benefit (`root.volumeDb` was already
    correct and synchronous for this file's own release). Cost of
    holding out is zero right now since `root.volumeDb =` stays alive
    regardless. Revisit in Step B once `root.volumeDb` itself is
    deleted - the likely real fix then is `PendingAmpState.
    notifyVolume()`/`notifyMute()` themselves writing an optimistic
    same-tick value before firing the async call, not something to
    design now. Comments explaining this holdout are left at both
    sites in `FullRepresentation.qml`.
  - **Switched to `pendingAmpState` (safe, no suppress/reactivate
    mechanic, single monotonic transition at worst):**
    `CompactRepresentation`'s `volumeFraction` (feeds both the tooltip
    and toast progress bars) and its `VolumeHoverTooltip`'s
    `volumeDb`/`muted` bindings; `FullRepresentation`'s 5 mute-button
    display bindings (background/border/icon/label text/label color).
    Accepted, not engineered around: `CompactRepresentation`'s toast
    progress-bar fraction can now show a brief catch-up transition
    (the toast's headline number is unaffected, fed the local
    `clamped`/`newMuted` value directly) - real but minor and cosmetic,
    not a functional bug.
  - **Untouched, correctly out of scope:** every `root.ampIp !== ""`
    gate in both files - `AmpIp` has no debounce/pending concept, it's
    a plain identity mirror, not part of the optimistic-command
    problem this phase addresses.
  - **Verified live, real amp (`192.168.0.22`)**, `busctl monitor`
    running throughout to confirm actual `NotifyVolumeCommand`/
    `NotifyMuteCommand` traffic (not just inferred from UI behavior),
    journalctl checked for `[WARN]` logs from either method the whole
    session (none appeared):
    - **The actual bug this phase exists to fix, confirmed working**:
      with the flyout open, middle-clicked the panel icon to mute -
      the flyout's Mute button flipped to "Unmute" (copper highlight)
      within the ~0.3s measurement window, a real `NotifyMuteCommand`
      call confirmed in the `busctl monitor` log at the same moment.
      Un-muted the same way, confirmed clean.
    - **The specific risk this plan was built around**: dragged the
      flyout's volume slider for real (synthetic press-move-release,
      calibrated cursor position via `workspace.cursorPos`) from
      -25.0dB to the floor (-60.0dB, drag exceeded track width and
      correctly clamped). Screenshotted after release: number, handle
      position, and fill all consistent and correct, matching the
      held-out binding's expected behavior (no async dependency at the
      moment of release, so no reversal is structurally possible here,
      not just "didn't happen to observe one"). A real
      `NotifyVolumeCommand` call confirmed in the `busctl monitor` log
      for this release.
    - **Reverse direction (Full → Compact)**: after the slider drag
      above, closed the flyout and hovered the panel icon - the
      tooltip correctly showed the dragged value (-60.0dB), confirming
      `pendingAmpState` is the shared, consistent source in both
      directions, not just Compact → Full.
    - Amp restored to -25.0dB/unmuted afterward, matching its state
      before this verification pass. `cargo test --workspace` (76/76)
      and `cargo clippy --workspace --all-targets` (zero warnings)
      reconfirmed unaffected, since this step is QML-only.
  - **Step B: scope corrected during investigation, before writing any
    code - a real regression risk in the originally-stated scope, not
    just a style choice.** `root.volumeDb`/`root.muted` in both files
    turned out to serve two separate jobs, only one of which Step A
    addressed: display (already redirected to `pendingAmpState`) and
    each mutator's own rapid-repeat *accumulation base*
    (`stepVolume()`'s `base = root.volumeDb ...`, the mute handlers'
    `newMuted = !root.muted`), which depends on that value being set
    **synchronously** so a fast second click/drag reads the value just
    set, not something stale. `PendingAmpState.notifyVolume()`/
    `notifyMute()` had no synchronous write of their own (confirmed by
    reading the actual file) - so deleting the local optimistic writes
    as literally scoped would have broken rapid-repeat correctness
    (three quick `+1dB` clicks netting +1dB instead of +3dB; two fast
    mute clicks both sending "mute on"), reproducing the exact
    known-gotchas.md bug #1 class from local-IPC latency instead of
    amp-broadcast latency. Confirmed by an independent review pass, not
    just one read.
    - **Prerequisite added, one file beyond the original two-file
      scope**: `PendingAmpState.qml`'s `notifyVolume()`/`notifyMute()`
      now write `root.volumeDb`/`root.muted` synchronously before
      firing the async D-Bus call - exactly the fix `FullRepresentation`'s
      own Step A holdout comment had already named as the eventual
      answer, just not yet built. Also added a failure-path rollback
      (capture the prior value, restore it if the call errors or
      fails) - examined as a real, if narrow, gap (a failed call used
      to leave the UI merely stale; with a synchronous write and no
      rollback it would instead assert an unconfirmed value
      indefinitely) and fixed since the cost was a few lines. Verified
      safe against the actual KDE source
      (`plasma-workspace/components/dbus/dbusconnection.cpp`): the
      `resolve`/`reject` callbacks are `Qt::SingleShotConnection`-guarded
      and mutually exclusive, so they fire at most once combined -
      no double-restore, no race with a late success. Also confirmed
      (by reading the whole file) no feedback loop: nothing in
      `PendingAmpState.qml` reacts to `volumeDb`/`muted` changing, so
      the real-confirmation path can never re-trigger a notify call.
    - **`CompactRepresentation.qml` - full cleanup, safe with the
      prerequisite**: `stepVolume()`/`toggleMute()` now read
      `pendingAmpState.volumeDb`/`.muted` as their accumulation base;
      the local `root.volumeDb =`/`root.muted =` writes,
      `lastIconStepAtMs`, `lastMuteChangeAtMs`, `debounceMs`, `now()`,
      `within()` are all deleted (the last three were fully orphaned
      once the fields were gone). Went one step further than the
      literal wording: the `root.volumeDb`/`root.muted` *properties*
      themselves and their `onRefreshed`/`onPropertiesChanged`
      mirror-writes are also removed, since nothing read them for
      anything anymore - leaving two fully-unread properties behind
      would itself have been redundant code.
    - **`FullRepresentation.qml` - narrower than originally scoped,
      deliberately**: only `lastMuteChangeAtMs` (field, the `onClicked`
      write, and its `onPropertiesChanged` guard) is deleted, collapsing
      that branch to an unconditional one-liner. `root.muted = newMuted`
      itself stays - no display depends on it anymore, but it still
      protects a rapid double-click's own read-before-write, and a
      synchronous write costs nothing to keep. **`lastVolumeButtonStepAtMs`,
      `lastVolumeSliderReleaseAtMs`, and `volumeInteracting` are
      explicitly NOT deleted**, contradicting the phase's original
      scope for this file - confirmed by two independent passes that
      all three protect `root.volumeDb`'s role as the display source
      for the slider Step A deliberately held out; `stepVolume()` still
      writes `root.volumeDb = clamped` (unchanged, still needed for the
      slider to move instantly on a button click), and removing their
      guards would let a stale/out-of-order update visibly perturb that
      held-out display - the exact thing the holdout exists to prevent.
      Follow-up, not this step's job: lifting the slider holdout itself
      (now that the prerequisite exists) is a separate future decision.
    - **Verified live, real amp (`192.168.0.22`)**:
      - **Rapid-repeat stress test (the specific regression this
        correction prevents)**: 5 scroll notches at 10ms spacing (far
        faster than any D-Bus round trip) via the panel icon -
        VolumeDb moved the full +5dB (`-25` → `-20`), not a partial
        amount.
      - **Rapid mute double-click**: two middle-clicks ~20ms apart -
        ended back at `Muted = false`, not stuck "on" from two
        "mute on" commands landing back to back.
      - **Cross-representation consistency re-confirmed**: with the
        flyout open, middle-clicked the panel icon - the flyout's Mute
        button updated promptly; volume number displayed correctly
        (`-20.0dB`, matching the stress test above).
      - **Held-out slider path re-confirmed unaffected**: dragged the
        flyout's slider to the ceiling (`-15.0dB`) - number, handle,
        and fill all correct and consistent, no glitch.
      - Amp restored to `-25.0dB`/unmuted afterward. `cargo test
        --workspace` (76/76) and `cargo clippy --workspace --all-targets`
        (zero warnings) reconfirmed unaffected.

- [x] **Phase 5.0.3 — Live verification across every consumer.**
      Depends on 5.0.2. Real amp (`192.168.0.22`, starting state
      `-25.0dB`/unmuted, restored to that afterward). All interactions
      performed via real synthetic input (a hand-built evdev virtual
      mouse, calibrated against `workspace.cursorPos` via a KWin
      script - not simulated/assumed), correlated against a live
      `busctl --user monitor com.ekmanch.DevialetRemote` capture (each
      D-Bus message carries its own microsecond-precision internal
      `Timestamp=`, used for all latency figures below - not wall-clock
      guesses). Each item's own evidence type is called out explicitly,
      per instruction, rather than blended into one "confirmed":
  1. **Scroll panel icon, flyout open - flyout slider vs. OSD toast
     timing.** Real synthetic scroll events on the panel icon
     (`vhelper.scroll()`), flyout open throughout. D-Bus evidence: two
     separate `NotifyVolumeCommand` calls measured, daemon-side
     call-to-`PropertiesChanged`-emission delta = **255µs** and
     **165µs** respectively (i.e. sub-millisecond, effectively
     instantaneous on the daemon side). Code-level evidence: the OSD
     toast (`CompactRepresentation`) is driven by
     `stepVolume()`'s own synchronous write into
     `pendingAmpState.volumeDb` (via `notifyVolume()`'s Step B
     optimistic write, landing *before* the async D-Bus call even
     fires) - zero added latency by construction, confirmed by reading
     the code, not inferred. The flyout's own slider *display* (the
     Step A holdout - see 5.0.2) instead depends on its own
     `onPropertiesChanged` round trip, bounded by the same
     sub-millisecond daemon delta above plus local D-Bus delivery/QML
     dispatch (not independently measurable without instrumenting the
     QML engine - flagged as a boundary of this evidence, not rounded
     up). Screenshot-based visual confirmation (taken ~0.6s after the
     interaction, well past any such gap): flyout slider and OSD toast
     both showed `-22.0dB`, consistent. **Result: no perceptible lag,
     confirmed structurally (toast is synchronous-by-construction) and
     via sub-ms daemon timestamps; frame-exact QML repaint timing was
     not separately measured (see boundary note above).**
  2. **Middle-click mute/unmute, flyout open.** Real synthetic
     middle-click (`vhelper.click("middle")`) on the panel icon. D-Bus
     evidence: `NotifyMuteCommand` call → `PropertiesChanged` (Muted)
     emission delta = **165µs**. Screenshot-based visual confirmation
     (~0.4s after the click, single screenshot): flyout's Mute button
     showed the active/"Unmute" state and the OSD toast showed
     "Muted" simultaneously, both consistent. **Result: no perceptible
     lag, same evidence profile as item 1.**
  3. **Reverse direction (Full→Compact): flyout's own Mute button, does
     the tooltip pick it up?** First established that the OSD *toast*
     is intentionally a local-interaction cue only (its
     `volumeToast.showVolume()`/`showMute()` calls live inside
     `CompactRepresentation`'s own `stepVolume()`/`toggleMute()`, not a
     generic watcher on `pendingAmpState`) - confirmed by reading the
     code, not a bug, so the toast was not expected to fire for a
     flyout-originated change and didn't. The correct passive-mirror
     target is the **hover tooltip**
     (`VolumeHoverTooltip.volumeDb`/`.muted`), confirmed by grep to be
     a direct, unconditional binding to `root.pendingAmpState.volumeDb`/
     `.muted` with no local caching. Real synthetic click on the
     flyout's own Mute button (`vhelper.click("left")` at its screen
     position) toggled `Muted` to `true` (confirmed via `busctl
     get-property` ground truth). Closed the flyout, hovered the panel
     icon, and captured a **screenshot showing the tooltip itself**
     reading `Optical 1 ... Muted` (copper-highlighted) - a real,
     legible, correctly-positioned render, not just a ground-truth
     inference. **Result: confirmed symmetric (Full→Compact), via a
     real screenshot of the tooltip's actual rendered content.** (See
     the tooltip-positioning side-finding below - most attempts to
     render the tooltip this session came out almost entirely clipped
     off the right edge of the screen; one specific trigger pattern
     - hovering while a scroll event fires - consistently rendered it
     correctly, and was used for this and item 6's evidence. Flagged
     as a new, separately-tracked issue, not fixed here.)
  4. **Real drag of the flyout's own volume slider, plus mid-drag
     external-change injection.** Real synthetic press-move-release
     (`vhelper.press()`/`move_rel()` in small steps/`release()`, not a
     single jump) on the slider handle. First pass (idle ~0.3s between
     establishing the drag and injecting an external
     `NotifyVolumeCommand -50` via `busctl call` mid-press) showed a
     **concerning transient**: the slider visually snapped to the
     injected value while still pressed. Investigated rather than
     reported at face value, per instruction to flag ambiguity: a
     second pass using the *same* idle-hold pattern (press, establish,
     then ~0.3s with no further move events) reproduced an unrelated
     symptom too - the flyout popup itself spontaneously closed mid-
     hold - which has no plausible connection to this file's own
     `volumeInteracting` guard logic. A third pass bracketing the
     injection with continuous small move events (matching how a real
     held mouse button actually behaves - never perfectly idle) showed
     **no perturbation**: slider stayed at the live drag value
     (`-34.0dB`) through the injected `-55` call. **Conclusion: the
     idle-hold anomaly is attributed to this session's synthetic-input
     grab going unstable under a prolonged idle press (corroborated by
     the unrelated popup-close symptom under the identical idle
     pattern), not a `volumeInteracting`-guard failure - confirmed via
     the continuous-motion retest, which is the realistic simulation of
     a real held mouse button.** Note also: `TODO.md`'s original item 4
     wording ("now that `volumeInteracting`'s guard is gone") is stale
     against what 5.0.2 Step B actually shipped - Step B's own
     investigation reversed that plan and deliberately *kept*
     `volumeInteracting`/`lastVolumeButtonStepAtMs`/
     `lastVolumeSliderReleaseAtMs` (see that entry above); this item
     was evaluated against the guard's actual continued presence, not
     the stale premise. **Released value sticks correctly**, confirmed
     twice: released at a genuine drag position both times
     (`-29.0dB`, then `-34.0dB`), and `busctl get-property` ground
     truth matched exactly both times, unaffected by the mid-drag
     external injection. **Result: no regression found in the guard
     itself; a real but separately-explained synthetic-input artifact
     was found and ruled out, not glossed over.**
  5. **Rapid multi-step scroll settles on the last value.** Six real
     synthetic scroll notches fired back-to-back
     (`vhelper.scroll(1)` × 6, no artificial delay between calls). Six
     `NotifyVolumeCommand` calls captured on the bus, strictly
     sequential and monotonic: `-33, -32, -31, -30, -29, -28`, the last
     two only **11 microseconds** apart. Final `busctl get-property`
     ground truth: `-28` (the last value sent, not a superseded
     intermediate), matching a screenshot of the tooltip showing
     `-28.0dB` at the same time. **Result: confirmed via real
     sequential D-Bus timestamps plus ground-truth + screenshot
     agreement - no dropped or reordered steps, no stale settle.**
  6. **"Hover tooltip defaults to Muted on initial load" - side
     observation only, not marked fixed.** Did **not** perform a fresh
     `plasmashell --replace` reload for this check - the daemon has
     been running continuously all session (no restart), so there was
     no genuine "initial load" moment to observe live, and forcing one
     purely for a side-observation-only item felt disproportionate
     (a full shell restart, versus every other item's non-disruptive
     mouse/click interactions). Instead: **code-level structural
     evidence only**, explicitly not a live reproduction attempt.
     `PendingAmpState.qml` declares `property bool muted: false`
     (sensible default), and both `onRefreshed`/`onPropertiesChanged`
     only ever assign it from real D-Bus data via `unwrap(..., false)`
     - no code path sets it speculatively to `true`. Because there is
     now exactly one shared `PendingAmpState` instance (Phase 5.0.1),
     the original suspected mechanism - two independently-initialized
     local `muted` mirrors racing each other - is structurally no
     longer possible; there is only one initialization to race against
     itself. **This is exactly the "plausible structural prevention,
     not a confirmed fix" the phase's own wording anticipated - stated
     here as such, not upgraded to "fixed."** The bug entry (see Bugs
     below) is left open.
  - **Minor incidental finding, not one of the six items, not fixed
    here**: `NotifyVolumeCommand`/`NotifyMuteCommand` do not themselves
    clamp to the `-15dB` safety ceiling - confirmed by directly
    `busctl call`-ing `NotifyVolumeCommand` with `-12` (above the
    ceiling) during item 4's injection testing, which was accepted and
    briefly reflected in `VolumeDb` before its 400ms pending window
    expired and it fell back to the amp's real last-known value. In
    normal operation this is unreachable (every QML caller already
    clamps via `volumeCeilingDb`/`volumeFloorDb` before calling
    `notifyVolume()`), so this is a defense-in-depth gap at the D-Bus
    entry point, not a reachable bug via the UI - noted for awareness,
    not treated as a regression from this phase.
  - **New side-finding, not fixed here, worth its own follow-up**: the
    hover tooltip (`VolumeHoverTooltip`'s `PlasmaCore.Dialog`) rendered
    almost entirely clipped off the right edge of the screen for most
    trigger paths tried this session (plain hover-and-wait, both before
    and after a flyout close), despite its own code comments claiming
    Plasma's default `location`-based positioning centers it on
    `visualParent`. Confirmed genuinely our tooltip, not an unrelated
    overlay (it reliably appeared/disappeared in sync with hover
    enter/exit). Root cause not investigated - `VolumeHoverTooltip.qml`'s
    positioning code was not touched by any of Phase 5.0.0-5.0.2, so
    this is very likely pre-existing and environment/session-specific
    (this display: 1920×1080 logical @ 2x scale, icon sitting far right
    in the panel), not a regression from this phase. One specific
    pattern (a scroll event firing while already hovering) consistently
    rendered it correctly and was relied on for items 3 and 6's
    screenshots; plain hover-and-wait clipped almost every other time.
    Worth its own investigation as a separate ticket, not chased
    further here.
  - **Bug closure**: items 1, 2, 3, and 5 confirmed clean with no
    caveats; item 4 confirmed clean after distinguishing a real
    synthetic-input testing artifact from an actual guard failure
    (see above - the guard itself was never shown to fail under
    realistic continuous-motion conditions). On that basis, the
    "FullRepresentation lags behind CompactRepresentation" bug (see
    Bugs section) is marked fixed below - **pending the user's own
    final live confirmation before merge**, per instruction; treat it
    as provisionally closed, not unconditionally closed, until that
    pass happens.
    
- [x] **Bug: FullRepresentation lags behind CompactRepresentation on
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
    **Phase 5.0.0-5.0.1 (Done) and 5.0.2-5.0.3 (Up next)** for the
    scoped fix (daemon-owned pending-command state, consumed by both
    representations via one new shared object) - daemon side (5.0.0)
    and the shared QML consumer object (5.0.1) both landed and
    live-verified, but neither representation actually reads from that
    object yet (that's 5.0.2's cutover), dedicated branch. Do not close
    this bug until 5.0.3's live verification confirms it end to end.
  - **Closed by Phase 5.0.3's live verification** (see that entry
    above, items 1/2/5 in particular): real synthetic scroll/
    middle-click interactions plus real D-Bus timestamps showed the
    daemon-side round trip is sub-millisecond
    (165-255µs measured), and `FullRepresentation`'s own display now
    reads from the same daemon-confirmed pending state
    `CompactRepresentation`'s optimistic echo used to leave it waiting
    on - no more waiting on the amp's own ~60-200ms broadcast cadence.
    **Marked closed provisionally - pending the user's own final live
    confirmation before merge**, per Phase 5.0.3's explicit instruction
    not to present this as unconditionally closed until that pass
    happens.
  - Distinct from the existing parked bug above ("widget doesn't
    reflect amp-initiated volume changes it didn't itself send") - that
    one describes a divergence that persists indefinitely until
    touched; this one is a delay that does eventually resolve on its
    own. Confirmed genuinely distinct, not the same root cause - the
    live investigation above is fully explained by amp-broadcast
    latency plus asymmetric optimism, with no connection found to the
    amp-initiated-change bug's mechanism.
    
    
- [x] **Bug: hover tooltip defaults to "Muted" on initial load, even
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
  - **Side observation from Phase 5.0.3 (not a fix, not a live
    reproduction attempt)**: `PendingAmpState.qml`'s `muted` property
    now defaults to `false` and is only ever assigned from real D-Bus
    data (`unwrap(..., false)`), and there is exactly one shared
    instance of it (Phase 5.0.1) instead of two independently-
    initialized local mirrors racing each other - the specific race
    class this bug was suspected to be. This is a plausible structural
    prevention for that whole bug *class*, not a confirmed fix for
    this specific ticket (no fresh-reload live reproduction was
    attempted - see Phase 5.0.3 item 6). Left open.
  - **Not able to reproduce when trying to provoke it 2026-09-01**

- [x] **Phase 7.0.0 — AppletPopup infrastructure spike.** On
      `spike/flyout-appletpopup-rebuild`: replaced just the
      compact→full transition with a bare `PlasmaCore.AppletPopup`
      holding empty/placeholder content — no real flyout UI — to test
      whether dismiss-on-click-outside, focus handling
      (`requestActivate()`), and screen-edge-aware positioning
      actually behave acceptably on this system before committing to
      rebuilding `FullRepresentation.qml` on top of it. Specifically
      resolved whether the known
      `QWindow::setWindowState does not accept Qt::WindowActive`
      warning (present even in KDE's own `CompactApplet.qml`) is
      cosmetic-only here or actually breaks keyboard focus into
      flyout controls.
  - Basis: `context-on-spike-flyout-dialog-rebuild-b-quirky-wand.md`
    investigation document (§6, "Go/no-go recommendation," step 2 of
    the recommended path; full results now also in that document's own
    new §7). `VolumeToast.qml`'s live `AlignBaseline` hazard (the
    doc's finding 9, step 1 of the same recommended path) was fixed
    first, as of commit `d2a9c49`.
  - New `AppletPopupSpike.qml`, gated behind `main.qml`'s
    `appletPopupSpikeEnabled` flag (default `false`) —
    `CompactRepresentation.qml`'s left-click handler only opens it
    instead of the real flyout when the flag is true. No
    `FullRepresentation.qml` content was ported in and no changes were
    made to that file. Every dismiss/positioning/focus binding was
    copied deliberately from the real installed `CompactApplet.qml`
    (`/usr/share/plasma/shells/org.kde.plasma.desktop/contents/
    applet/CompactApplet.qml`) and the real `appletpopup.h`/`.cpp`/
    `popupplasmawindow.h` headers, re-confirmed against the real
    source this session rather than trusted from memory of §3's
    summary.
  - **Bug found and fixed before any live testing was possible**: the
    spike auto-opened ~5s after `plasmashell` startup with no click
    made. `Window`-derived types (which `PlasmaCore.AppletPopup` is)
    default to `visible: true` in QML; `CompactApplet.qml` overrides
    this with an explicit binding, and this file initially had no
    equivalent explicit initial value. Fixed with a plain
    `visible: false` initial-value assignment. Re-verified clean after
    the fix across three separate reloads, zero auto-opens.
  - **Verified live, real desktop (Plasma 6.7.4, Wayland/KWin)** — no
    mouse/keyboard automation tool exists in this Wayland session (no
    `xdotool`/`ydotool`/`wtype`), so the project owner performed the
    physical clicking/typing directly while journald was tailed live
    for correlation, not simulated or assumed:
    - Opens and positions correctly even at the hardest real edge case
      available on this system (panel icon sitting in the screen's
      literal top-right corner) — no clipping, confirmed via two
      separate screenshots.
    - Dismiss-on-click-outside: confirmed explicitly (left-clicking
      empty desktop wallpaper closed it).
    - Escape key dismiss: confirmed explicitly.
    - Keyboard focus reaches a real interactive control: confirmed
      both visually (typed text appeared verbatim in a TextField, live
      "has active focus" indicator lit) and via the `mainItem` →
      `focusTestField` relay sequence in journald, matching
      `CompactApplet.qml`'s own focus-relay mechanism exactly.
    - The `QWindow::setWindowState does not accept Qt::WindowActive`
      warning **did not appear once** across 11 separate open/
      `requestActivate()` cycles over ~5 minutes of real interaction
      (checked in journald filtered to the `plasmashell` process and
      in its raw redirected stdout/stderr — both empty for this
      string).
    - Not tested this session: repositioning while the popup stays
      open across a live panel move or monitor change. Carried forward
      explicitly into Phase 7.1.0's verify list below, not silently
      dropped just because everything else passed.
  - **Conclusion**: every risk §6 flagged as the actual open question
    for this spike came back clean under live verification — the green
    light to proceed with the real rebuild, per the investigation's own
    recommended path. This is **not** evidence that the layout-hazard
    risk from §1/§4 is resolved — that was never exercised by an
    empty-content spike and only gets tested once real content exists
    (Phase 7.3.0 onward). Flag left at `false` (off) on completion; the
    real, shell-managed flyout was left completely untouched and fully
    functional throughout.
  - **Correction, added after Phase 7.8.0's cutover**: this "green
    light" assessment — and the investigation document's own §6
    recommendation to use `PlasmaCore.AppletPopup` "not the older
    Dialog" — never checked the choice against the rebuild's own stated
    goal. The investigation document's own Context section states the
    goal explicitly: rebuilding as a custom `PlasmaCore.Dialog` "would
    open up real background/transparency control on the flyout, the
    same way it already did for `VolumeToast.qml` and
    `VolumeHoverTooltip.qml`." §6 instead recommended `AppletPopup`
    specifically because "it's the exact class already producing
    today's flyout" — without noticing that being the exact class
    already producing today's flyout is exactly *why* today's flyout
    has no transparency: `PlasmaWindow`'s `BackgroundHints` enum
    (confirmed in `plasmawindow.h`, and already documented
    independently in CLAUDE.md's own "real transparency investigated"
    note) has no `NoBackground` value at all. Phases 7.0.0-7.8.0 are
    functionally solid and thoroughly verified (see each phase's own
    entry) but do not achieve real transparency — caught by the project
    owner comparing a live screenshot against the tooltip/OSD's
    already-transparent look, after 7.8.0's cutover. See Phase 7.9.0+
    below for the fix.

- [x] **Phase 7.1.0 — Promote the spike into the real flyout popup
      shell.** Depends on 7.0.0. Still infrastructure-only — no real
      amp/volume/source content, still gated behind `main.qml`'s
      `appletPopupSpikeEnabled` flag (default `false`), not yet the
      real cutover path. Basis: investigation document §7 (spike
      results) and §3 (API surface), re-confirmed directly against
      `appletpopup.h`/`popupplasmawindow.h` and `CompactApplet.qml`
      again this phase.
  - `AppletPopupSpike.qml` renamed/evolved into `FlyoutPopup.qml`
    (old file removed). Every dismiss/positioning/focus binding
    carried over unchanged from the proven 7.0.0 spike, not
    re-derived. `CompactRepresentation.qml` and `main.qml`'s comments
    updated to reference the new name; the toggle flag itself keeps
    its existing name.
  - Two real-build deltas applied, both confirmed against real
    headers before implementing (not assumed from the 7.0.0 summary):
    - `appletInterface: flyoutPopup.plasmoidItem` — `PlasmoidItem`
      IS-A `AppletQuickItem` (`appletpopup.h`'s internal
      `QPointer<AppletQuickItem>`), the exact same binding
      `CompactApplet.qml`'s own `dialog` uses. A new required
      `plasmoidItem` property was added to `FlyoutPopup.qml` and wired
      from `CompactRepresentation.qml` to carry this through.
    - `hideOnWindowDeactivate: flyoutPopup.plasmoidItem.
      hideOnWindowDeactivate`, replacing the spike's hardcoded `true`.
  - Content stayed the spike's own placeholder Label/TextField/Close
    button, unchanged, per this phase's own scope.
  - **Verified live, real desktop (Plasma 6.7.4, Wayland/KWin)**,
    project owner performing all physical interaction (no input
    automation available in this Wayland session), journald tailed
    live for correlation:
    - Open/position, click-outside dismiss, Escape dismiss, and the
      `mainItem` → `focusTestField` focus-relay sequence all
      re-confirmed clean with `appletInterface` now set — zero
      regressions from 7.0.0, zero
      `QWindow::setWindowState does not accept Qt::WindowActive`
      occurrences across all open/close cycles.
    - Size persistence (the actual point of setting
      `appletInterface`): resized the popup, closed it, reopened it —
      same size restored. Confirmed working.
    - **Carried-forward item from 7.0.0, now closed**: literally
      dragging the panel to a different edge while the popup stays
      open isn't achievable on this system (panel-edit drag mode and
      an open popup don't coexist, and there's no second monitor to
      test a screen change with instead). Verified the practical
      equivalent instead — a second instance of the widget was added
      to a left-edge panel and the flyout opened there — confirming
      `popupDirection`'s `Plasmoid.location` switch correctly
      reorients (`LeftEdge → Qt.RightEdge`) rather than rendering
      off-screen or misaligned. Accepted as closing this item; a live
      mid-open panel/monitor change specifically remains untestable on
      this hardware, not silently dropped.
  - **Real bug found live, not anticipated by this phase's own task
    description**: `PlasmaCore.AppletPopup` is user-resizable by
    click-and-drag as a built-in feature of the class itself
    (`appletpopup.h`'s own doc comment — confirmed by reading it, not
    assumed), with no QML property to disable it. This is not new
    behavior introduced by this rebuild — the *existing*, already-
    shipped flyout has always been wrapped in this exact class by the
    shell (`CompactApplet.qml`'s `dialog`), so it has always been
    draggable this way; nobody had tried before. Because
    `FlyoutPopup` and the real shell-managed `dialog` both bind
    `appletInterface` to the same `plasmoidItem` while they coexist
    behind the toggle (true until Phase 7.8.0's cutover), they persist
    size into the *same* KConfig group
    (`[Containments][46][Applets][128][Configuration]`, keys
    `popupWidth`/`popupHeight`) — so resize-testing `FlyoutPopup`
    directly corrupted the real, live flyout's rendered size twice
    during this session's verification. Both times fixed with
    `kwriteconfig6 --delete` on the two keys + `plasmashell --replace`,
    confirmed restored to normal size after each fix. **Phase 7.2.0
    correction: not just resize-testing** - `AppletPopup::hideEvent()`
    writes the keys on every close (see 7.2.0's entry), so any open/close
    of `FlyoutPopup` re-corrupts the real flyout's size; the harness now
    restores the keys itself, manual spike testing still needs the
    `kwriteconfig6` cleanup.
  - **Protection against this decided, not implemented yet**: rather
    than a "reset to default size on close" mechanic, chose size-
    pinning `mainItem`'s min/max Layout size hints to its final
    preferred size once that size is known and verified stable —
    recorded as a new explicit requirement in Phase 7.7.0's entry
    below, since it needs the fully-assembled, verified-stable final
    content size that phase's own pass establishes. Until 7.7.0 lands,
    any future resize-testing against `FlyoutPopup` while both popups
    still coexist must be followed by the same `kwriteconfig6`
    cleanup — this hazard doesn't go away on its own before cutover.
  - Flag reverted to `false` (off) on completion; the real, shell-
    managed flyout confirmed fully functional and back to its normal
    size throughout, with no lingering KConfig corruption.

- [x] **Phase 7.2.0 — §5 verification harness.** Depends on 7.1.0.
      Built the tooling §5 describes before any real content exists;
      every content phase from 7.3.0 onward gates on it. Verified against
      7.1.0's placeholder popup only - "verified" here means the tooling
      runs and produces stable output across repeated runs of the same
      states, not that any flyout content is bug-free. No commits (per
      CLAUDE.md); flag reverted to `false` on completion.
  - **Design (approved in plan review, all four review questions
    answered in the plan itself)**: state is driven over D-Bus, no
    synthetic input anywhere. `tools/flyout-harness/fakeamp.py`
    impersonates the daemon on its real bus name (`Amp1`, all 13
    properties with exact signatures, 4 methods as logged no-ops,
    `PropertiesChanged` one property per signal in `emit_all()`'s order)
    and owns a second control name (`…DevialetRemote.Harness` / `Harness1`:
    `PopupOpen`, `UiState`, `StateId`, `Seq`, `SettleMs`). New
    `plasmoid/contents/ui/LayoutProbe.qml` (instantiated once inside
    `FlyoutPopup.qml`'s `mainItem` - the only change to that file,
    placeholder content untouched) sets `popup.visible` from `PopupOpen`
    (the click handler's own statement), assigns `UiState` keys onto a
    `uiTarget` (QML-internal state such as `ampListOpen`), and on each
    `Seq` bump waits `SettleMs` then logs every Item under `mainItem` as
    one JSON line via `console.log` → journald (`[FlyoutProbe]` prefix,
    Phase 5.0.3's path): key (`objectName`, else structural path),
    class, x/y/w/h, `mapToItem(null)` and `mapToGlobal` points, implicit
    size, visibility, `text`/`font.pixelSize` when present; nested
    `mainItem` windows (7.3.0's planned overlay) recursed with their own
    window record. `harness.py run` stops the systemd daemon unit if
    active, owns the names with `DO_NOT_QUEUE` (zbus 5.19's builder was
    read: the daemon also uses `DO_NOT_QUEUE`, no replacement flags, so
    neither side can ever take the name from the other), drives each
    state, asserts the probe's own `Amp1` snapshot matches what it set
    ("state never reached the widget" is a hard error), screenshots with
    `spectacle -b -n -f`, crops, and restores the daemon in a `finally`
    block. `scenarios.py` derives every state from `recompute()`'s two
    branches: amp ∈ {0known, 1auto-short, 1auto-long, 1none, 2none,
    2sel-short, 2sel-long} × vol {-40.0, -15.0, 0.0} × mute × pow {Off,
    Booting, On} × src {short, 16-char long, none} × list {closed, open};
    not-connected amp values collapse the inner dims to `-`. Full set =
    438 states / 2409 single-dimension pairs; named subsets (`smoke`,
    `amp`, `volume-mute`, `power`, `source`) plus `--vary`/`--fix`.
    `analyze.py` writes `report.md`/`summary.json`: control identity,
    popup geometry table (§1 master finding at a glance), element moves
    on single-dimension flips grouped by element with Δx/Δy/Δw/Δh and
    text before/after (optional `expected.json` allowlist), exact pixel
    diffs with bbox/row bands/diff images, `--noise-mask` self-noise
    exclusion. `harness.py compare a b` diffs two runs' coordinates
    (run-to-run stability and the per-phase settle-floor check).
    `runs/` is gitignored. Full usage + house rules in the README.
  - **Probe footprint, stated plainly (review question 2)**: the only
    always-on cost is one `DBusServiceWatcher` match rule for a name that
    never appears in normal use; everything else sits behind an inactive
    `Loader`. Confirmed live: zero `[FlyoutProbe]` journal lines across
    three plasmashell restarts with the harness not running (after moving
    the lifecycle log from the Loader's `active` signal - which fires
    once at construction as the default `true` yields to the binding -
    into the loaded item's own `Component.onCompleted/onDestruction`).
    Safe to ship permanently; nothing to strip before 7.8.0.
  - **Three real bugs found by the harness's own first runs, none in
    the flyout:**
    - `spectacle -b -f` from the tool shell wrote a fully transparent
      3840×2160 PNG with exit code 0 - every crop was blank and every
      pixel diff trivially zero. Root cause: from a non-interactive shell
      spectacle picked the xcb backend, and an XWayland grab of a Wayland
      session is empty. Fix: `QT_QPA_PLATFORM=wayland` forced for every
      capture, plus a hard error on an all-transparent image so it can
      never pass silently again. Recorded in CLAUDE.md's Environment.
    - `UiState` as an `a{ss}` dict reached QML as an opaque
      `QDBusArgument` - `Object.keys()` empty, nothing applied, zero
      warnings (the same marshalling gap test-scaffold/watch.qml documents
      for `Sources`, now confirmed for dicts too). Switched to a JSON
      string property; the probe now also logs `uiApplied` per key and
      the expected "UiState key not on uiTarget: ampListOpen" warning
      appears for the placeholder, which has no such property yet.
      Recorded in CLAUDE.md.
    - Crop noise: with an 8 px pad the control pair differed by ~8k
      pixels - all in the pad, where the desktop behind the popup (the
      terminal scrolling the run's own log) shows; with pad 0 still ~150
      px along the bottom rows and corners, where the theme frame's
      antialiased rounded edges let the desktop bleed through. Crop is
      now the `mainItem` rectangle (window position + root item offset,
      × dpr), which excludes the frame - the frame never changes with
      state, so nothing the harness is for is lost.
  - **Verified live (real desktop, Plasma 6.7.4, Wayland/KWin, 2x
    scale), flag on, real daemon stopped/restored by the harness itself
    every run:**
    - Bus-name refusal: `fakeamp.py` standalone with the real daemon
      running exits 3 with "already owned by :1.4 - stop the real daemon
      first". Under temporary names, `busctl introspect` showed all 13
      properties with the daemon's exact signatures, methods accepted,
      19 per-property `PropertiesChanged` signals on the wire.
    - `states --set full`: 438 states, 2409 pairs; the six not-connected
      states carry `-` for vol/mute/pow/src, nothing else does.
    - Four `--set smoke` runs (7 states + control) plus one at
      `--settle-ms 1200` and one `--set amp` (14 states): every run exit 0,
      13 items per state, popup 340×195 / mainItem 324×180 in every
      state, `compare` reports **identical coordinates** run-to-run
      (including across plasmashell restarts) and between settle 600 and
      1200 ms - the settle-floor mechanism works (trivially, for fixed
      content). Single-dimension-flip tables empty in every run, as they
      must be for state-independent placeholder content. Probe item
      count always equalled parsed lines (no journald drops).
    - Control capture after the crop fix: **63 differing pixels in a
      2×32 box** - exactly the placeholder TextField's blinking caret,
      nothing else; every pair diff 0 once that noise mask applies, and
      every non-masked pair in the amp set showed the same 63 px in the
      same box. This is the caveat §5's control capture exists to
      surface: content phases with animated states (Booting pulse/
      spinner) should expect a small, attributable control diff and use
      `--noise-mask`.
    - Timing: 1.7 s per state at 600 ms settle (0.3 s spectacle, 0.6 s
      settle, the rest D-Bus/journal/crop) → the 438-state full gate
      is ~13 min, ~26 min with `--noise-mask`.
    - Ctrl-C mid-run (`--set amp`, interrupted at state 3): names
      released, daemon unit restarted and owning its name again within
      1 s, `KnownAmps` = the real amp only. The persisted-selection file
      was never touched.
  - **Correction, found by you right after the first completion report
    (real flyout rendered truncated to 324×180 after the flag revert):**
    the report above originally claimed the `popupWidth`/`popupHeight`
    KConfig keys "were never touched (324×180 before and after)" - wrong
    conclusion from a true observation. The keys were being *rewritten
    with the same values* on every run. Read libplasma 6.7.4's
    `appletpopup.cpp` (fetched from invent.kde.org, not the header alone):
    `AppletPopup::hideEvent()` writes both keys **unconditionally on
    every close** whenever `appletInterface` is set - no resize involved -
    and `setAppletInterface()` applies them at construction
    (`m_sizeExplicitlySetFromConfig` → `resize`). Confirmed empirically:
    keys deleted, shell restarted, one harness run with no resize → keys
    back at 324×180 (= the placeholder mainItem's 18×10 grid units). So
    the 7.1.0 hazard is broader than "resize-testing": *any* open/close of
    `FlyoutPopup` - by the harness or by hand - persists the spike's size
    into the group the real flyout reads on its next construction, i.e.
    after the next `plasmashell --replace`. The 324×180 baseline recorded
    at the start of this session was itself already this corruption, left
    over from 7.1.0's last open/close after its own cleanup. Fixed in the
    harness: `run` snapshots both keys for every instance of the applet
    before starting and restores them (or deletes them if absent) at
    teardown, logged in `run.json`; verified against a *fresh* shell:
    keys absent before → "rewritten 324×180, restoring" logged → absent
    after. (Verification subtlety: a run against a shell that still
    caches the old values shows no write at all, because
    `KConfigGroup::writeEntry` only marks the group dirty when the value
    differs from its in-memory copy - an external `kwriteconfig6
    --delete` doesn't invalidate that cache. Test this class of thing
    after a `plasmashell --replace`, never against a running shell.) Applies until 7.8.0's cutover removes the sharing;
    7.7.0's size-pinning does not change this (pinning fixes what gets
    written, not that it gets written). Real flyout restored by deleting
    both keys + `plasmashell --replace`; keys confirmed absent at the end
    of the phase, flag off.
    - Teardown: flag reverted, `kpackagetool6 --upgrade` +
      `plasmashell --replace`, zero probe output at startup, no new QML
      errors from this plasmoid, daemon active.
  - **Not verified by me**: a real click on the shell-managed flyout
    after the revert (no input automation; the load path is intact and
    the code path is untouched, but the click itself is yours to
    confirm). `KnownAmps` length in the probe's snapshot is always
    `null` (opaque array, see above) - the driver checks `AmpIp`/
    `VolumeDb`/`PowerState` instead, which distinguish every amp value.
  - **Requirements this places on 7.3.0+ (in the README's house
    rules)**: every anchored element gets a stable `objectName`; UI-only
    state is a plain property on one item that `FlyoutPopup.qml`'s probe
    points `uiTarget` at (7.3.0: `ampListOpen` on the content root, the
    overlay binding to it internally - consistent with option (b)'s
    self-containment, and unchanged if that option is ever reverted);
    the settle floor is re-measured per phase by running the phase's set
    at 600 and 1200 ms and comparing, never copied forward.

- [x] **Phase 7.3.0 — Amp header + amp list section.** Depends on 7.2.0.
      First real-content section of the FlyoutPopup rebuild. §4 point 4
      option (b) implemented: the amp list is pulled out of in-flow
      mainColumn into a self-contained overlay, so amp count and
      expand/collapse cannot move anything below the header. Flag committed
      `false` (off), matching the repo convention that the spike flag is
      flipped to `true` only locally to test (see main.qml:83's own
      comment); it was `true` on-disk during the 2026-09-03 session for the
      user's live confirmation below, then set back to `false` for the
      commit. That session also diagnosed the AppletPopup size-key
      collision, which had truncated the *old* flyout while the flag was
      off - popup size keys cleared as the fix, and the harness clears them
      on each run's teardown.
  - **New components**: `FlyoutContent.qml` (successor to
    FullRepresentation.qml's root - header-subset D-Bus mirror, background
    tint, settings gear, mainColumn, the `ampListOpen` UI-state hook, and
    the `popupVisible`-driven hide reset); `AmpHeader.qml` (in-flow header,
    finding 3 applied - every Label `wrapMode: Text.NoWrap` +
    `maximumLineCount: 1`; height pinned to a measured literal, 46 row + 26
    pad = 72, every child `Qt.AlignVCenter`, no `AlignBaseline`; owns its
    own bottom divider); `AmpListOverlay.qml` (a QtQuick.Controls Popup, not
    a second Dialog - PC3 ComboBox precedent - anchored flush under the
    header, findings 4/5/6/7: real ScrollView+ScrollBar instead of the old
    silent clip-at-220, "no amps" label, the divider as the overlay's own
    bottom edge, the Repeater height all contained). `FlyoutPopup.qml` hosts
    `FlyoutContent` and now sizes the popup to its implicit size (was the
    spike's hardcoded gridUnit*18 x gridUnit*10).
  - **Divider decided from the mockup, not guessed** (task item 4):
    `devialet_tray_boot_state_mockup.html` - `.amp-header{border-bottom}`
    is the header's own edge (always on, in `AmpHeader`);
    `.amp-list.open{border-bottom-color:var(--divider)}` is the list's own
    edge (only while open), so it became the overlay's opaque background's
    1px bottom border. Neither divider "separates" adjacent content, so
    neither needs an in-flow mainColumn sibling.
  - **Self-containment** (task item 2): the overlay crosses its boundary
    only via inputs `theme`/`knownAmps`/`ampIp` and outputs `closed`
    (Popup's own) + `ampChosen(ip)`; reverting option (b) to an in-flow
    list is this file + one line in FlyoutContent. State sync is
    binding-free (a Popup's `visible` must never be bound - closePolicy
    calls close() imperatively): `ampListOpen` is a plain bool with four
    imperative writers (header toggle, overlay `closed`, flyout-hide reset,
    harness UiState) and one consumer (`onAmpListOpenChanged` -> open()/
    close()); re-entrancy terminates because close() on a closed Popup
    emits nothing.
  - **Harness extended**: `LayoutProbe.qml` now walks `Overlay.overlay`
    (Popup content is reparented there, path prefix `overlay`), logs a
    rotation-invariant window-space **center** (`wcx`/`wcy`) alongside the
    origin corner, and records the flyout window's `active` flag;
    `analyze.py` diffs on the center (the corner is a false positive on a
    rotated item - the caret's 180deg flip) and warns on any state whose
    popup is not visible+active. `expected-7.3.0.json` allowlists overlay-
    subtree keys (matched by walk path, since those items carry
    objectNames). Two real harness bugs found and fixed by 7.3.0's own
    first run: the allowlist matched key only, missing objectName-keyed
    overlay items (now matches path too); and the caret's rotated origin
    read as a 7x13px move (now center-based).
  - **Verified live (Plasma 6.7.4, Wayland/KWin, 2x), flag on, harness
    driving via D-Bus (no input automation):**
    - `run --vary amp,list` (14 states, 0known/1auto-short/1auto-long/
      1none/2none/2sel-short/2sel-long x closed/open) + control:
      **exit 0, zero unexpected moves, zero warnings, a single popup-
      geometry row** - the master-finding guarantee: `mainColumn`, the
      header, `sectionsPlaceholder` and `settingsTrigger` are pixel-
      identical across every amp count and both list states; the 772
      "allowed" moves are all overlay-subtree (the overlay resizing with
      amp count, rows appearing), state-dependent by design.
    - Header height a constant **72** across all amp states (the pinned
      literal matches the real layout exactly).
    - Settle floor: `--vary amp,list` at 600 vs `--settle-ms 1200` →
      `harness.py compare` **identical coordinates**; layout lands by
      600 ms. `--set smoke` exit 0.
    - **No second window** (task item 3, verified not inferred): the
      in-window Popup leaves the flyout window `visible`+`active` in every
      `list=open` state (a second native window taking activation would
      flip `active` false and hideOnWindowDeactivate would close the
      flyout); the `QWindow::setWindowState does not accept
      Qt::WindowActive` warning stayed **absent** across the whole
      session; zero QML errors from the new files.
    - Eyeballed (standalone fakeamp, keys cleared so the popup takes its
      content-driven size): popup 316x357 window / 300x342 mainItem;
      header (copper dot, DEVIALET eyebrow, model name, ip · Connected,
      gear, open caret) and overlay (None row italic + outline dot, inner
      divider, selected amp copper + check, second amp "· name
      unresolved") render per the mockup; overlay floats over the
      still-empty placeholder region.
  - **Physical-click behaviours - user-confirmed live 2026-09-03** (these
    can't be driven by the harness, which has no input automation, so they
    were left for the user's own click, same as every prior phase): the
    real dismiss *gestures* both work - **Escape closes the flyout**, and
    **a click outside the flyout closes it** (`closePolicy: CloseOnEscape |
    CloseOnPressOutsideParent`); and **the amp list resets to closed when
    the flyout is closed with the list open and then reopened** (the
    `popupVisible`-driven `ampListOpen = false` hide reset) - the user
    explicitly confirmed this last is the desired behaviour. The
    `mainItem`->content focus relay fires only on a real window-activating
    click (not the harness's programmatic `visible=true`); no focus warning
    occurs either way. User verdict: "I don't see any reason to not move
    ahead with this" - 7.3.0 accepted, proceed to 7.4.0.
  - **`sectionsPlaceholder`**: a 270px spacer standing in for
    7.4.0-7.6.0's volume/action/source/footer, so the popup has a
    realistic ~342px content height and the overlay isn't clipped. An
    estimate, not a measurement of the old flyout; each later phase
    shrinks it and it is gone by 7.6.0.
  - **Note for whoever commits**: the Phase 7.2.0 harness python files
    were `git add`ed for review, which also staged
    `tools/flyout-harness/__pycache__/*.pyc` - worth a `git rm --cached`
    + a `__pycache__/` gitignore entry before committing.

- [x] **Phase 7.4.0 — Volume block: dB/unit readout, source chip,
      slider.** Depends on 7.3.0 verified solid — this section sits
      directly below the amp list, so it's the first real test of
      whether 7.3.0's chosen height strategy actually held.
  - **New component**: `VolumeBlock.qml`, following AmpHeader.qml/
    AmpListOverlay.qml's Phase 7.3.0 precedent exactly - pure signal-up
    (`stepRequested(direction)`/`sliderReleased(value)`), no direct
    D-Bus/exec calls of its own. Replaces the first chunk of
    FlyoutContent.qml's `sectionsPlaceholder` (270 → 156, an estimate
    for 7.5.0/7.6.0's remaining sections, same as 7.3.0's own estimate
    was for all four).
  - **Architecture decision, not in the original task brief - flagged
    here rather than silently made**: volumeDb is fed from
    `root.pendingAmpState.volumeDb` (Phase 5's shared, daemon-resolved
    pending-or-confirmed value), *not* a new local D-Bus mirror the way
    FullRepresentation.qml's `root.volumeDb` still works. This makes
    FullRepresentation.qml's `lastVolumeButtonStepAtMs`/
    `lastVolumeSliderReleaseAtMs`/`volumeInteracting` debounce
    machinery unnecessary here: Phase 5.0.2 Step B already made
    `PendingAmpState.notifyVolume()` write synchronously, same-tick,
    before firing its D-Bus call, and the daemon's own
    `resolve_pending_commands()` (Phase 5.0.0) already owns confirmed-
    vs-expired resolution. `CompactRepresentation.qml`'s `stepVolume()`
    already relies on exactly this with no such bookkeeping - this
    phase's `FlyoutContent.stepVolume()`/`releaseVolume()` mirror that
    file's shape 1:1, not FullRepresentation.qml's older one. The
    slider's external Binding is `when: !pressed` only, no separate
    holdout flag needed (the "snap-back risk" that blocked switching
    FullRepresentation.qml's own binding no longer applies once
    notifyVolume() writes synchronously - see VolumeBlock.qml's header
    comment for the full reasoning).
  - Fix finding 1 (the dormant `AlignBaseline` on the dB-value/unit
    `RowLayout`): converted `dbValueRow` to `AlignVCenter` on both
    Labels + a measured `Layout.preferredHeight`. Neither Label's font
    swaps state in this row (checked `FullRepresentation.qml` first,
    per the task's own instruction - only `dbValueLabel`'s text
    *length* varies, numeric vs the "—" placeholder), so the row's
    implicit height was already constant; pinned anyway per house
    style. Measured via the harness dump (not copied from another
    file, per the `VolumeToast.qml` lesson): a constant **35** across
    every actually-reachable state (`"-40.0"`/`"-15.0"`, the "—"
    placeholder, and the harness's synthetic `vol=0.0` scenario, which
    the Slider's own `to: -15.0` clamps to displaying `"-15.0"` too,
    same as it would for the original file's identical slider bound -
    not a bug this phase introduced).
  - Fix finding 2 (source chip): `sourceChip`/`sourceChipLabel` gained
    `elide: Text.ElideRight` + `Layout.maximumWidth: 140`, plus an
    explicit `sourceChipLabel.width: parent.width - 18` (needed for
    elide to actually engage - a Label with no width constraint sizes
    to its own implicitWidth regardless of `elide`). Verified against
    the harness's own longest source name, `"Chromecast Audio"` (16
    chars, the protocol's real slot-name maximum) - fits at 140 without
    eliding, confirmed by eyeball (see below).
  - Re-verified finding 8 (the slider): unchanged in shape (width from
    the two fixed 26×26 buttons, `implicitHeight: 26` literal,
    background/handle sized purely from `availableWidth`/
    `visualPosition`) - confirmed still clean by the harness's own zero-
    unexpected-moves result across every state.
  - `wrapMode: Text.NoWrap` added to every Label in this file (not just
    the ones getting `elide`), matching `AmpHeader.qml`'s finding-3
    convention - cheap, not explicitly requested by this task's items,
    but consistent with house style.
  - **New `tools/flyout-harness/expected-7.4.0.json`**, extending
    7.3.0's overlay-only allowlist with this section's own legitimate
    within-row reflow: `dbValueRow`/`dbValueLabel`/`dbUnitLabel` for
    `vol`/`amp`, `sourceChip`/`sourceChipLabel` for `src`/`amp`, the
    fillWidth spacer between them for `vol`/`src`/`amp`, and the
    slider's own fill/handle Rectangles for `vol`/`amp` - each rule
    scoped to the specific dimension that actually drives it (not a
    blanket `dim: "*"`), so an unrelated dimension moving one of these
    keys would still be caught as a real regression.
  - **Verified live (Plasma 6.7.4, Wayland/KWin), flag on, harness
    driving via D-Bus (no input automation), all against
    `tools/flyout-harness/expected-7.4.0.json`**:
    - `run --set smoke`: **exit 0**, 0 unexpected moves, 0 warnings,
      control identical, single popup-geometry row (316×357 window /
      300×342 mainItem, unchanged from 7.3.0). Re-ran after the height
      pin was corrected from an initial 32 guess to the measured 35.
    - `run --vary vol,mute` (the task's own narrow run - 6 states):
      **exit 0**, 0 unexpected moves, 0 warnings. Every allowed move's
      key confined to `VolumeBlock`'s own elements (`dbValueRow`,
      `dbValueLabel`, `dbUnitLabel`, the fillWidth spacer, the slider's
      fill/handle) or the amp-list overlay - nothing under `AmpHeader`/
      `mainColumn`'s other direct children moved at all, confirming
      7.3.0's guarantee held through this section's own dynamic
      content. `mute` alone produced zero geometry change anywhere in
      this section (nothing in the volume block keys off `Muted` - that
      only arrives with 7.5.0's action row).
    - Settle floor: `--vary vol,mute` at 600ms (default) vs
      `--settle-ms 1200` → `harness.py compare` **identical
      coordinates**. 600ms holds for this section too; not re-derived
      upward.
    - `--set full` explicitly not run this phase, per the task's own
      instruction that the full 438-state sweep is reserved for
      7.7.0's phase-end gate.
  - **Eyeballed** (`shots/*.png` from the smoke run, inspected
    directly): base state renders "−40.0 dB" / "Optical 1" chip /
    slider at its correct position, pixel-matching the mockup; the
    `src=long` state's "Chromecast Audio" chip fits without eliding;
    the `amp=0known` (not-connected) state shows the whole block
    correctly dimmed to 0.4 opacity, "—" placeholders in both the dB
    label and the (very faint, by design - same as the original file's
    identical opacity treatment) source chip, slider parked at its
    floor position - all matching `FullRepresentation.qml`'s original
    behavior, not a rebuild regression.
  - Popup size keys (`popupWidth`/`popupHeight`) confirmed restored to
    their pre-run `300`/`342` values after every run via `kreadconfig6`,
    matching CLAUDE.md's AppletPopup size-key collision note; flag set
    back to `false` and the plasmoid reinstalled/`plasmashell --replace`
    afterward, matching 7.3.0's own convention.
  - Did not touch Phase 7.5.0/7.6.0's sections (action row, source
    selector) - `sectionsPlaceholder` still stands in for both.

- [x] **Phase 7.5.0 — Action row: mute/power buttons.** Depends on
      7.4.0 verified solid.
  - **New component**: `ActionRow.qml`, following AmpHeader.qml/
    AmpListOverlay.qml/VolumeBlock.qml's precedent exactly - pure
    signal-up (`muteToggleRequested()`/`powerToggleRequested()`), no
    direct D-Bus/exec calls of its own. Replaces the next chunk of
    FlyoutContent.qml's `sectionsPlaceholder` (156 → 100, an estimate
    for 7.6.0's remaining source-selector+footer section).
  - **Architecture (task item 3)**: `muted` is fed from
    `root.pendingAmpState.muted` (no local mirror), mirroring
    VolumeBlock.qml's volumeDb pattern exactly -
    `FlyoutContent.toggleMute()` mirrors `CompactRepresentation.qml`'s
    `toggleMute()` 1:1 (no debounce - Phase 5.0.2 Step B's
    daemon-resolved shape already covers it). `power`/`powerState` are
    different: `PendingAmpState` deliberately doesn't cover them (its
    own header comment scopes it to `AmpIp`/`VolumeDb`/`Muted` only),
    so they stay in FlyoutContent's existing local D-Bus mirror
    (present since 7.3.0 for the header's dot/sub-text) - this phase is
    that mirror's first *writer* (`togglePower()`), so it's also the
    first phase that needs a debounce guard on `Power`/`PowerState` in
    `onPropertiesChanged` - added, ported verbatim from
    `FullRepresentation.qml`'s `lastPowerChangeAtMs`/`within()`/
    `beginPowerOnBoot()`. Confirmed this really is still needed here
    (unlike volume/mute): Phase 5.0.0's daemon-owned pending-command
    state was scoped to `VolumeDb`/`Muted` only, nothing covers `Power`.
  - Applied §4 point 2 (task item 2) to `powerContentRow` (the
    icon<->spinner swap) - explicit `Qt.AlignVCenter` on every child +
    a measured `Layout.preferredHeight`, even though the investigation
    doc called this row low-risk. Measured via the harness dump across
    off/Booting/on (not assumed from the icon/spinner both being 13x13
    literals): a constant **14** in all three. Extended the identical
    treatment to `muteContentRow` for consistency (task item 2 named
    only the power button by name, but Mute/Unmute's own label-length
    change is the same dependent-child class) - also constant **14**
    across mute on/off. **Correction during verification**: both were
    first pinned at a guessed 18 (not measured) before the harness run
    - caught and fixed to the real measured 14 before the final
    passing run, same "don't copy/guess a number" discipline as
    7.4.0's dB-row pin.
  - **Honesty note, not in the task brief**: unlike `VolumeBlock.qml`'s
    `dbValueRow` (a real nested `RowLayout`-in-`RowLayout`, where the
    `Layout.preferredHeight` pin is structurally load-bearing),
    `muteContentRow`/`powerContentRow` are `Button.contentItem` -
    sized by the `Button` control itself (fills the full 38px button
    height per QQC2's own contentItem geometry management, confirmed
    by the harness dump's own `h:38` vs `ih:14`), not read via
    `QtQuick.Layouts` attached properties. The pin is therefore
    decorative here, not load-bearing - kept anyway per this rebuild's
    stated blanket policy (§4 point 2's own reasoning: pin regardless
    of assessed risk), and each child's explicit `Qt.AlignVCenter` is
    what's actually doing the safety work (no cross-sibling
    contamination, unlike `Qt.AlignBaseline` - see CLAUDE.md's house
    rule for why that distinction is what makes VCenter safe by
    construction here even without a functioning height pin).
  - **New `tools/flyout-harness/expected-7.5.0.json`**, extending
    7.4.0's file with `ActionRow[0]`-prefixed rules scoped precisely to
    `mute`/`pow`/`amp` (the three dims that actually drive this
    section's own reflow - the two `Layout.fillWidth` GridLayout
    columns trade width against each other as `Mute`/`Unmute`/
    `Power On`/`Power Off`/`Powering on…` text length changes, inherited
    unchanged from `FullRepresentation.qml`'s original GridLayout, not
    a new gap introduced here) plus one narrow rule for `powerSpinner`
    and its two anonymous children, scoped to their own path prefix
    with `dim: "*"` - justified (not a blanket carve-out) by the raw
    coords dump confirming `vis: false` in every flagged pair: an
    invisible `RowLayout` child's computed x/y is incidental Qt Layout
    output that never renders, distinct from its real, asserted
    on-screen position while actually visible (`pow=Booting`, covered
    by the `pow`-dim rule).
  - **Verified live (Plasma 6.7.4, Wayland/KWin), flag on, harness
    driving via D-Bus (no input automation), all against
    `expected-7.5.0.json`**:
    - `run --set smoke`: **exit 0**, 0 unexpected moves, 0 warnings,
      control identical, single popup-geometry row (316×357/300×342,
      unchanged since 7.3.0). Re-ran after correcting the height pins
      from 18 to the measured 14.
    - `run --vary pow,mute` (the task's own narrow run - 6 states, all
      three power states × both mute states): **exit 0**, 0 unexpected
      moves, 0 warnings. Every allowed move's key confined to
      `ActionRow`'s own subtree or (from 7.3.0/7.4.0's carried-forward
      rules) the overlay - zero coordinate drift on `AmpHeader`/
      `VolumeBlock`/`mainColumn`'s other direct children, confirming
      7.3.0/7.4.0's guarantee held through this section's own dynamic
      content, including the genuinely-animated spinner.
    - Settle floor: `--vary pow,mute` and `--set smoke` at 600ms
      (default) vs `--settle-ms 1200` → `harness.py compare` on both:
      every *visible* element's coordinates identical, including
      `powerSpinner`'s own real on-screen position in the `Booting`
      state specifically (checked directly against the raw coords
      dump, not just the diff summary) - confirmed the settle timer
      reliably lands after the spinner has started rendering, not
      mid-transition, per the task's specific concern. The only
      reported diff in either compare was the already-accounted-for
      invisible-spinner incidental-position noise (see above) -
      confirmed non-visual by checking `vis: false` in the raw dump
      before accepting it as harmless rather than assuming.
    - `--set full` explicitly not run this phase, reserved for 7.7.0.
  - **Eyeballed** (`shots/*.png`, inspected directly): `Off` (idle grey
    "Power On"), `Booting` (amber "Booting…" header, amber-bordered
    power button, spinner ring+arc rendered correctly mid-rotation),
    and `mute=on` (copper-highlighted "Unmute" pill, "Power Off") all
    match the mockup; the not-connected (`0known`) state shows the
    whole row correctly dimmed to 0.4 opacity alongside the header/
    volume block.
  - **Not verified this session - needs the user's own click, same
    category as 7.3.0's dismiss-gesture items**: a genuinely live power-
    on against the real amp (real daemon, not the harness's `fakeamp`)
    with the spinner actually rotating on screen in real time, not a
    single still frame. No mouse/keyboard automation exists in this
    Wayland session (confirmed repeatedly across this project's
    history), and the harness's own `fakeamp.py` must own the real
    `com.ekmanch.DevialetRemote` bus name to drive the popup at all, so
    it can't run *alongside* the real daemon to combine "harness-opened
    popup" with "real daemon state" - the two are mutually exclusive
    with the tooling that exists today. Every static state the daemon
    can be in (`Off`/`Booting`/`On`, each mute state) is already
    covered above via `fakeamp`; only the *live, continuous* animation
    against the *real* daemon is unverified by me.
  - Popup size keys confirmed restored to their pre-run `300`/`342`
    values after every run via `kreadconfig6`; flag set back to `false`
    and the plasmoid reinstalled/`plasmashell --replace` afterward,
    matching 7.3.0/7.4.0's own convention.
  - Did not touch Phase 7.6.0's section (source selector + footer) -
    `sectionsPlaceholder` still stands in for it.

- [x] **Phase 7.6.0 — Source selector (ComboBox) + footer.** Depends
      on 7.5.0 verified solid. Smallest remaining section — least
      flagged in the investigation, but still part of the full
      rebuild and still gated the same way as every other section.
  - **New components**: `SourceSelector.qml` (SOURCE eyebrow + the
    ComboBox) and `Footer.qml` (connection-status line), split rather
    than folded into one file (task item 1's "your call") - the
    selector is interactive with its own model/command/signal surface,
    the footer is purely presentational (`online`/`ampIp` only, no
    signal), a genuinely different concern. `sectionsPlaceholder` is
    now **fully consumed** - confirmed by `grep -rn
    "sectionsPlaceholder" plasmoid/` turning up only historical
    comments in prior phases' files, no actual `Item` left anywhere
    (task item 5).
  - **Task item 2, confirmed against the current file rather than
    assumed**: `org.kde.plasma.components.ComboBox` (PlasmaComponents3),
    not QtQuick.Controls' base ComboBox - ported verbatim, including
    FullRepresentation.qml's own extensive QTBUG-66446 justification
    comment. Popup/delegate internals genuinely untouched (confirmed by
    the harness: zero unexpected moves on any of `sourceCombo`'s own
    visible elements across every `src` state - see below); only
    background/contentItem/indicator are restyled, exactly as before.
  - **Task item 3 (§4 point 5), investigated rather than assumed**: the
    task's own premise ("likely...using the existing '—' placeholder
    convention") does not hold here - checked directly
    (`grep '"—"' plasmoid/contents/ui/*.qml`), the literal em-dash
    convention only exists in VolumeBlock.qml (already handled in
    7.4.0) and the toast/tooltip files (not part of this rebuild).
    This section's own placeholder is `sourceCombo.displayText`'s
    `"No source"` fallback (ported from the Android app's
    `no_source_label`), not a dash. Confirmed no new width-reservation
    fix is needed: `sourceComboLabel` is already `Layout.fillWidth:
    true` + `elide: Text.ElideRight` inside a ComboBox whose own outer
    width is fixed (`Layout.fillWidth: true` spans the row,
    content-independent) - "No source" <-> a real source name (up to
    the protocol's 16-char slot maximum) can't nudge the icon badge
    (fixed 24x24, first) or the indicator caret (absolutely positioned
    off `sourceCombo.width`) either inside or outside the row. §4 point
    5's actual goal (no nudging across a placeholder<->real-value
    transition) is achieved via containment (fillWidth + elide), the
    same technique already proven for VolumeBlock's dB-value row and
    source chip - confirmed empirically too: the harness's `--vary src`
    run showed **zero** moves on any of `sourceSelector`'s own visible
    elements (only the ComboBox's own hidden internal cursor artifact
    and VolumeBlock's already-allowlisted source chip moved - see
    below).
  - **Architecture**: pure signal-up
    (`SourceSelector.sourceChosen(index, name)`), matching every prior
    section. `sources`/`activeSourceIndex` added to FlyoutContent
    (array-of-struct, identical `unwrapSources`/`fetchSourcesFresh`
    treatment `knownAmps` already established) plus `selectSource()`.
    `activeSourceName` (added 7.4.0 as an always-trusted scalar) now
    shares `ActiveSourceIndex`'s debounce guard
    (`lastSourceChangeAtMs`) - the identical "gains a guard once it
    gains a local writer" pattern Power/PowerState followed in 7.5.0.
  - **New `tools/flyout-harness/expected-7.6.0.json`**, extending
    7.5.0's file with: (a) a narrow rule for
    `SourceSelector[0]/ComboBox[0]/MobileCursor[0]` (PlasmaComponents3's
    own internal mobile text-selection-cursor handle, part of the
    untouched popup/delegate internals) - confirmed via the raw coords
    dump (`vis: false` in every flagged pair) that it never renders
    while the popup is closed, same precedent as 7.5.0's `powerSpinner`
    rule; (b) a `dim: "amp"` rule for `footer`/`footerDot`/
    `footerLabel` - see the discovery below.
  - **Real finding during verification, not assumed clean**: the
    footer's own `RowLayout` carries `Layout.fillWidth: true` +
    `Layout.alignment: Qt.AlignHCenter` together (ported verbatim from
    FullRepresentation.qml). Initial documentation in `Footer.qml`
    assumed this combination was inert (fillWidth forcing full width
    makes centering moot) and concluded no §4 point 5 concern existed
    there. The harness's own `--set smoke` run (dim `amp`,
    0known vs 1auto-short) proved that assumption wrong: `footer`'s
    measured width tracks its own content, not mainColumn's width, and
    the row visibly recenters (window-space x shifts) as the
    connection-status text's length changes. Corrected: `footerDot`/
    `footerLabel`'s own x *relative to `footer`* never moves (confirmed
    via the raw coords dump) - only the parent row's position as a
    whole. Not a master-finding risk (last row in mainColumn, nothing
    below to cascade into, own height never changes) and not a §4
    point 5 case either (none of "Connected"/"Not connected"/"Not
    responding" is a placeholder form) - allowlisted as a confirmed-
    harmless, inherited-unchanged cosmetic wobble, not silently
    ignored. `Footer.qml`'s header comment corrected to the empirically
    verified explanation before committing.
  - **Second real finding during verification, more significant**: the
    very first `--set smoke` eyeball screenshot was missing the footer
    entirely. Investigated rather than dismissed as a crop error:
    the coords dump's own `begin.mainItem` record showed `ih: 373`
    (the real content's implicit height) against an actual `h: 342` -
    the popup was rendering **31px short of its own content**. Root
    cause: CLAUDE.md's already-documented AppletPopup size-key
    collision (`popupWidth`/`popupHeight` persisted in the applet's
    KConfig group from an earlier session, read back and applied
    verbatim at construction, overriding the content-driven implicit
    size). This was already known/documented policy for *manual*
    testing, but had gone unnoticed across 7.3.0-7.6.0's own harness
    runs specifically because every phase's own "popup geometry" check
    only asserts *stability across states within one run* (a real,
    still-valid check), never *`h` equals `ih`* - so a stale/stuck size
    would pass that check silently every time, which is exactly what
    happened here. Fixed per CLAUDE.md's documented remedy
    (`kwriteconfig6 --delete` on both keys + `plasmashell --replace`);
    re-verified the popup then grew to the correct 300x373 (316x388
    window) and the footer rendered correctly. **All of this phase's
    verification runs were re-run after the fix** - the results
    reported above are from the corrected geometry, not the clipped
    one. Not re-verified retroactively for 7.3.0-7.5.0 (their own
    coordinate-based regression checks remain valid regardless of
    window clipping - Qt still computes item geometry correctly even
    when the containing window is too short to show all of it - so
    nothing there is known to be wrong, only unconfirmed by an explicit
    `h`-vs-`ih` check at the time). Worth folding an explicit `h == ih`
    assertion into the harness itself before 7.7.0's full gate, so this
    can't silently recur - flagging for that phase, not fixed here
    (out of this phase's own scope).
  - **Verified live (Plasma 6.7.4, Wayland/KWin), flag on, harness
    driving via D-Bus (no input automation), all against
    `expected-7.6.0.json`, after the popup-size-key fix above**:
    - `run --set smoke`: **exit 0**, 0 unexpected moves, 0 warnings,
      control identical, single popup-geometry row (316×388/300×373,
      correctly grown from 7.5.0's 316×357/300×342 by this phase's real
      content).
    - `run --vary src` (the task's own narrow run - short/long/none):
      **exit 0**, 0 unexpected moves, 0 warnings. Every allowed move's
      key confined to `SourceSelector`'s hidden `MobileCursor` artifact
      or `VolumeBlock`'s already-allowlisted `sourceChip` (since
      `activeSourceName` feeds both) - zero coordinate drift on
      `AmpHeader`/`VolumeBlock`'s own visible elements/`ActionRow`,
      confirming 7.3.0-7.5.0's guarantee held. `SourceSelector`'s own
      visible elements (`sourceComboLabel`/`sourceIconBadge`/indicator)
      showed **zero** moves at all across every `src` state - empirical
      confirmation of the item-3 investigation above.
    - Settle floor: `--vary src` and `--set smoke` at 600ms (default)
      vs `--settle-ms 1200` → `harness.py compare` on both: `--vary
      src` identical; `--set smoke` showed only the already-documented
      (7.5.0) invisible-`powerSpinner` noise, nothing new. 600ms holds
      for this section too.
    - `--set full` explicitly not run this phase, reserved for 7.7.0.
  - **Eyeballed** (`shots/*.png`, inspected directly, post-fix): base
    state renders the full flyout - header, volume block, action row,
    "SOURCE" + "Optical 1" combo, divider, "● Connected" footer - all
    matching the mockup; `src=long`'s "Chromecast Audio" fits the combo
    without eliding; the not-connected (`0known`) state shows the whole
    selector dimmed, "No source", and "Not connected" in the footer.
  - Popup size keys confirmed restored to empty (their pre-fix,
    pre-this-phase-testing state) after every run via `kreadconfig6`;
    flag set back to `false` and the plasmoid reinstalled/
    `plasmashell --replace` afterward, matching every prior phase's
    convention.

- [x] **Phase 7.7.0 — Full-suite verification gate.** Depends on
      7.3.0-7.6.0 all landed. Not a repeat of each section's own local
      check — the complete state cross product from §5, run once
      against the fully assembled flyout end to end (every dimension
      simultaneously, not one at a time), the actual final gate §5
      describes before calling the rebuild done.
  - **Prerequisite (task item 1): the harness never actually asserted
    `h == ih`.** `analyze.py`'s popup-geometry check (§2) only asserted
    *stability* (one geometry row across every state), which a
    stale-but-consistent stuck size — exactly the Phase 7.1.0/7.2.0
    KConfig size-collision class, and exactly what Phase 7.6.0 found by
    hand via a screenshot missing an element — passes cleanly. Added a
    direct assertion: per state, `mainItem.w == mainItem.iw` and
    `mainItem.h == mainItem.ih`, exact equality (matching `geom_delta`'s
    own no-epsilon convention). Wired into a new exit code (3, between
    1=control-unstable and 2=unexpected-moves in severity) and a
    dedicated report table. **Verified the check itself actually
    catches the bug it's meant to catch**, not just added and trusted:
    deliberately wrote a stale `popupHeight` via `kwriteconfig6`,
    restarted plasmashell, ran `--set smoke` — got exit 3 with a correct
    mismatch table (`300×200` actual vs `300×373` implicit). Cleaned up
    and reconfirmed a clean baseline before the real gate.
  - **Two infrastructure hardening fixes made during this phase, both
    root-caused before being treated as harness bugs to paper over**:
    1. A popup-visibility failure (`win.visible`/`active` flipping to
       `false` between two D-Bus-driven captures with `PopupOpen` never
       toggled by the harness in between — confirmed via the raw
       journal, not assumed) hit twice during early full-sweep attempts.
       Initially suspected as self-inflicted (my own interleaved `sleep
       && tail` check-in commands possibly causing a terminal focus
       event); **the user corrected this live** — it was their own use
       of the computer (and, on a later attempt, their screensaver)
       actually stealing window activation, not anything this session
       did. `hideOnWindowDeactivate` is real, documented
       `PopupPlasmaWindow` behavior (investigation doc §3), not a bug in
       this rebuild's own QML. Added a bounded one-retry recovery in
       `harness.py`'s `run_capture()` that explicitly forces
       `PopupOpen=True` again before re-dumping (not just re-dumping the
       same still-closed window, which would fail identically) — makes
       the gate robust to a one-off external dismissal while still
       failing hard if the popup were genuinely, reproducibly
       dismissable by this rebuild's own content.
    2. A `spectacle wrote a fully transparent image` failure (the
       README's own documented Wayland/XWayland capture-backend caveat,
       first seen in Phase 7.2.0's very first smoke run) recurred twice
       during the same attempts, each time ~100 states apart with no
       common trigger in the state content itself — consistent with the
       user's screensaver/lock explanation (a blanked/locked screen
       captured as transparent), not a QML bug. Added a bounded 3-attempt
       retry directly inside `capture()` (harness.py) — re-invokes
       `spectacle`, does not touch or re-derive any state/position data
       the coordinate checks already verified.
  - **The genuinely clean full pass** (`run --set full --noise-mask`,
    against `expected-7.6.0.json`, real amp state via `fakeamp`, no
    physical interaction with the machine for the remainder of the run
    per the user's own precaution): **exit 0**. 438 states, 876 captures
    parsed, 2409 single-dimension pairs.
    - `control_unstable: False` — every control-pair coordinate set
      identical across all 438 states.
    - `size_mismatch: False`, 0 mismatches — the new prerequisite check
      passing for real, not just present.
    - **Single popup geometry across all 438 states**:
      `{"win": [316, 388], "mainItem": [300, 373, 300, 373]}` — one row,
      `w == iw` and `h == ih` both holding simultaneously across the
      entire cross product (volume text length × mute × power × source
      × amp × amp-list-state).
    - `unexpected_moves: 0`. `allowed_moves: 32819`, spot-checked by
      grouping on key: every single key belongs to an already-
      established, individually-justified allowlist category from
      7.3.0-7.6.0 (`powerSpinner`+children, `ActionRow`'s mute/power
      width-trade family, `VolumeBlock`'s spacer/chip/dB-row/slider
      family, the whole `overlay`/`ampOption:<ip>` subtree, `Source
      Selector`'s `MobileCursor`, `footer`/`footerDot`/`footerLabel`) —
      no foreign key snuck through under a rule that was broader than
      intended. Critically, **no `AmpHeader` element
      (`ampDot`/`ampEyebrow`/`ampName`/`ampSub`/`ampCaret`/
      `ampHeaderDivider`) and no `settingsTrigger` appear anywhere in
      either the unexpected or allowed lists** — the header genuinely
      never moved once, across the full 438-state cross product, which
      is the master-finding guarantee (investigation doc §0) this
      entire rebuild was built to prove.
    - `warnings: []`.
    - The 47,933 total control-pair differing pixels are not a red flag
      - checked directly, not waved off: **100% of nonzero control-pair
        pixel counts (144 of 438 states) come from `pow=Booting` states
        specifically** (the spinner rotation + amp-dot pulse
        animations, the README's own documented un-pixel-matchable
        noise class) - zero non-Booting states show any control-pair
        pixel difference at all. Coordinates, the thing that actually
        gates pass/fail, are unaffected.
  - **Size-pinning protection (task item 4, confirmed decision, found
    live during 7.1.0), done only after the full pass above confirmed
    stability, per the task's explicit ordering requirement**:
    `PlasmaCore.AppletPopup` is user-resizable by click-and-drag as a
    deliberate, built-in feature of the class itself (`appletpopup.h`'s
    own doc comment: "this class is resizable and can forward any input
    events received on the margin to the main item") — no QML property
    to switch it off, not something this rebuild introduces (the
    existing shipped flyout has always been wrapped in the same class).
    **Mechanism confirmed by reading `appletpopup.cpp` directly**
    (fetched from `raw.githubusercontent.com/KDE/libplasma` after
    `invent.kde.org` required auth this session - both are the real
    upstream source, not inferred from the header alone): a
    `LayoutChangedProxy` owned by `AppletPopup` reads `mainItem`'s
    `Layout.minimumWidth/Height` and `Layout.maximumWidth/Height`
    attached properties (via `connectNotifySignal`, independent of
    whether `mainItem` sits inside a real Layout container) and calls
    the window's own `setMinimumSize`/`setMaximumSize` whenever they
    change. Implemented in `FlyoutPopup.qml`: all four properties bound
    reactively to the same `flyoutContent.implicitWidth`/
    `implicitHeight` already driving `implicitWidth`/`implicitHeight`
    (not hardcoded literals - stays correct if content legitimately
    changes later, rather than needing hand-updating). Re-verified after
    adding the pin: `--set smoke` and `--set amp` both **exit 0**,
    identical `316×388`/`300×373` geometry, confirming the pin doesn't
    fight the automatic content-driven sizing (tautologically
    guaranteed, since both are bound to the exact same expression).
  - **Resize-inert verified directly, without a physical drag** (the
    user asked for the drag test; no mouse/keyboard automation exists in
    this session to perform one, so verified via the actual constraint a
    drag would be bounded by instead): opened the popup deterministically
    via `fakeamp.py --state ... --open` (real daemon stopped first, same
    precondition the harness itself enforces), then loaded a small KWin
    script (`org.kde.KWin`'s `Scripting` D-Bus interface -
    `loadScript`/run, `workspace.windowList()`, read back via
    `journalctl _COMM=kwin_wayland`) that inspects the flyout window's
    real `minSize`/`maxSize`/`resizeable` as KWin itself computes them -
    not the QML property values (already confirmed via the harness), the
    actual compositor-level constraint a click-and-drag resize would be
    clamped against. Result, the real window (`w=316 h=388`, matching
    every harness dump): `minW=316 minH=388`, `maxW=316 maxH=388`,
    **`resizeable=false`** - KWin's own computed boolean, arrived at
    independently of the QML-side reasoning, agrees with it. Confirms the
    pin is enforced where it actually matters (the window manager), not
    just correctly wired on the QML side. Cleaned up after (`unloadScript`,
    fakeamp killed, real daemon restarted, `plasmashell --replace` to
    close the still-open popup and revert the flag) - popup size keys
    confirmed still empty afterward (the forced restart didn't trigger a
    graceful `hideEvent` write).
  - **Physically confirmed live by the user, same session**: while the
    popup was open for the KWin-script check above, the user tried
    dragging its edges by hand and could not resize it - agrees with
    both the KWin-level `resizeable=false` reading and the QML-side
    `LayoutChangedProxy` reasoning. Three independent confirmations
    (upstream source, live compositor query, live physical drag attempt)
    now agree.
  - Popup size keys confirmed restored to empty after every run (the
    deliberate stale-key injection during the prerequisite's self-test
    included) via `kreadconfig6`; flag set back to `false` and the
    plasmoid reinstalled/`plasmashell --replace` afterward, matching
    every prior phase's convention.

- [x] **Phase 7.8.0 — Cutover.** Depends on 7.7.0 passing clean. Two
      sequenced steps, matching Phase 5.0.2's "cut over, then delete"
      discipline — not simultaneous, each its own commit.
  - [x] **Step A — make the new build the real path.**
    `CompactRepresentation.qml`'s `onClicked` no longer reads
    `appletPopupSpikeEnabled` at all - `flyoutPopup.visible =
    !flyoutPopup.visible` unconditionally, the old `if
    (root.appletPopupSpikeEnabled) {...} else {root.plasmoidItem.
    expanded = ...}` branch is gone from the active path. `main.qml`'s
    `fullRepresentation:` binding, `FullRepresentation.qml`, and the
    `appletPopupSpikeEnabled` flag/property (both `main.qml`'s and
    `CompactRepresentation.qml`'s own copy, still forwarded) are all
    left in place but genuinely unused now - untouched, per the task's
    explicit "reviewable/revertible in isolation from 7.9.0" scope.
  - **Real regression caught and fixed while doing the cutover itself,
    not left for later**: the hover-tooltip suppress-while-flyout-open
    logic (Phase 4.5.3 item 2/4's fix) was keyed entirely off
    `root.plasmoidItem.expanded`, which nothing sets anymore once the
    left-click path stops touching it - left as-is, the tooltip would
    have silently started appearing over the open flyout again the
    moment this step landed, undoing that fix without anyone changing
    `VolumeHoverTooltip.qml` itself. Fixed by adding the equivalent
    `onVisibleChanged` suppression directly on `flyoutPopup` (mirroring
    the existing `Connections{target: root.plasmoidItem}` block's own
    shape) and updating `onEntered`/`hoverShowTimer.onTriggered`'s
    guards to check `flyoutPopup.visible` too. The old `expanded`-based
    checks were kept alongside the new ones, not replaced outright -
    `expanded` is still a real, live property until 7.9.0 deletes
    `fullRepresentation:` (the shell's own auto-generated per-applet
    "toggle" global keyboard shortcut is a second, independent path
    that can still flip it, opening the *old* `FullRepresentation.qml`
    flyout - untouched by this step, deliberately, since disabling
    global shortcuts isn't in this step's scope and that shortcut
    predates this rebuild entirely). `main.qml`'s own comment on the
    flag corrected to describe its now-vestigial status accurately,
    without touching the binding itself.
  - **Smoke-level verification only, per the task's own explicit
    scope** (the full 438-state cross product already ran clean at the
    end of 7.7.0 and re-running it here would mostly re-prove content
    already proven, not the cutover itself): confirmed the harness's
    own `run --set smoke` passes clean (**exit 0**,
    `control_unstable=False`, `size_mismatch=False`,
    `unexpected_moves=0`) against the now-permanently-unconditional
    path, with **no flag toggling at all** - `appletPopupSpikeEnabled`
    stayed `false` (its permanent value from here on) for the entire
    run, and `LayoutProbe`/`FlyoutPopup` still worked correctly,
    confirming the harness's own precondition #1 (previously "flip the
    flag, reload, revert after") is genuinely obsolete now - updated
    `tools/flyout-harness/README.md` to say so. Eyeballed the smoke
    run's own screenshot: renders correctly, matching every prior
    phase.
  - Popup size keys confirmed restored to empty after the smoke run via
    `kreadconfig6`; plasmoid reinstalled/`plasmashell --replace` after
    the QML changes, matching every prior phase's convention. Real
    daemon confirmed active afterward.
  - **Real soak period, done by the user, real day-to-day use** - volume
    (all the different ways it's adjustable), mute, power cycle, source
    switch, amp pick. Explicit callout: "the new amp list is way nicer
    than the old accordion-style list" (Phase 7.3.0's overlay-instead-
    of-in-flow design, §4 point 4 option (b)). Click-outside dismiss and
    the resize pin re-confirmed live too (the pin: "I have confirmed
    again that I cannot resize the flyout").
  - **Real bug found during the soak, not by the scripted checks**:
    Escape did not dismiss the flyout. Root-caused (not fully proven
    live - no input automation exists in this session to directly
    confirm the exact focus state) from an already-established fact in
    this project's own code: `LayoutProbe.qml`'s header comment
    documents that a `QtQuick.Controls` `Popup` - `AmpListOverlay`, and
    `SourceSelector`'s `ComboBox` dropdown - reparents its content into
    the window's `Overlay.overlay` when open, a *sibling* of `mainItem`
    in the window's item tree, not a descendant of it.
    `Keys.onEscapePressed` (on `flyoutMainItem`) relies on the focused
    item's own `parent`-chain bubbling reaching back up to it; if focus
    is left on something under that reparented subtree (or ends up
    null) after closing one of those popups, the bubbling chain never
    passes through `flyoutMainItem` and its handler never fires -
    consistent with the user's own report ("everything else seems
    fine" - the ComboBox/amp-list interactions themselves worked
    correctly, only Escape *afterward* was affected) and with why the
    scripted harness never caught it (no input automation, so the
    focus-chain state this depends on was never exercised the way real
    clicking does). Compared directly against
    `/usr/share/plasma/shells/org.kde.plasma.desktop/contents/applet/
    CompactApplet.qml` (the real shell reference this file's dismiss/
    focus code was always copied from) - structurally identical
    (`MouseEventListener{focus:true}`/`Keys.onEscapePressed`/
    `onActiveFocusChanged` relay), so this isn't a divergence from the
    real pattern, just a pre-existing fragility in that pattern once a
    Popup-reparenting control is added to the content - something
    `FullRepresentation.qml`'s own ComboBox could equally have hit, just
    apparently never exercised this specific way before.
  - **Fix**: a window-scoped `Shortcut` (`context: Qt.WindowShortcut`)
    added in `FlyoutPopup.qml` alongside the existing
    `Keys.onEscapePressed` (kept, not replaced - still correct for the
    base case). A `Shortcut` fires independent of whichever item
    currently holds focus, sidestepping the bubbling-chain fragility
    entirely rather than patching the exact focus path.
  - **Verified live by the user, multiple times, specifically targeting
    the failure scenario**: Escape now dismisses the flyout reliably -
    "even when the amp list is expanded or the source list is
    expanded," and "definitely works consistently even after I have
    selected a different amp / source" - exactly the interaction
    sequence that triggered the original bug.
  - **Phase 7.8.0 Step A now confirmed solid over real use** - the
    user's own soak-test explicitly given, escape-dismiss bug found and
    fixed within it, re-verified. Proceeding to the next phase is
    unblocked — but see the correction on Phase 7.0.0's own entry above:
    what comes next is no longer cleanup. Cleanup is renumbered
    **Phase 7.13.0** and moved to the end of the sequence below; the new
    **Phase 7.9.0** is the transparency-goal fix this whole rebuild was
    originally for.

- [x] **Phase 7.9.0 — Dialog + Overlay.overlay spike (investigation,
      gates 7.10.0).** Depends on 7.8.0. Corrects the mistake documented
      on Phase 7.0.0's own entry above: the rebuild's whole stated
      reason for existing was real desktop transparency, matching
      `VolumeHoverTooltip.qml`/`VolumeToast.qml`'s already-working look
      — `PlasmaCore.AppletPopup` never delivers that (`PlasmaWindow`'s
      `BackgroundHints` has no `NoBackground` value, confirmed in
      `plasmawindow.h`). This phase is not a repeat of Phase 7.0.0's own
      spike — that proved `AppletPopup` mechanics; this proves the
      specific piece that's genuinely unproven for `PlasmaCore.Dialog`:
      a real `Overlay.overlay`-hosted `Popup`/`ComboBox` (the shape
      `AmpListOverlay.qml`/`SourceSelector.qml` already use) inside a
      bare `Dialog` with `backgroundHints: NoBackground`.
  - Build a throwaway spike (same spirit as the removed
    `AppletPopupSpike.qml`) — a bare `PlasmaCore.Dialog`
    (`backgroundHints: NoBackground`, `type: Dialog.AppletPopup` —
    confirmed to exist as a literal `WindowType` enum member in
    `dialog.h`, unlike either of `VolumeHoverTooltip.qml`/
    `VolumeToast.qml`'s own non-interactive `Tooltip`/`OnScreenDisplay`
    types — `visualParent`/`location: Plasmoid.location` positioning,
    `hideOnWindowDeactivate`) hosting a minimal
    `MouseEventListener{focus:true}` plus a real
    `QtQuick.Controls.ComboBox` or `Popup`, no other real content.
  - Verify live: does it render with real transparency? Does the
    Popup/ComboBox content actually reparent into and render from
    `Overlay.overlay` the same way `LayoutProbe.qml` already confirms
    for `AppletPopup`? Does dismiss-on-click-outside correctly
    distinguish "clicked into the open ComboBox popup" from "clicked
    elsewhere" (the investigation document already read
    `Dialog::focusOutEvent()`, dialog.cpp 1254-1283, and found it
    handles exactly this case — confirm it live, not just from source)?
    Does Escape work? Does keyboard focus reach real interactive
    content? Does edge-aware positioning work correctly at a real
    panel-icon anchor — specifically checking whether it reproduces
    `VolumeHoverTooltip.qml`'s own known off-screen-clip bug (still
    open, see the Bugs section below) or not, since that's the one
    existing real-world data point for this exact positioning
    mechanism (`visualParent` + `location`).
  - If genuinely broken (not just a rough edge) — stop and report back
    before 7.10.0, same as Phase 7.0.0's own go/no-go gate.
  - **Built (throwaway, deleted in 7.13.0)**: `DialogSpike.qml` — a bare
    `PlasmaCore.Dialog` (`type: AppletPopup`, `backgroundHints:
    NoBackground`, `location: Plasmoid.location`, `visualParent` = the
    panel icon, `hideOnWindowDeactivate: true`, `visible: false` initial
    value, Dialog's own default `flags` kept — *not* VolumeHoverTooltip/
    VolumeToast's `WindowDoesNotAcceptFocus` — and deliberately **no**
    `appletInterface`, since `Dialog::hideEvent()` (dialog.cpp 1456-1467)
    writes `popupWidth`/`popupHeight` on every hide whenever it is set)
    hosting `MouseEventListener{focus:true}` with the same
    `Keys.onEscapePressed` + window-scoped `Shortcut` + focus relay as
    `FlyoutPopup.qml`, a `PlasmaComponents3.ComboBox` (the exact type
    `SourceSelector.qml` uses; its popup is a `T.Popup`, i.e.
    Overlay-hosted, same as `AmpListOverlay.qml`'s), a `TextField` and a
    55%-alpha card with a 12px fully transparent band around it as the
    transparency probe. Wired the 7.0.0 way: `main.qml` flag
    `dialogSpikeEnabled` (default `false`, forwarded to
    `CompactRepresentation.qml`, whose left-click opens the spike instead
    of the flyout only when it is `true`) plus a `DialogSpike` instance in
    `CompactRepresentation.qml` given `tooltipRef: hoverTooltip` and
    `flyoutRef: flyoutPopup` for side-by-side measurement. `FlyoutPopup.
    qml`, `FlyoutContent.qml` and every section component untouched (`git
    status`: only `main.qml`/`CompactRepresentation.qml` modified, the
    rest new files).
  - **How it was driven — no hands, no guesses.** No Wayland input
    automation exists on this machine (Phase 7.0.0's finding, re-checked:
    no xdotool/ydotool/wtype/kdotool), so `DialogSpikeDriver.qml` (loaded
    by a `Loader` only while `tools/dialog-spike/spike.py serve` owns
    `com.ekmanch.DevialetRemote.DialogSpike` — the LayoutProbe/fakeamp
    pattern; inert otherwise, and its `import QtTest` is only ever loaded
    into plasmashell during a run) executes D-Bus-delivered commands and
    logs a JSON result per command. Synthetic input is QtTest's
    `TestEvent` (`QuickTestEvent`, `/usr/lib/qt6/qml/QtTest`), whose
    `mouseClick`/`keyClick`/`keyClickChar` go through QTest →
    `QWindowSystemInterface`, the same in-process path a real compositor
    event takes once it is inside Qt — enough for everything decided
    inside Qt (Popup/Overlay handling, focus, `Keys`/`Shortcut`). The
    compositor half ("clicked elsewhere") was done for real from KWin:
    `tools/dialog-spike/kwin-activate.js` hands activation to another
    normal window via `workspace.activeWindow`, and `kwin-geom.js` reads
    back KWin's own `frameGeometry`/`minSize`/`maxSize`/`resizeable`/
    `appletPopup` for the spike window. Screenshots via `spectacle -b -n
    -f` with `QT_QPA_PLATFORM=wayland` forced (CLAUDE.md), analysed with
    PIL/numpy. As an A/B control the driver ran the *identical*
    synthetic-click sequence against the real `FlyoutPopup.qml`
    (`PlasmaCore.AppletPopup`) — opening `SourceSelector`'s dropdown and
    clicking empty flyout space only, never picking a source, so nothing
    was sent to the amp.
  - **Real transparency: YES, measured, not eyeballed.** Screen 1920×1080
    @2x. Full-screen captures closed vs open, spike at (1568,32) 300×260
    over a text-editor window. Card interior (text-free block) mean RGB
    open = 39/37/36; predicted 0.55·card + 0.45·behind = 41.6/40.2/38.8
    (mean abs error 2.84); an opaque card would be 30.6/28/25.5 (error
    9.28); untouched background (error 17.67). The 12px band: every pixel
    identical to the closed capture except a uniform −5.5 shift that is
    also present 30px *outside* the spike window and absent below it — the
    editor window behind dimming as it lost activation, not paint. The
    open capture shows the editor's title-bar icons and text through the
    band and the card. This is the look the whole rebuild was for.
  - **KWin blur-behind: NOT present, and not expected.** The text line
    behind the card stays legible and sharp; high-frequency energy ratio
    open/closed = 0.54 against 0.45 expected for an unblurred 55% overlay
    (blur would drive it far lower). Consistent with `dialog.cpp`
    `updateTheme()` calling `KWindowEffects::enableBlurBehind(q, false)`
    for `NoBackground`. `VolumeHoverTooltip.qml`/`VolumeToast.qml` use
    `theme.osdGradientTop/Bottom` at alpha 0.94, so their "solid" look is
    near-opaque paint, not blur either. Expectation for 7.10.0/7.11.0: a
    `NoBackground` flyout gets true alpha blending over the desktop and
    nothing else; blur would need a mechanism this project already found
    unavailable from QML (Phase 4.0's `KWindowEffects` investigation).
  - **Overlay.overlay hosting: works — after a Qt 6.11 overlay-placement
    bug is worked around (the one genuinely new finding).** Confirmed
    empirically, not reasoned: the dropdown's `contentItem` parent chain
    is `QQuickListView → QQuickPopupItem → QQuickOverlay`, the
    `QQuickOverlay` is a child of `QQuickRootItem` and a *sibling* of
    `mainItem` (`overlayIsSiblingOfMainItem: true`), sized to the window
    once a popup is open, `popupType` 0 (`Popup.Item`, not a native
    window), and the window stays `active: true` throughout. Clicking a
    delegate selected it (`currentIndex` 0→3, `activated` fired, popup
    closed) with the Dialog still visible and active. **But** on first
    open the overlay itself sat at **(−150, −130)** — exactly −(w/2, h/2)
    — so the dropdown rendered 130px above where QQC2 placed it, clipped
    by the window's top edge (screenshot: only "Phono…Line 2" visible,
    overlapping the panel), and press-outside-to-close was dead for
    presses outside the shifted rect (two `click-inside` presses at
    (60,185) left it open; a press on the `TextField` closed it, but via
    `QQuickComboBox::focusOutEvent`, not press-outside). Root cause,
    read from the real Qt 6.11.2 source (`qquickoverlay.cpp` 340-352,
    fetched from code.qt.io): `QQuickOverlayPrivate::updateGeometry()`
    positions the overlay at `-(contentItem.size − window.size)/2` and
    only re-runs on a contentItem geometry/rotation change; `Dialog`
    resizes its `contentItem` **before** its window
    (`DialogPrivate::syncToMainItemSize()`, dialog.cpp 646
    `contentItem()->setSize(s)` then 651 `adjustGeometry(geom)`), so the
    overlay is computed against the stale window size (0×0 on first
    show) and the later window resize changes nothing on the contentItem,
    so it is never recomputed. Every subsequent resize repeats it: the
    driver logged offsets (−150,−130), (−30,0), (0,−80), (+30,0),
    (0,+80), (−100,0), (+100,0) across the size changes. **A/B, same
    Qt, same click path**: the `AppletPopup` flyout's overlay reads
    (0,0) 316×388 while open, its dropdown sat at (24,121) inside the
    window, and one `click-inside` closed it — so this is Dialog-specific
    (window-before-content ordering in `PlasmaWindow`), and it is why
    7.8.0's soak never saw it. **Workaround, verified live**: reset
    `Overlay.overlay.x/y` to 0 from `onWidthChanged`/`onHeightChanged`/
    `onVisibleChanged` of the Dialog (`DialogSpike.qml` `fixOverlay()`).
    With it the overlay reads (0,0) after every open and resize, the
    dropdown lands where QQC2 puts it ((26,30) in the 260-tall window,
    (26,78) directly under the ComboBox in the 420-tall one — same
    fit-inside-window behaviour the AppletPopup flyout shows, whose
    dropdown also flips upward for lack of room), `click-inside`/
    `click-at:150,380` close it, and `click-popup:2` selects. **7.10.0
    must carry this reset into `FlyoutPopup.qml`**; `LayoutProbe.qml`'s
    overlay walk needs no change (its coordinates are overlay-relative,
    which equals window-relative once the overlay is at (0,0) — and the
    harness will independently show any residual offset as a moved
    `overlay/...` element).
  - **Dismiss-on-click-outside distinguishes correctly, confirmed live
    (not from `focusOutEvent()` source reading this time).** Compositor
    half: with the dropdown open, KWin activating another normal window
    closed the Dialog (`visible: false`, `windowDeactivated` emitted —
    the `hideOnWindowDeactivate` path in `Dialog::focusOutEvent()`);
    same with the dropdown closed. In-window half: clicks into the open
    dropdown (select) and clicks elsewhere inside the window (close
    dropdown only) never deactivated the Dialog — `active: true` in every
    dump, no `windowDeactivated`. "Clicked into the open ComboBox popup,
    stay open; clicked elsewhere, close" behaves exactly as the source
    reading predicted.
  - **Escape: works, same two-stage shape as the real flyout.** Dropdown
    open + Escape → dropdown closes (`CloseOnEscape`), Dialog stays.
    Escape again → `window Shortcut(Escape) activated` → Dialog hides.
    With focus in the `TextField`, Escape → Shortcut → hides.
    `Keys.onEscapePressed` on `mainItem` never fired (focus sits on the
    ComboBox, exactly the 7.8.0 fragility) — the window-scoped Shortcut
    is what does the work, so 7.10.0 must keep it.
  - **Keyboard focus reaches the real controls.** Immediately after
    `open`: `activeFocusItem` = the ComboBox (via `mainItem` →
    `combo.forceActiveFocus()` relay, logged `mainItem activeFocus: true`
    → `false` → `combo activeFocus: true`). Down arrow twice →
    `currentIndex` 3→4→5 with `activated` fired each time. Click on the
    TextField → it takes focus; `type:hello` → `text: "hello"`. KWin
    reports the window `active: true`, `appletPopup: true`
    (`role_appletpopup` from `applyType()`), and `setTakesFocus(true)`
    from the default flags evidently holds.
  - **Positioning at the real panel icon: correct, including the edge
    clamp.** Icon centre x = 1718 (panel top edge, 36px tall). Every open
    landed at (1568,32) 300×260 — centred on the icon; 360 wide →
    (1538,32); **500 wide → (1420,32) = 1920 − 500**, the right-edge
    clamp in `popupPosition()` (dialog.cpp 1112-1120), KWin's
    `frameGeometry` agreeing on every reading; shrinking re-centres. The
    Dialog re-positions on every `mainItem` size change while open
    (`updateLayoutParameters()` → `popupPosition()`), the mechanism the
    tooltip bug was suspected to lack. **`VolumeHoverTooltip.qml`'s clip
    bug did not reproduce**: the spike never clipped in ~15 opens across
    three sizes, and the tooltip itself, shown at the same anchor by
    setting `visible = true` directly, came up at (1632,32) 172×98 —
    centred, fully on screen — in both QML's and KWin's geometry.
    Caveat stated plainly: that is the same statement the hover timer
    runs, but with no pointer over the icon; the bug's real trigger
    (an actual hover) was not exercised, so the bug stays open, just
    with one more data point that the `visualParent` + `location` maths
    is not the problem.
  - **Sizing finding for 7.10.0: `Dialog` does not follow `mainItem`'s
    implicit size after show — the `Layout` hints are the sizing
    mechanism, not just the resize pin.** With no hints, `grow:true`
    (implicit 300×260 → 360×420) left the window at 300×260 and KWin
    reported `minSize` 20×20, `resizeable: true`. Dialog sizes the window
    from `mainItem`'s *actual* size at show and then owns it
    (`updateLayoutParameters()` calls `mainItem->setSize()` from the
    window); what it listens to are `Layout.minimum*/maximum*`
    (`getSizeHints()`, `updateMinimumWidth()` & co.). With the four
    hints bound to the implicit size — the exact 7.7.0 pin — `grow` →
    360×420 and `wide` → 500×260 followed immediately, and KWin read
    `minSize = maxSize = 300×260` / `500×260`, **`resizeable: false`**:
    the pin holds under Dialog, re-verified compositor-side as 7.7.0
    required (physical drag not done — no input automation; same
    three-pronged gap as 7.7.0 closed by the user's own drag).
    **Danger found the hard way**: switching the max hints to 0 while
    shown (`pin:false`) killed plasmashell instantly — "The Wayland
    connection experienced a fatal error: Protocol error" /
    kwin_wayland_wrapper "error in client communication (pid …)", no
    coredump. Never let those hints go to 0/invalid on a visible Dialog;
    bind them to the content size from the start and leave them.
  - **Housekeeping proven**: no auto-open (no `visible -> true` without a
    preceding `open` across five shell restarts); no `QWindow::
    setWindowState does not accept Qt::WindowActive` warning; no
    "trying to show an empty dialog" warning even though the first
    `visible -> true` logs geometry 1718,32 0×0 before the size lands;
    the only Dialog-related warning in the journal ("Member visible of
    the object PlasmaQuick::Dialog overrides a member of the base
    object") predates this session (present at 21:15, before the spike
    existed). Popup size keys: the spike (no `appletInterface`) never
    wrote them; they *did* drift 300/373 → 284/358 during the session,
    and one real flyout open/close wrote 300/373 back — the writer is
    `AppletPopup::hideEvent()` on a never-shown `FlyoutPopup` at
    `plasmashell --replace` time (window = config size, `mainItem` =
    window − frame margins 16×15), i.e. CLAUDE.md's "writes on every
    close" note also covers shell replacement, harmless while the pin
    re-forces the size on show. Cleaned up per CLAUDE.md: both keys
    deleted, `plasmashell --replace`, keys confirmed absent, real daemon
    active, driver unloaded (`spike.py quit`), flag left `false`.
  - **Not tested**: a human on the `dialogSpikeEnabled` flag path (real
    pointer/keys — the synthetic path covers Qt-internal behaviour, the
    KWin script covers activation, but nobody physically clicked this
    session); panel move / monitor change while open (the same gap 7.0.0
    carried); a real hover over the icon for the tooltip bug.
  - **Verdict: GO for Phase 7.10.0, with conditions written into its
    entry below** — nothing genuinely broken, one real Qt bug with a
    verified two-line workaround, one sizing mechanism difference that
    the existing 7.7.0 pin already satisfies, one 4px positioning
    difference to decide on. Awaiting the project owner's explicit
    go-ahead before any 7.10.0 work, per this phase's own gate.

- [x] **Phase 7.10.0 — Rebuild FlyoutPopup.qml on PlasmaCore.Dialog.**
      Depends on 7.9.0's spike coming back clean. Done 2026-09-05 — see
      the "Results" bullets at the end of this entry; not committed (the
      project owner commits after checking it by hand).
  - **Conditions from 7.9.0's findings (see that entry for the proof)**:
    (1) carry the `Overlay.overlay` (0,0) reset into `FlyoutPopup.qml`
    (Qt 6.11 `QQuickOverlayPrivate::updateGeometry()` vs Dialog's
    content-before-window resize order — without it every
    Overlay-hosted popup renders offset and press-outside dies);
    (2) keep the four `Layout.minimum*/maximum*` hints bound to the
    content size from the start — on Dialog they are the sizing
    mechanism as well as the pin, and setting them to 0 while shown
    crashes plasmashell via a Wayland protocol error;
    (3) keep the window-scoped Escape `Shortcut` (the `Keys` handler
    never fires with focus on the ComboBox); (4) decide the 4px: Dialog
    positions against the icon item's own bottom (y=32) not the panel's
    bottom edge (y=36) that AppletPopup used — a top margin/inset or an
    accepted 4px overlap; (5) expect no KWin blur — `NoBackground` is
    plain alpha over the desktop.
  - Rebuild `FlyoutPopup.qml` around `PlasmaCore.Dialog`
    (`backgroundHints: NoBackground`), reusing `FlyoutContent.qml` and
    every section component (`AmpHeader`, `AmpListOverlay`,
    `VolumeBlock`, `ActionRow`, `SourceSelector`, `Footer`) as-is or
    with minimal changes — the section components themselves need no
    changes; only the host window class and `FlyoutPopup.qml`'s own
    `AppletPopup`-specific properties change:
    `popupDirection`→`location` (Dialog has no `popupDirection`; use
    `location: Plasmoid.location` directly, same type
    `Plasma::Types::Location` on both), `removeBorderStrategy`→removed
    (no Dialog equivalent — likely moot once `NoBackground` removes the
    drawn frame border there'd be nothing left to "remove borders"
    from), `floating` if used (type mismatch: `AppletPopup`'s is
    `bool`, `Dialog`'s is `int` "by how much... floating" — not
    currently set by `FlyoutPopup.qml`, confirm still unneeded).
    `visualParent`, `hideOnWindowDeactivate`, `mainItem`,
    `appletInterface` keep the same names/types on both classes.
    `appletInterface`'s tie-in to KConfig `popupWidth`/`popupHeight`
    persistence is marked `// TODO: plasmoidItem?` in `dialog.h` itself
    — verify this still persists correctly, don't assume identical
    behavior just because the property exists.
  - Re-verify the Phase 7.7.0 resize-pin fresh under `Dialog` (own
    three-pronged check: harness geometry, live KWin-script
    `minSize`/`maxSize`/`resizeable` query, physical drag) — not
    assumed to carry over. The pin's actual C++ implementation
    (`LayoutChangedProxy`) is a private `AppletPopup`-only member
    (`appletpopup.h`); `dialog.h`'s own `DialogPrivate` separately
    declares parallel slots (`updateMinimumWidth()`,
    `updateMaximumWidth()`, `updateMinimumHeight()`,
    `updateMaximumHeight()`, `updateLayoutParameters()`,
    `slotMainItemSizeChanged()`) strongly suggesting the same
    conceptual mechanism exists natively on `Dialog` — but via
    different private code, so re-verify, don't assume.
  - `Keys.onEscapePressed`, the Phase 7.8.0 window-scoped
    `Shortcut{Escape}` fix, the `MouseEventListener{focus:true}`/
    `onActiveFocusChanged` relay, `requestActivate()`, and the
    `visible: false` initial-value workaround are generic QML/`QWindow`
    API unaffected by the base class — port verbatim.
    `CompactRepresentation.qml` needs no changes at all: `Dialog`
    exposes the identical `Q_PROPERTY(bool visible READ isVisible
    WRITE setVisible NOTIFY visibleChangedProxy)` contract
    `flyoutPopup.visible = !flyoutPopup.visible` already depends on.
  - Do not touch `AmpListOverlay.qml`, `SourceSelector.qml`, or any
    other section component's own content — this phase is the host
    window only.
  - **Results (2026-09-05).** Four explicit requirements carried in from
    the go-ahead, each answered below: (1) never zero the pin hints
    while shown, (2) apply and re-verify the overlay reset in the real
    build, (3) test the tooltip clip bug under real hover trigger
    conditions, (4) correct CLAUDE.md's stale "goes away at 7.8.0".
  - **What changed.** `FlyoutPopup.qml` rewritten around
    `PlasmaCore.Dialog` (`type: AppletPopup`, `backgroundHints:
    NoBackground`, `location: Plasmoid.location`,
    `hideOnWindowDeactivate: plasmoidItem.hideOnWindowDeactivate`, no
    `flags` override, no `appletInterface` — see below). Everything
    generic ported verbatim: `MouseEventListener{focus:true}` +
    `onActiveFocusChanged` relay, `enabled: visible`, `requestActivate()`,
    `visible: false` initial value, `Keys.onEscapePressed` + window
    `Shortcut{Escape}`, the four `Layout` hints, `LayoutProbe`,
    `FlyoutContent`. `CompactRepresentation.qml` unchanged (its
    `flyoutPopup.visible = !flyoutPopup.visible` contract holds).
    `FlyoutContent.qml` got the one "minimal change" this entry allowed
    for: its tint Rectangle no longer bleeds outward by the Darkly frame
    insets (the `KSvg.FrameSvgItem` measuring `dialogs/background` and
    the four `inset*` properties are gone, `org.kde.ksvg` import
    dropped) — under `NoBackground` mainItem IS the window (measured
    window 300×373 == mainItem 300×373 == contentItem), so a negative
    margin would only have clipped the rounded corners square. Section
    components untouched.
  - **(1) Pin hints — hard rule applied.** The four hints are bound
    permanently to `flyoutContent.implicitWidth/Height` from
    construction; nothing in the file can set them to 0 or unbind them
    while shown. Written into `FlyoutPopup.qml`'s header as a HARD RULE
    with the 7.9.0 crash as the reason. Re-verified under `Dialog` with
    the entry's three prongs minus the physical drag: harness geometry
    300×373 in every state (7/7, control identical); KWin script
    readback `minSize [300,373] == maxSize [300,373]`, `resizeable:
    false`, `appletPopup: true`; a physical edge drag could not be
    performed (no input automation, see (3)) — KWin's own `resizeable:
    false` is the compositor-level statement that the drag has nothing
    to act on, the same evidence 7.9.0 accepted.
  - **(2) Overlay reset — reproduced in the real build, then fixed by
    the port.** First open after a fresh shell logged
    `[FlyoutPopup] overlay offset -150 -186.5 (width 300) -> reset to
    0,0` — the exact Qt 6.11 `QQuickOverlayPrivate::updateGeometry()`
    symptom from the spike, at the real flyout's own size (half of
    300×373). After the reset the driver measured `overlayGeom [0,0,
    300,373]` on every subsequent open (the offset only occurs once,
    on the first show; later opens log nothing). Both Overlay-hosted
    popups verified in place via `tools/dialog-spike/` driving the
    real flyout with QtTest synthetic input: the source ComboBox
    dropdown renders as overlay child at (16,114) 268×168 (flipped
    upward above the combo at y=282 because 168px does not fit below
    inside the 373px window — QQC2's own fit logic, same window height
    as before, not a regression) and matches the screenshot; a click
    into the footer closes it and leaves the window open; Escape #1
    closes the dropdown, Escape #2 the window (window Shortcut path,
    as in the spike); `AmpListOverlay` opens as overlay child at
    (0,72) 300×145, renders in place (screenshot), closes on a click
    into the footer. Press-outside on both works because the overlay
    now covers the window. KWin handing activation to another window
    closed the flyout (`hideOnWindowDeactivate` through
    `plasmoidItem`'s value, `true` here). Focus lands on
    `FlyoutContent` → `sourceCombo` on open, as before.
  - **Positioning: the 4px decided, plus a 1px Dialog quirk found.**
    Decision: flush with the panel edge, exactly where `AppletPopup`
    put it (y=36), no transparent strip and no size change. Mechanism:
    `visualParent` is a new invisible `panelSpan` Item, declared in
    `FlyoutPopup.qml` but reparented into the icon item, spanning the
    icon's extent along the panel and the panel window's full
    thickness across it, with a live ancestor-walk binding for its
    position. First measurement landed at y=35: `popupPosition()` uses
    `QRect::bottom()`/`right()`, which are inclusive (top+height−1) —
    also why the 7.9.0 spike anchored to a 3..33 icon sat at y=32, not
    33. Fixed by extending the span by 1px on the far side only
    (near edges use `top()`/`left()` and are exact). Final: window
    (1568,36) 300×373 from QML, KWin and the harness alike; x centred
    on the icon (1718−150). `DialogSpikeDriver.qml`'s `flyoutInfo()`
    now logs `visualParent`/`panelSpan` window+global rects and
    `dialogVisualParentIsSpan` so this stays checkable.
  - **(3) Tooltip clip bug under real hover trigger conditions.**
    Attempt A — a real compositor pointer: built a throwaway Wayland
    client (session scratchpad, Rust, `wayland-protocols-plasma`'s
    `org_kde_kwin_fake_input`) that KWin would let move the actual
    pointer, but KWin only offers that global to clients whose
    `.desktop` entry lists it in `X-KDE-Wayland-Interfaces` (kwin
    6.7.4 `allowInterface()`, message "not in X-KDE-Wayland-Interfaces
    of"), and registering such an entry was blocked by the session's
    permission classifier as a system change needing the owner's OK —
    not attempted again; the binary is throwaway and the entry was
    never installed. Attempt B — the real hover *code path* with a
    synthetic pointer: QtTest `TestEvent.mouseMove(item,x,y,delay,
    buttons,modifiers)` (six arguments in 6.11; fewer throws
    "Insufficient arguments" silently inside the driver — found and
    fixed) on the panel window → `MouseArea.onEntered` →
    `hoverShowTimer` (real 700ms) → `hoverTooltip.visible = true`,
    i.e. every line of the real trigger except the compositor's
    pointer focus. 21 shows across: 3× first-show after a fresh shell,
    6× before opening the flyout, 6× after closing it (the bug report's
    "both before and after"), 6× flyout-open-while-shown (tooltip hid
    every time), all with hover-away hides in between. Every one of
    the 21 positioned at (1632,32) 172×98 — centred on the icon,
    fully on screen — in QML *and* in KWin's `frameGeometry` (the
    first one read back live: `tooltip: true`, x 1632, y 32), with a
    screenshot showing it rendered in place. One unscripted real hover
    also happened mid-run (someone at the machine hovered and clicked
    the icon between two driver commands, opening the real flyout);
    the tooltip geometry recorded right after was the same (1632,32)
    172×98. Verdict: the clip did NOT reproduce through the real hover
    code path, 21/21 — but the compositor pointer was never over the
    icon in the scripted runs, so this entry does not claim the bug
    cleared; it narrows the remaining suspect to something only a real
    pointer does (KWin-side pointer focus/placement interplay, or the
    icon's real hover-enter timing). A single hand hover in the
    owner's soak, screenshot if it clips, is the remaining test.
    Separate observation, pre-existing and untouched: the tooltip's
    own `visualParent` is the icon item, so it sits at y=32, 4px into
    the 36px panel — the same anchor quirk this phase fixed for the
    flyout via `panelSpan`; `VolumeHoverTooltip.qml` is not this
    phase's file.
  - **Transparency on the real flyout — measured, real.** Same-patch
    closed-vs-open pixel test on full-screen captures: a tint patch
    with wallpaper behind it reads open=(28.1,26.3,29.8) vs the
    α=0.82 blend prediction (28.1,25.4,29.7) — mean error 0.35 — vs
    7.08 from opaque paint; a patch outside the window is identical
    closed/open (44.2 from the blend, i.e. nothing painted there). The
    wallpaper is visible through the flyout in the screenshots, rounded
    corners intact edge to edge. No blur, as expected.
  - **`appletInterface` — verified, deliberately not set.** From
    `dialog.cpp`: `hideEvent()` writes popupWidth/popupHeight on every
    hide when set; `updateSizeFromAppletInterface()` (the only reader)
    returns before reading when min == max; `updateResizableEdges()`
    likewise yields no edges. So on this pinned window it is one KConfig
    write per close for nothing. Verified by absence: keys deleted,
    then ~20 open/close cycles, the harness run and four
    `plasmashell --replace` (the last at cleanup) — still absent each
    time. Before the rebuild the *old* shell wrote 300×373 at the
    upgrade's own `--replace`, the last write those keys will see from
    this flyout.
  - **Harness.** `tools/flyout-harness/harness.py run --set smoke
    --label phase7.10.0-smoke` → run
    `20260905-123825-phase7.10.0-smoke`: 7 states, control identical
    (0 differing pixels), one geometry 300×373 (300×373 mainItem) in
    all 7, 0 unexpected moves against `expected-7.6.0.json` (113
    allowed hits on 73 elements, all the known state-driven ones),
    verdict PASS. Crop box now `[3136,72,3736,818]` = mainItem at the
    window origin (no frame). `LayoutProbe.qml`'s `Overlay.overlay`
    walk needed no change (7.11.0's open question): the `list=open`
    state logged 115 items vs 74, the extra 41 being the amp list
    under the `overlay` prefix, after the overlay reset. The full
    438-state gate is 7.11.0's.
  - **(4) CLAUDE.md corrected** — the size-key section's title and its
    last paragraph now say it did not go away at 7.8.0 (why: the
    shell-managed popup stays instantiated until 7.13.0 and the
    cut-over popup was itself an AppletPopup with appletInterface) and
    how 7.10.0 closed it; the Known-issues transparency note points at
    this phase as delivered.
  - **Not done / carried forward.** Physical edge-drag and a real-
    pointer hover (both need input the session could not inject, see
    (3)); panel move / monitor change while open (same gap 7.0.0 and
    7.9.0 carried); left/right/bottom panel locations — `panelSpan`'s
    axis logic covers them by construction but only the top edge was
    run; soak under normal use (7.11.0). `tools/dialog-spike/`,
    `DialogSpike.qml`, `DialogSpikeDriver.qml` stay until 7.13.0 as
    the only way to script this window; the fake-input client lives in
    the session scratchpad only.
  - **Owner's soak (2026-09-05, real use, hands on).** Reported working:
    mute/unmute; expanding the source list and the amp list; no amp
    selected and a real amp selected; several sources (Roon Ready,
    Spotify, Optical 1); power on/off and the powering-on state; the
    settings gear still opens the ConfigDialog; a range of volumes; the
    hover tooltip shows on hover and stays away while the flyout is
    expanded; the volume OSD shows on volume change whether or not the
    flyout is open. Closes two of the "not done" items above:
    - Physical edge drag: the pointer no longer turns into a resize
      cursor at the flyout's edges/corners at all — "genuinely not
      resizable", and the owner notes the old cursor-change-without-
      resize was itself a confusing bit of UI. Mechanism, from
      `dialog.cpp`: `updateMouseCursor()` only sets the resize cursors
      for edges in `resizableEdges`, and `updateResizableEdges()`
      yields none when `appletInterface` is unset or min == max — both
      true here — whereas `AppletPopup` ran its own edge gesture with
      its own cursor. So not setting `appletInterface` fixed the cursor
      as a side effect; worth keeping in mind if anyone is ever tempted
      to set it "for persistence".
    - Real-pointer hover: exercised by the owner by hand; the tooltip
      appears. The owner explicitly does not want a scripted real-
      pointer test (no `.desktop` fake-input grant) — a manual soak as
      an actual user is the accepted evidence for pointer-driven
      behaviour from here on. Whether the hover tooltip rendered fully
      in place (the Bugs-section clip) was not stated either way; the
      Bugs entry stays open until the owner says so.

- [x] **Phase 7.11.0 — Full re-verification pass.** Depends on 7.10.0.
      Done 2026-09-05 — full-suite gate for the Dialog rebuild, same
      discipline as Phase 7.7.0.
  - **Precondition**: popup size keys confirmed absent for real before
    starting — `kwriteconfig6 --delete` on both keys, then a fresh
    `plasmashell --replace`, then grepped the config file directly (not
    just trusted the delete command's own exit code, per this project's
    own "verify absence after a restart, never compare values" rule) —
    `[Containments][46][Applets][128][Configuration]` had no
    `popupWidth`/`popupHeight` keys at all, only its `ConfigDialog`/
    `General`/`Shortcuts` subgroups. Reconfirmed absent again after the
    full run below.
  - **Environment incident, corrected by the project owner — recorded
    here because it was misdiagnosed in the moment.** The first full
    run aborted at state 237/438 when `spectacle` returned a fully
    transparent capture 3 times in a row (exceeding the bounded retry
    from Phase 7.7.0); a second attempt failed immediately on the very
    first capture. In the moment this was investigated as a KWin
    render-pipeline fault — `-a`/active-window capture still worked
    while `-f`/full-screen capture didn't, and
    `busctl --user call org.kde.KWin /Compositor org.kde.kwin.Compositing
    reinitialize` did make full-screen capture start working again,
    which read as confirmation of that theory. **The owner corrected
    this directly: it was the screensaver activating during the long
    hands-off run, not a compositor bug** — this had already happened
    on a prior session's long run, and the expectation coming in was
    that it would be prevented this time, not re-diagnosed as something
    else. `reinitialize` incidentally cleared the symptom but was never
    the actual cause. Fix applied: `qdbus6 org.freedesktop.ScreenSaver
    /ScreenSaver org.freedesktop.ScreenSaver.Inhibit` alone does not
    durably hold (a one-shot CLI call disconnects immediately, and the
    inhibit is tied to the caller's live bus connection), so a
    background loop calling `.SimulateUserActivity` every 60s was run
    for the remainder of the session; the third full run then completed
    all 438 states with no interruption. The loop was stopped once
    testing finished. Saved as a standing memory
    (`inhibit-screensaver-before-long-runs`) so any future long
    hands-off run on this box inhibits the screensaver *before*
    starting, unconditionally, rather than waiting to see if it
    interrupts the run.
  - **The genuinely clean full pass**
    (`run --set full --noise-mask --label phase7.11.0-full-take3`,
    `runs/20260905-144008-phase7.11.0-full-take3`, real amp state via
    `fakeamp`, screensaver inhibited for the duration): 438 states, 876
    captures parsed, 2409 single-dimension pairs. `report --expected
    expected-7.6.0.json` → **exit 0**.
    - `control_unstable: False` — every control-pair coordinate set
      identical across all 438 states; 0 states with coordinate diffs.
    - `size_mismatch: False`, 0 mismatches — **the h == ih / w == iw
      popup-geometry assertion (added in 7.7.0 after it caught a real
      silent-clipping bug in 7.6.0) holds cleanly under `Dialog`
      specifically**, a different window class than what it was
      originally built against: one geometry row across the entire
      cross product, `{"win": [300, 373], "mainItem": [300, 373, 300,
      373]}` — window size equals mainItem's actual size equals
      mainItem's own implicit size, simultaneously, in every state.
      (The pre-rebuild `AppletPopup` baseline was `win 316×388 /
      mainItem 300×373` — `Dialog` carries no extra frame margin, as
      expected from 7.9.0/7.10.0's own findings.)
    - `unexpected_moves: 0` against `expected-7.6.0.json`. `allowed_moves:
      32819` — the exact same count 7.10.0's own full run reported,
      i.e. the established allowlist categories (`AmpHeader`,
      `VolumeBlock`, `ActionRow`, `overlay`/`ampOption:<ip>`, `Source
      Selector`, `footer`, `powerSpinner`) still fully account for
      every move with nothing foreign sneaking through. `warnings: []`.
    - Control-pair pixel noise: 144/438 states nonzero, and **100% of
      those are `pow=Booting` states** (spinner rotation + amp-dot
      pulse) — 0 non-Booting states show any control-pair pixel
      difference. Same pattern 7.7.0's full pass established; still
      holds under `Dialog`.
  - **`Overlay.overlay` walk — reconfirmed at full scale, not just the
    smoke sample (task item 2).** Computed item counts per
    amp/list-state combination across all 438 states directly from the
    run's `coords/*.json`: `list=closed` is always exactly 74 items
    regardless of amp/vol/mute/pow/src state (the overlay never leaks
    into the closed count); `list=open` is exactly 115 items for 0 or 1
    known amps and exactly 123 for 2 known amps (one amp row ≈ 8 extra
    items) — zero variance within any category across the full vol ×
    mute × pow × src cross product. This is the smoke run's "115 vs 74"
    finding, now confirmed to generalize exactly rather than assumed to.
  - **Real transparency — measured across the full state set (task item
    4), not a single screenshot.** Built a full-scale version of
    7.10.0's same-patch blend check: cropped the run's own
    `_closed_full.png` (captured once, before any state changes) to the
    same box used for every state's screenshot, giving a wallpaper
    reference in the exact same coordinate frame as every shot. Used
    `Theme.qml`'s actual `panelGradientTop`/`panelGradientBottom` (alpha
    0.82 — confirmed this is what `FlyoutContent.qml`'s root tint
    Rectangle uses) to build a per-row predicted-transparent image
    (`0.82×tint + 0.18×wallpaper`) and a predicted-opaque image
    (`tint` alone), then derived a discriminating pixel mask directly
    from the data (wallpaper differs from flat tint by >30 on some
    channel — 89% of the panel's pixels, i.e. real desktop content is
    visible through most of the panel, not just one convenient corner)
    and compared every one of the 438 shots against both hypotheses
    inside that mask:
    - predicted-**transparent** mean abs error: 6.37 (max 7.46, min
      3.19)
    - predicted-**opaque** mean abs error: 11.38 (max 12.89, min 8.93)
    - **the transparent hypothesis fit better in 438/438 states — no
      exceptions.** (Absolute error values run higher than 7.10.0's own
      single-patch figures of 0.35/7.08 because this mask deliberately
      covers text/control pixels too, which neither hypothesis models —
      the discriminating signal is the consistent, large, universal gap
      between the two hypotheses, not the absolute numbers.)
    - Directly inspected two representative screenshots (the base
      not-connected `closed` state, and a `Booting`+`list=open`+long
      source-name state — chosen for maximum visual difference from
      each other) — both show the same real window-shaped wallpaper
      artifact bleeding through the top-right of the panel, confirming
      this isn't one lucky capture.
  - **Live pointer-triggered side-by-side against
    `VolumeHoverTooltip.qml`/`VolumeToast.qml` — closed by the owner's
    own soak (2026-09-05), not scriptable from this session.**
    `VolumeToast` only fires from a genuine scroll/click on the panel
    icon (`CompactRepresentation.qml`'s `stepVolume()`/`toggleMute()`),
    needing real pointer input this session couldn't inject (matching
    the same real-pointer-needs-a-human precedent as the hover tooltip
    in Phase 7.10.0's own soak note above — a synthetic-wheel-event
    driver for this one comparison would have been new scripted-input
    scaffolding the project has deliberately avoided elsewhere). The
    owner instead did the real scroll and screenshotted both the
    tooltip and the toast live, side by side, both showing "Devialet
    Expert 140 Pro / Optical 1 / -28.0 dB" simultaneously. Sampled the
    screenshot's own pixels directly rather than taking the look on
    faith: the toast panel carries a pixel at `(181,129,88)` — a warm
    skin tone from the wallpaper's foreground character bleeding
    straight through the dark tint, impossible under opaque paint — and
    the tooltip shows the same effect at lower magnitude (~23% of a
    sampled region measurably pulled off its flat base tint by the room
    behind it), consistent with its own higher, deliberate alpha (0.94
    vs the flyout/toast's 0.82, per `Theme.qml` — see below). Confirms
    in code and now live: all three (`FlyoutPopup.qml`,
    `VolumeToast.qml`, `VolumeHoverTooltip.qml`) build on the identical
    `PlasmaCore.Dialog` + `NoBackground` mechanism confirmed in
    `dialog.cpp`; the only difference is tint alpha
    (`panelGradientTop`/`Bottom` @ 0.82 for the flyout vs.
    `osdGradientTop`/`Bottom` @ 0.94 for the toast/tooltip — a
    deliberate, pre-existing difference documented in `Theme.qml`, not
    a discrepancy to reconcile). The full-scale blend analysis above
    used that exact 0.82 value and this live capture is independent
    confirmation it holds on the real flyout, not just in the harness.
  - **Scripted checks are not a substitute for a real soak (task item
    6) — stating this plainly, not treating the harness pass as
    sufficient on its own.** Phase 7.8.0's own precedent already proved
    this: its scripted verification passed clean, and it was still a
    real, hands-on usage session that caught the mute/OSD bug 7.8.0's
    own harness run never exercised. Everything in this entry is
    coordinate/pixel-level and D-Bus-driven; it cannot observe real
    cursor behavior, real hover timing, or a human's subjective read of
    "does this actually look transparent to me" the way the owner's own
    eyes can. **A real soak period under normal use is still required
    before this phase is treated as fully closed**, matching Phase
    7.8.0's own precedent and the explicit instruction for this phase.
    The `VolumeToast`/`VolumeHoverTooltip` side-by-side above is now
    closed by the owner's own capture; still outstanding is a general
    "does the flyout look and feel right day-to-day" pass now that it's
    a different window class than the AppletPopup-based flyout users
    have been living with since Phase 7.8.0.

- [x] **Phase 7.12.0 — Darkly corner-radius mismatch fix.** Depends on
      7.11.0 verified solid. Done 2026-09-05 — closed as "problem
      disappeared on its own," exactly the outcome this entry's own
      pre-implementation note flagged as the thing to check for first.
  - Verified live, not assumed: the project owner opened the real
    flyout against a solid dark background (a maximized Dolphin window
    behind it) — the exact condition CLAUDE.md's original seam writeup
    named as where the artifact was visible — and reported no corner
    artifacts at all. Independently re-verified rather than taking the
    screenshot at face value: found the flyout's actual pixel bounding
    box via a raw horizontal/vertical pixel scan (x≈1634-1943,
    y≈39-425 in the supplied screenshot — the flyout tint (~18-20) and
    Dolphin's own dark background (~12) are close enough in value that
    the edge isn't obvious by eye, which if anything makes this a
    *stricter* low-contrast test than a typical dark wallpaper), then
    cropped and zoomed all four corners 12x with nearest-neighbor
    scaling. Every corner shows one single, smooth anti-aliased curve —
    no double-border, no second offset curve, no box-within-box
    artifact at any of the four corners.
  - **Root cause confirmed exactly as this entry's own pre-
    implementation note hypothesized**: `backgroundHints: NoBackground`
    clears Darkly's real frame SVG entirely
    (`dialogBackground->setImagePath(QString())`, `dialog.cpp`), which
    was the *other* curve in the original mismatch (our tint
    Rectangle's true circular arc vs Darkly's frame SVG's cubic-Bezier
    corner underneath it, per CLAUDE.md's original writeup). With that
    second curve gone entirely under `Dialog` + `NoBackground`, there is
    nothing left underneath for our own corner radius to seam against —
    confirmed empirically above, not just reasoned from the header.
  - **No code change made or needed.** The setting/toggle investigation
    this entry originally scoped (bypassing Darkly's corner adaptation
    for users who keep the theme) is now moot — there's no seam left to
    design a bypass for. CLAUDE.md's "Known issues" section still
    describes the seam as an accepted trade-off from the pre-Dialog
    (`AppletPopup`) era; flagged as needing its own follow-up
    correction note (matching the doc's own precedent for this kind of
    "a later phase closed this" update) but not edited as part of this
    TODO-only pass — scoped to TODO.md per the project owner's explicit
    request.

- [x] **Phase 7.13.0 — Cleanup.** Depends on 7.12.0. Done 2026-09-05 —
      final phase of the whole Phase 7.0.0-7.13.0 flyout rebuild; see
      this entry's own closing summary below for the full arc.
  - **Grepped the whole repo first**, per this phase's own instruction,
    before deleting anything. `AppletPopupSpike.qml` was already gone
    (renamed into `FlyoutPopup.qml` back in 7.1.0). Confirmed still
    present and safe to delete: `DialogSpike.qml`, `DialogSpikeDriver.qml`
    (only ever loaded by each other/`CompactRepresentation.qml`), and
    `tools/dialog-spike/` (`kwin-geom.js`, `kwin-activate.js`,
    `spike.py`, referenced nowhere else). `FullRepresentation.qml`'s many
    cross-file mentions (`VolumeBlock.qml`, `PendingAmpState.qml`,
    `Theme.qml`, `SourceSelector.qml`, `FlyoutContent.qml`,
    `ActionRow.qml`, `Footer.qml`, `AmpHeader.qml`, `AmpListOverlay.qml`,
    `ConfigGeneral.qml`) are all historical "ported/extracted from"
    attribution comments, not live dependencies — checked each one
    individually, none touched (this project already keeps this kind of
    comment for other deleted files, e.g. `AppletPopupSpike.qml, now
    removed`). Deleted: `FullRepresentation.qml`, `DialogSpike.qml`,
    `DialogSpikeDriver.qml`, `tools/dialog-spike/` entire.
  - **`CompactRepresentation.qml` cleanup**: removed the dead
    `appletPopupSpikeEnabled`/`dialogSpikeEnabled` properties, the
    `DialogSpike { … }` instantiation, `onClicked`'s dead
    `dialogSpikeEnabled` branch (now an unconditional
    `flyoutPopup.visible = !flyoutPopup.visible`), and every
    `!root.plasmoidItem.expanded` check (`onEntered`, `hoverShowTimer.
    onTriggered`, and a whole `Connections { onExpandedChanged }` block)
    — see the investigation below for why removing these was safe here.
  - **Investigated rather than assumed (task's explicit instruction) —
    and it caught a real, reproducible regression the initial attempt
    missed.** Read libplasma's real source (`plasmoiditem.cpp`, fetched
    from invent.kde.org) to answer whether deleting `main.qml`'s
    `fullRepresentation:` binding actually neutralizes the shell's
    auto-generated per-applet "Activate Devialet Remote Widget" global
    shortcut: confirmed `PlasmoidItem` unconditionally connects
    `Applet::activated` to `setExpanded(true)` on first activation, with
    no check for a full representation existing and no property that
    suppresses it — so `expanded` can still flip `true` via that
    shortcut (or Enter/Space/accessibility activation on the panel
    icon) regardless. Reading `CompactApplet.qml`'s own QML (its popup
    Dialog and Layout hints all null-check `root.fullRepresentation`
    gracefully) suggested simply omitting `fullRepresentation:` entirely
    was therefore safe.
    - **That reasoning was wrong, and the first attempt (deleting the
      binding outright) shipped it anyway.** Live verification (fresh
      `kpackagetool6 --upgrade` + `plasmashell --replace`, harness
      `--set smoke`) showed a probe timeout with zero `[FlyoutProbe]`
      lines ever logged — and the project owner caught the real,
      visible symptom directly: **the panel icon had disappeared
      entirely**, confirmed via their own screenshot. No QML error was
      ever logged anywhere (checked exhaustively — `journalctl`,
      `plasmawindowed`, `qmllint`), which is what made this genuinely
      easy to miss without that live check.
    - **Root-caused, not patched around**: something requires a truthy
      `fullRepresentation` for the compact representation to render at
      all — confirmed by direct bisection (restoring
      `fullRepresentation: Item {}` alone, with no other change, brought
      the icon back immediately, verified live by the owner). The exact
      C++-side mechanism wasn't chased further (out of scope for this
      cleanup), but the empirical fact is now documented in `main.qml`'s
      own comment for whoever next touches this.
    - **Fix**: `main.qml` keeps `fullRepresentation: Item {}` — a
      trivial placeholder, not a reintroduction of the deleted file's
      actual content. Documented residual trade-off, deliberately left
      unhandled: with a truthy `fullRepresentation` restored, the
      obscure global shortcut above *can* now make the shell's own
      popup Dialog visible (an empty box sized by its generic Kirigami
      fallback, not the real flyout) — but this needs a shortcut nobody
      binds by default, auto-dismisses on any click elsewhere or Escape
      (`hideOnWindowDeactivate`'s own default plus `CompactApplet.qml`'s
      `Keys.onEscapePressed`), and never conflicts with the real flyout
      or hover tooltip (both driven by `flyoutPopup.visible`, not
      `expanded`, after this phase's cleanup of `CompactRepresentation.
      qml`). An inherent constraint of the compact/full representation
      model for any applet with no meaningful full representation, not
      a regression this cleanup introduced.
  - **Re-verified clean after the fix**: fresh `kpackagetool6 --upgrade`
    + `plasmashell --replace`; popup size keys confirmed absent both
    before and after (`[Containments][46][Applets][128][Configuration]`
    has only its `ConfigDialog`/`General`/`Shortcuts` subgroups); the
    real daemon active after teardown; harness `--set smoke` — 7/7
    states, counts matching the established 74 (closed) / 115 (open)
    pattern exactly, `report --expected expected-7.6.0.json` → **exit
    0**. The owner independently confirmed the icon visible and the
    flyout opening/working live (screenshot: real amp connected,
    volume/mute/power/source all functioning, transparency intact).
  - **`tools/flyout-harness/harness.py`**: one stale string fixed in
    passing (a `ProbeTimeout` hint referencing `appletPopupSpikeEnabled`,
    a property that no longer exists anywhere after this phase) — not
    itself spike scaffolding, just a troubleshooting message that would
    have actively misled a future debugging session.
  - **Closing summary — the full Phase 7.0.0-7.13.0 arc, for anyone
    reading this later.** The flyout started this arc hosted in the
    shell-managed `PlasmaQuick::AppletPopup`/`PlasmaWindow` (the same
    class the original, pre-rebuild flyout always used), which has no
    `NoBackground` value at all — genuine desktop transparency was
    structurally impossible in that class, full stop. Phases 7.0.0-7.8.0
    built a complete, hand-rolled replacement flyout (own popup shell,
    amp header, volume block, action row, source selector, footer, amp
    list overlay) *inside that same constrained class*, reasoning at the
    time that it was "the exact class already producing today's
    flyout." That was a real mid-course mistake, not a footnote: 7.8.0's
    own cutover shipped and soak-tested clean, and the miss was only
    caught afterward when the project owner directly compared a live
    screenshot of the new flyout against `VolumeToast.qml`/
    `VolumeHoverTooltip.qml`'s already-transparent look and noticed the
    new flyout was still opaque. Phase 7.9.0 corrected course with a
    real investigation (a `PlasmaCore.Dialog` + `Overlay.overlay` spike,
    not a leap to implementation), Phase 7.10.0 rebuilt the flyout on
    that class and measured real, live transparency for the first time,
    Phase 7.11.0 re-ran the full 438-state verification gate against the
    new window class and confirmed it clean (with its own detour: a
    screensaver interruption first misdiagnosed as a compositor fault,
    corrected by the project owner), Phase 7.12.0 confirmed the
    long-standing Darkly corner-radius seam had disappeared as a
    side effect of `NoBackground` removing the theme's frame SVG
    entirely, and this phase removes the scaffolding and the
    now-truly-dead original `AppletPopup`-era code both the spike and
    the mid-course correction left behind. Net result: the flyout is a
    hand-built `PlasmaCore.Dialog` with real desktop transparency,
    verified clean at full scale, with no leftover spike files, no dead
    `FullRepresentation.qml`, and no lingering flags from either the
    original spike or the corrected one.

## Up next

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

- [ ] **Phase 7.14.0 — Restyle AmpListOverlay/SourceSelector to match
      the updated mockup.** Depends on 7.13.0. Visual polish only, no
      architectural or behavioral changes — both components' existing
      self-contained boundaries (visibility, positioning, dismiss, the
      ampChosen(ip)/open signal contracts) stay exactly as they are.
  - Reference: `Devialet_flyout_mockup_v1.html`, "MOCKUP · POPUP/
    COMBOBOX OVERLAY BEHAVIOR" section — a newer, more polished design
    pass than what Phase 7.3.0 originally implemented against.
  - Both `AmpListOverlay.qml` and `SourceSelector.qml`'s popups should
    read as floating cards inset from the flyout's own edges, with
    visible rounded corners (`Kirigami.Units.cornerRadius`, per the
    existing house rule) — not flush/full-width against the flyout
    container the way they currently render.
  - `AmpListOverlay.qml`: confirm row padding/spacing matches the
    mockup's visual density; selected-amp styling (copper dot/text +
    checkmark) already matches, just needs the card treatment above.
  - `SourceSelector.qml` — the bigger gap: the mockup shows a small
    icon chip per source row (distinct glyphs for Optical/UPnP/Roon
    Ready/AirPlay/Spotify) and copper text + checkmark for the selected
    row, replacing the current flat gray highlight bar and plain text
    rows. This uses `org.kde.plasma.components.ComboBox` (required per
    CLAUDE.md's QTBUG-66446 house rule) — first confirm its
    delegate/popup/background properties actually support this level
    of customization before implementing; report back if there's a
    real constraint rather than assuming it'll just work. Check the
    mockup's HTML for the actual per-source glyphs and whether this
    project has an existing icon convention to match, rather than
    inventing a new one.
  - Verify live across every existing test state (0/1/2+ known amps,
    empty source list, long source/amp names). Pure styling — run the
    Phase 7.2.0 harness's `--vary amp,list` and confirm zero unexpected
    moves outside the overlay prefix, since everything in `mainColumn`
    should stay completely unaffected.
  - Do not touch `AmpHeader.qml`, `VolumeBlock.qml`, `ActionRow.qml`,
    or `FlyoutContent.qml`'s own structure — scoped entirely to the two
    overlay components' internal visual content.
    
- [ ] Phase 8.0.0 — Rust: hard-limit clamp in the shared protocol crate.
  The safety backstop, independent of any UI/mockup work, so this can
  start immediately. Any function in the dependency-free protocol
  library crate that constructs/sends a volume-set command clamps to
  the configured hard limit internally — structural, not a check any
  particular caller (devialet-ctl, the daemon's D-Bus handler, a future
  client) has to remember to apply. Add cargo tests covering: command
  at/above/below the limit, limit unset (unbounded), and the boundary
  value itself. No QML changes this phase.

- [ ] Phase 8.1.0 — Persistence + ConfigDialog settings UI.
  Depends on the updated ConfigDialog mockup. Add soft-limit/hard-limit
  dB fields to the widget's KConfig schema (main.xml, alongside
  whatever Phase 4.3.0's settings page already defines), both unset/
  unbounded by default. Build the actual settings-page UI per the
  mockup. Confirm the daemon can read the persisted hard-limit value
  and pass it into Phase 8.0.0's clamp — this phase is what actually
  wires the Rust safety net to a real, user-set value instead of
  testing it against a hardcoded one.

- [ ] Phase 8.2.0 — QML: slider bounds + soft-limit visual treatment.
  Depends on 8.1.0. The volume slider's max (`to`) becomes the hard
  limit, not a fixed constant — dragging to the end of the track means
  "at the ceiling," never past it. Render the track segment between
  soft and hard limit in a distinct warning color; the numeric dB
  readout picks up the same treatment once in that zone. Purely
  informational, no gesture-gating (per the decision to keep this
  simple for now). Apply to every volume-adjusting surface: the
  flyout's VolumeBlock slider AND the +/- buttons/panel-icon-scroll
  step logic (all three currently share a common step/clamp path per
  Phase 4/5's architecture — confirm this and wire once, not three
  times).

- [ ] Phase 8.3.0 — Immediate clamp on settings change.
  Depends on 8.1.0 (needs the setting to exist) — can be built
  alongside or after 8.2.0. When a newly-set hard limit is below the
  amp's current live volume, the daemon immediately sends a real
  volume-set command dropping the amp to the new limit, rather than
  waiting for the next user-initiated volume change. Verify this
  interacts correctly with Phase 5's pending-command architecture (the
  daemon-initiated drop needs to update PendingAmpState/be reflected in
  the UI the same way a user-initiated change is, not bypass it) and
  with multiple known amps (does changing the setting affect only the
  currently-selected/connected amp, or every known amp regardless of
  connection state? — decide explicitly, don't default silently).

- [ ] Phase 8.4.0 — Full verification pass.
  Depends on 8.0.0-8.3.0. Live-verify: hard limit genuinely
  unbypassable via devialet-ctl direct invocation and via rapid
  scroll/slider-drag bursts (Phase 5.0.2's rapid-repeat concern applies
  here too — confirm several fast steps near the ceiling can't
  overshoot it even transiently); soft-limit visual zone renders
  correctly across the full range including boundary values; settings
  UI round-trips correctly (set, close ConfigDialog, reopen, value
  persisted); immediate-clamp-on-lower-limit fires correctly and is
  visible in flyout/tooltip/OSD simultaneously per Phase 7's
  consistency guarantees; unbounded (unset) behaves identically to
  today's widget with no limits configured at all.

## Bugs

- [ ] **Bug: volume icon on flyout mute button does not update
      depending on mute/unmute state**

- [ ] **Bug: hover tooltip (`VolumeHoverTooltip`'s `PlasmaCore.Dialog`)
      renders almost entirely clipped off the right edge of the
      screen for most trigger paths.** Found incidentally during Phase
      5.0.3's live verification, not previously known. Reproduced via
      plain hover-and-wait (both before and after closing the flyout);
      confirmed genuinely our tooltip and not an unrelated overlay (it
      reliably appears/disappears in sync with hover enter/exit, and
      disappears when the mouse moves away). Contradicts the file's own
      code comment claiming Plasma's default `location`-based
      positioning centers the dialog on `visualParent` - the icon sits
      close to the screen's right edge but with easily enough room
      (~200 logical px) for a centered ~350px-wide tooltip to fit, so
      centering alone shouldn't clip like this. One specific pattern -
      a scroll event firing while the mouse is already hovering -
      consistently rendered it correctly positioned; that pattern was
      relied on for Phase 5.0.3 items 3 and 6's screenshots instead of
      plain hover. Not investigated further and not fixed - this
      dialog's positioning code was not touched by any of Phase
      5.0.0-5.0.2, so this is very likely pre-existing and possibly
      specific to this session's display setup (1920×1080 logical @ 2x
      scale, icon near the panel's right end), not a regression from
      the pending-state architecture work. Worth its own investigation.
  - Phase 7.9.0 data point: shown at the same anchor by setting
    `visible = true` directly (no pointer over the icon), the tooltip
    positioned correctly — (1632,32) 172×98, centred on the icon, in
    both QML's and KWin's geometry — and the Dialog spike never clipped
    across ~15 opens at three sizes, including a 500px-wide window that
    the right-edge clamp placed at x = 1920 − 500. So the `visualParent`
    + `location` maths itself is fine; whatever triggers the clip is
    specific to the real hover path (pointer over the panel icon while
    the tooltip first appears), which no automated check here can
    exercise. Still open.
  - Phase 7.10.0 data point: the real hover *code path* was exercised
    with a synthetic pointer (QtTest `mouseMove` on the panel window →
    `onEntered` → the real 700ms `hoverShowTimer` → `visible = true`),
    21 shows including first-show after a fresh shell and before/after
    flyout cycles: all at (1632,32) 172×98, on screen, KWin agreeing.
    One unscripted real hover during the same run gave the same
    geometry. What has still never been exercised under instrumentation
    is the compositor's own pointer being over the icon (KWin would not
    offer `org_kde_kwin_fake_input` without a `.desktop` grant, which
    needs the owner's OK). Not cleared — narrowed: if it reproduces
    by hand, the difference is on the compositor/pointer-focus side,
    not in `popupPosition()` or the QML trigger chain. See Phase
    7.10.0's results for the details.

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
- [ ] **Unify flyout/OSD/tooltip alpha; revisit once transparency
      toggle + slider is re-scoped (deferred until after Phase 7.x.x).**
      `Theme.qml` currently defines two separate translucency levels:
      `panelGradientTop`/`Bottom` at alpha 0.82 (the flyout) and
      `osdGradientTop`/`Bottom` at alpha 0.94
      (`VolumeHoverTooltip.qml`/`VolumeToast.qml`). The comment
      justifying the split says the flyout would get genuine KWin
      blur-behind to soften a lower alpha, while the OSD/tooltip don't
      get blur and need higher opacity to read cleanly. This is now
      known to be false: Phase 7.9.0/7.10.0 confirmed
      `backgroundHints: NoBackground` disables blur-behind for ALL
      `PlasmaCore.Dialog` instances (`dialog.cpp`, plus live pixel
      analysis showing no blur on the flyout) - the flyout never gets
      blur either, so the stated reason for the split doesn't hold.
  - Separately, 0.82's own origin is suspect: its comment claims it
    came from the design mockup, but the mockup's `.flyout` CSS rule is
    actually fully opaque (`--panel-alpha: 1`) - the claimed source
    doesn't contain this value. Not yet confirmed via `git log`/`git
    blame` whether an earlier mockup revision or commit had a real
    rationale, or whether it was simply invented at implementation time
    and mis-attributed in the comment.
  - Project owner's stated preference: keep the OSD's existing 0.94 as
    the shared default across all three surfaces once unified - this is
    what originally motivated wanting real transparency on the flyout
    at all.
  - When scoped: this should be folded into whatever phase reintroduces
    the transparency toggle/slider (removed pre-Phase-7 when
    transparency was infeasible on the old AppletPopup-based flyout,
    now viable again under `Dialog`), rather than done as a standalone
    fix - the eventual design should probably eliminate
    `panelGradientTop`/`Bottom` as separate constants entirely (have
    the flyout read `osdGradientTop`/`Bottom` directly) so the two
    can't drift apart again, and the toggle/slider's design will
    determine whether that's a single shared control or per-surface.
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
