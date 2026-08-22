# devialet-expert-remote-widget
KDE Plasma widget acting as a remote for the Devialet Expert Pro 140

## Development setup

The plasmoid invokes `devialet-ctl` by bare command name (not by absolute
path), so it must be discoverable on `PATH` in the environment plasmashell
runs in.

Until this project has a proper install step, set this up manually:

    cargo build --release
    ln -sf "$(pwd)/target/release/devialet-ctl" ~/.local/bin/devialet-ctl

`~/.local/bin` is on `PATH` by default on most modern distros (including
CachyOS); if the plasmoid's button doesn't seem to do anything, check that
this directory is actually in your `PATH` and that the symlink exists and
points at a current build.

**Note:** after every `cargo build --release`, the binary at
`target/release/devialet-ctl` is a fresh file — but since this is a
symlink, it re-points automatically. No need to redo the `ln -sf` after
rebuilds, only if you delete/recreate `~/.local/bin/devialet-ctl` itself.

### Daemon autostart (systemd --user unit)

The status-listener daemon (`devialet-remote-daemon`) isn't started for
you — without this step, the widget shows "Not connected" on every login
until you start it by hand.

`systemd/devialet-remote-daemon.service` in this repo has a placeholder
`ExecStart` line — it literally contains the string `@@EXECSTART@@`
instead of a real path, since there's no fixed install location yet (same
"not a real packaging story" caveat as the `devialet-ctl` symlink above,
and the reason this can't just be a hardcoded path checked into the repo:
it has to match wherever *you* cloned this project). **Don't**
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

**Note:** like the `devialet-ctl` symlink, this only needs to be redone if
you move/delete the repo clone (the resolved unit file has the old build's
absolute path baked in) — an ordinary `cargo build --release` alone is
enough to pick up code changes, since `ExecStart` just points at the same
binary path each time.