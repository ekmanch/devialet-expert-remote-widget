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

- [ ] **Phase 3 — full functional controls, default styling.**
      Volume slider + step buttons, mute toggle, power toggle, source
      picker — all bound to real D-Bus properties, all verified against
      the real amp. Debounce pattern applied for locally-initiated
      changes. No copper/graphite theming, no amp picker, no settings
      view yet. *(Prompt drafted, not yet run.)*
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