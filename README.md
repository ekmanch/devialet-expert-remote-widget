# devialet-expert-remote-widget
KDE Plasma widget acting as a remote for the Devialet Expert Pro 140

## Development setup

The plasmoid invokes `devialet-ctl` (commands) and `devialet-chime`
(volume-change chime) by bare command name (not by absolute path), so
both must be discoverable on `PATH` in the environment plasmashell runs
in. The install location is `/usr/local/bin` (Phase 13.0.0 decision, see
CLAUDE.md's "Install location" note for the reasoning): it is on every
default `PATH` on Arch and derivatives (`/etc/profile`, `/etc/login.defs`,
SDDM's `DefaultPath`, systemd's own search path), which `~/.local/bin` is
not - that directory only reaches plasmashell's `PATH` if your login shell
happens to add it.

Build both binaries in release profile and copy them in (the `install`
step is the only part of this project's setup that needs root):

    cargo build --release --locked -p devialet-ctl -p devialet-chime
    sudo install -Dm0755 -t /usr/local/bin \
        target/release/devialet-ctl target/release/devialet-chime

Check from a shell with no user `PATH` additions:

    env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/bin devialet-ctl --help

**Note:** these are copies, not symlinks into `target/` - they keep
working after `cargo clean`, but a rebuild does not update them. Re-run
the `install` line after any `cargo build` that changes either binary.
If you previously followed the old instructions and have
`~/.local/bin/devialet-ctl` / `~/.local/bin/devialet-chime` symlinks,
delete them: `~/.local/bin` precedes `/usr/local/bin` on `PATH`, so a
stale symlink there shadows the installed copy.

### Daemon autostart (systemd --user unit)

The status-listener daemon (`devialet-remote-daemon`) isn't started for
you — without this step, the widget shows "Not connected" on every login
until you start it by hand.

`systemd/devialet-remote-daemon.service` in this repo now has a plain
bare `ExecStart=devialet-remote-daemon` (Phase 13.0.2) — no per-clone
path substitution needed, since the daemon binary is built in release
profile and copied to `/usr/local/bin`, on systemd's own unit search
path for a non-absolute `ExecStart`, exactly like `devialet-ctl`/
`devialet-chime` (Phase 13.0.0). Build and place it, then install the
unit with `scripts/install-daemon-unit.sh`, which is idempotent — safe
to re-run after every rebuild, and safe to run on a system where an
older, differently-pointed version of this unit is already active (it
detects the mismatch and restarts to pick up the current binary):

    cargo build --release --locked -p devialet-remote-daemon
    sudo install -Dm0755 -t /usr/local/bin target/release/devialet-remote-daemon
    scripts/install-daemon-unit.sh

Check it's actually running:

    systemctl --user status devialet-remote-daemon.service
    busctl --user introspect com.ekmanch.DevialetRemote /com/ekmanch/DevialetRemote/Amp

**Note:** re-run all three commands after any `cargo build` that changes
the daemon — the installed binary is a copy, not a symlink, so it
doesn't update itself, and `install-daemon-unit.sh` only restarts the
service when it detects the running process doesn't match the current
binary (a genuine no-op re-run leaves the daemon running undisturbed).