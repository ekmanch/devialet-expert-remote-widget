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