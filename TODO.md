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

## Up next

- [ ] **Phase 4.1 — Amp picker UI.** Styled from the start using 4.0's
      language. Built against Phase 3.5's existing `KnownAmps` /
      `SelectedAmpIp` / `SelectAmp` D-Bus surface — no persistence yet,
      same as 3.5 left it. Picker has no awareness that persistence
      exists; it just calls `SelectAmp` on user action like it always
      would.
- [ ] **Phase 4.2 — Amp selection persistence (daemon-side).** Deferred
      from 3.5 specifically so it could be verified against a real picker
      UI (select amp A, restart daemon, confirm A reconnected; select amp
      B, restart again, confirm B not A persisted) instead of verified
      blind via busctl — this is why it runs after 4.1, not before.
  - **Ownership decision (settled):** the daemon owns persistence, not
    the widget. Daemon writes to a small config file on
    `SelectAmp(ip)`, reads it back on startup, and does the live
    re-discovery reconciliation (don't blindly trust a stale
    persisted IP) before exposing `SelectedAmpIp`.
  - Reasoning: lifecycle mismatch (daemon is the long-lived,
    systemd-supervised process; the widget/plasmoid reloads far more
    often — panel add/remove, plasmashell restarts — so widget-owned
    persistence would mean re-pushing on every reload plus tie-break
    logic against whatever the daemon already auto-selected); the
    live-reconciliation step needs daemon-side discovery state anyway,
    so splitting storage into the widget while reconciliation stays
    in the daemon just fragments one piece of logic across two
    processes; matches the existing pattern of `SelectedAmpIp`/
    `KnownAmps` already being daemon-owned properties the widget reads
    and reflects, not values it maintains and pushes.
- [ ] **Phase 4.3 — Settings view.** Styled from the start, built last
      since it hangs off the settings-trigger (gear icon) on an
      already-stable, already-styled main view.
  - **Settled split (two kinds of state, not one):** *Blur background*,
    *Reduce motion*, *Volume step per scroll notch* are pure UI/widget
    preferences, stored in `plasmoid.configuration` (KConfig).
    *Launch at login* is not an independently-stored preference — it's
    a live reflection of `systemctl --user is-enabled` for the Phase
    3.6 systemd unit. Toggling it enables/disables the unit directly
    rather than setting a KConfig bool that could drift out of sync
    with actual systemd state.
  - Given the two different state models, likely drafted as two
    sub-prompts (KConfig-backed toggles vs. the systemd-state row)
    rather than one.
- [ ] **Phase 4.4 - scroll-over-panel-icon volume control.** When the
      mouse is hovering over the widget's panel icon, it should be
      possible to scroll using the mouse wheel to change the volume
      up/down depending on if the user is scrolling up or down. (Renamed
      from "scroll-over-tray-icon" - this widget is panel-pinned, not
      tray-hosted, see the architecture-change entry above. Scope itself
      is unchanged, not started here.)
- [ ] **Phase 4.5 - install script + devialet-ctl packaging story.**
      Bash install script (.sh) so a user can clone the repo, run it, and
      have the widget fully installed and usable — this necessarily
      includes deciding how devialet-ctl gets placed somewhere on PATH
      (currently a manual `~/.local/bin` symlink per README, fine for
      dev but not a real install path), alongside installing the
      plasmoid itself and the Phase 3.6 systemd unit. Treat this as one
      combined install story rather than a separate CLI-only packaging
      step, since the script would need to solve both anyway.

## Not yet scoped / parked



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
