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

`systemd/devialet-remote-daemon.service` in this repo has a placeholder
`ExecStart` line — it literally contains the string `@@EXECSTART@@`
instead of a real path, since the daemon has no fixed install location
yet (Phase 13.0.2 will move it to `/usr/local/bin` like the two binaries
above, at which point this placeholder goes away; until then it has to
match wherever *you* cloned this project). **Don't**
`systemctl --user link` or copy that file as-is — systemd would try to
exec the literal string `@@EXECSTART@@` and fail. Instead, substitute it
for the absolute path to the release binary you just built, and write the
resolved result to `~/.config/systemd/user/` (where `systemctl --user`
actually looks for user unit files):

    cargo build --release
    sed "s|@@EXECSTART@@|$(pwd)/target/release/devialet-remote-daemon|" \
        systemd/devialet-remote-daemon.service \
        > ~/.config/systemd/user/devialet-remote-daemon.service
    systemctl --user daemon-reload
    systemctl --user enable --now devialet-remote-daemon.service

Check it's actually running:

    systemctl --user status devialet-remote-daemon.service
    busctl --user introspect com.ekmanch.DevialetRemote /com/ekmanch/DevialetRemote/Amp

**Note:** this only needs to be redone if
you move/delete the repo clone (the resolved unit file has the old build's
absolute path baked in) — an ordinary `cargo build --release` alone is
enough to pick up code changes, since `ExecStart` just points at the same
binary path each time.