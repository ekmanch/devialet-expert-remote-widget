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