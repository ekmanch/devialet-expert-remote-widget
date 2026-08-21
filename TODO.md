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

## Up next

- [ ] **Phase 3 — full functional controls, default styling.** *(In
      progress - implemented and self-verified where possible; real-click
      confirmation in the actual tray still needed, see below.)*
      Volume slider + step buttons, mute toggle, power toggle, source
      picker — all bound to real D-Bus properties. No copper/graphite
      theming, no amp picker, no settings view yet.
  - Debounce ported directly from MainActivity.kt (verified against that
    source this phase, not reconstructed from memory): button steps use a
    sliding 400ms window (each step resets the timer); the slider only
    sends + stamps its timestamp once, on release; a separate
    `volumeInteracting` flag blocks all incoming volume pushes for the
    whole duration of an active drag or button-hold, independent of the
    timestamps. Mute/Power/Source get a single-shot 400ms window too (not
    in the Kotlin app, but explicitly requested this phase for
    consistency - flagged as a deliberate addition, not silent parity
    drift).
  - Volume range: -15dB ceiling is code-enforced (`MAX_VOLUME_DB` in the
    protocol crate); -60dB floor is a UI convention only (matches the
    Kotlin app's own slider bounds) - **not** enforced anywhere in Rust.
  - Confirmed by reading devialet-ctl's source: the forced -40dB
    post-source-switch volume is already handled inside `devialet-ctl
    source`, not something QML needs to send separately.
  - Self-verified via direct `devialet-ctl`/`busctl` calls against the
    real amp (source switch + forced -40dB, -15dB ceiling clamping a -5dB
    request): confirmed working, independent of the QML UI.
  - Found and fixed via `plasmawindowed` testing: a ComboBox hosted inside
    `PlasmoidItem`'s fullRepresentation didn't show its selected text
    (same model/data confirmed correct and rendering fine in a plain QML
    window) - root cause not fully chased down, worked around via an
    explicit `displayText` override, which resolved it.
  - **Still needs real-tray, real-click confirmation** (can't automate
    clicks/drags in this environment): slider drag feel + release-only
    send, step-button tap and hold-to-repeat, mute/power toggle round
    trip, source ComboBox selection round trip.
- [ ] **Phase 3.5 — multi-amp daemon support.** Daemon-only work: decide
      and implement how the daemon discovers/tracks more than one amp on
      the network and exposes that on D-Bus (new property? multiple
      objects? something else — not yet decided). No QML changes in this
      phase. Verified via busctl/logs only.
  - **Open question, unresolved:** testability is limited to one physical
    amp right now — need to decide whether this phase is verified against
    real hardware, synthetic/mocked broadcast traffic, or partially
    deferred until a second amp is available. Decide before drafting the
    Phase 3.5 prompt, don't let Claude Code improvise this.
- [ ] **Phase 4 — amp picker, settings view, full mockup styling.**
      Amp picker QML (built against whatever surface Phase 3.5 produces),
      Plasmoid.configuration settings view (blur, reduce motion, scroll
      step, launch-at-login display), copper/graphite theme, Space
      Grotesk/JetBrains Mono fonts, blur/animation, matching
      `devialet_tray_flyout_mockup.html`.

## Not yet scoped / parked

- [ ] **systemd unit — create, enable, and verify.** CLAUDE.md documents
      the decision (`systemd --user`, `Restart=on-failure`) and the repo
      layout reserves `systemd/devialet-remote-daemon.service`, but as far
      as documented so far the daemon has only been run manually during
      testing — the actual unit file, `systemctl --user enable`, and
      crash-recovery behavior haven't been confirmed working yet. Needs
      its own verification pass (kill the daemon, confirm systemd restarts
      it; reboot, confirm autostart).
- [ ] **devialet-ctl install/packaging story.** Currently a manual
      `~/.local/bin` symlink per README — fine for dev, not a real install
      path. Revisit once the widget is closer to shareable (install
      script, Makefile target, or AUR package).
- [ ] **Scroll-over-tray-icon volume control.** Separate MPV Lua script to
      redirect scroll events over active MPV windows to the amp instead of
      MPV's own volume. Independent of the plasmoid itself — not blocked
      on any of the phases above, can happen in parallel whenever.
- [ ] Two deferred Android-repo TODOs (tracked there, not here, but noted
      for awareness since protocol truth is shared): AGP declarative DSL
      migration, targetSdk 34→37 bump with `ACCESS_LOCAL_NETWORK`
      permission.