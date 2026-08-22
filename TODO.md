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

## Up next

- [ ] **Phase 3.7 — mDNS amp model name resolution.** Currently the
      widget only ever shows the raw UDP `device_name` (e.g.
      "Expert140Pro"/"My Devialet-ETH"-style names) — there's no attempt
      at mDNS resolution at all yet, so there's no fallback happening
      today, just the one behavior that exists. Add the same
      `modelName ?: udpName` logic the Android app already has (via its
      `AmpModelNameResolver`), daemon-side: resolve each known amp's
      model name over mDNS (e.g. "Expert140Pro" → "Devialet Expert 140
      Pro"), expose it as an additional field on `KnownAmps`, and have
      the primary DeviceName property for the selected amp prefer the
      resolved model name, falling back to the raw UDP name when
      resolution hasn't completed or fails. Daemon-only, no QML changes
      — mirrors Phase 3.5's shape (D-Bus surface addition, no UI yet).
      Investigate the Android resolver's actual mDNS service type and
      name-mapping logic before implementing, don't guess or
      reconstruct it from one example name..
- [ ] **Phase 4 — amp picker, settings view, full mockup styling.**
      Amp picker QML (built against whatever surface Phase 3.5 produces),
      Plasmoid.configuration settings view (blur, reduce motion, scroll
      step, launch-at-login display), copper/graphite theme, Space
      Grotesk/JetBrains Mono fonts, blur/animation, matching
      `devialet_tray_flyout_mockup.html`.
- [ ] **Phase 4.1 - scroll-over-tray-icon volume control.** When the
      mouse is hovering over the system tray icon for the widget, it
      should be possible to scroll using the mouse wheel to change the
      volume up/down depending on if the user is scrolling up or down.
- [ ] **Phase 4.2 - install script + devialet-ctl packaging story.**
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