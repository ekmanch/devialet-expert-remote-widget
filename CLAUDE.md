# CLAUDE.md

## Project

KDE Plasma system tray widget (Plasmoid) for controlling the Devialet Expert
Pro 140 amplifier over UDP. Companion project to an existing Android app and
an in-progress Flutter app for the same amplifier — same protocol, different
platform. Rust + QML, no C++.

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
  `com.ekmanch.DevialetRemote.Amp1`, session bus. Properties: `DeviceName`,
  `AmpIp`, `Online`, `Power`, `Muted`, `VolumeRaw`, `VolumeDb`,
  `ActiveSourceIndex`, `ActiveSourceName`, `Sources` (array of
  `(name, index, enabled, selected)` tuples, always 30 entries).
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
│       └── config/                 # config.qml + main.xml — Plasmoid.configuration
│                                    #   (blur, reduce-motion, scroll-step,
│                                    #   launch-at-login display). Added when a
│                                    #   phase actually needs a settings view.
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