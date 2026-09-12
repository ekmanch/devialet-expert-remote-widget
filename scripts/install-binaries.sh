#!/usr/bin/env bash
# Phase 13.0.3 — idempotent build + placement wrapper for the three Rust
# binaries: devialet-ctl, devialet-chime (both invoked by the plasmoid by
# bare name through plasmashell's executable engine) and
# devialet-remote-daemon (run by the systemd --user unit via a bare
# ExecStart). All three go to /usr/local/bin as copies, release profile -
# the Phase 13.0.0 decision, see CLAUDE.md's "Install location" bullet for
# why that path and not ~/.local/bin or ~/.cargo/bin.
#
# Standalone and idempotent like install-plasmoid.sh / install-daemon-
# unit.sh; install.sh sequences it as step 1 of 3. Safe to run alone after
# a rebuild.
#
# Idempotency: after `cargo build --release --locked`, each built binary is
# compared byte-for-byte (`cmp`) with the installed copy. If all three are
# identical the script says so and exits 0 WITHOUT invoking sudo - a
# genuine no-op re-run must not ask for a password. Only the binaries
# that differ are (re)placed.
#
# Root: /usr/local/bin is root-owned, so `install` runs under sudo unless
# the destination directory is already writable by the current user (a
# root shell, or a writable prefix). This is the only step in this
# project's setup that needs root.
#
# Interaction with the running daemon (measured in Phase 13.0.3): GNU
# `install` unlinks the destination before writing, so a running
# devialet-remote-daemon keeps executing its old, now-deleted inode.
# install-daemon-unit.sh then sees `/proc/<pid>/exe` -> "... (deleted)",
# which is not the canonical path, and restarts the unit - so a rebuilt
# daemon gets restarted and an unchanged one (skipped here by `cmp`) is
# left alone. Run install-daemon-unit.sh after this script (install.sh
# does) whenever the daemon binary changed.
#
# CARGO_TARGET_DIR is honoured: cargo writes there when it is set, so this
# script reads the built binaries from the same place.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
TARGET_DIR="${CARGO_TARGET_DIR:-${REPO_DIR}/target}"
DEST_DIR="/usr/local/bin"
BINARIES=(devialet-ctl devialet-chime devialet-remote-daemon)

die() {
    echo "install-binaries: error: $*" >&2
    exit 1
}

command -v cargo >/dev/null 2>&1 || die "cargo not found on PATH (Rust toolchain required: pacman -S rust, or rustup)"
command -v cmp >/dev/null 2>&1 || die "cmp not found on PATH (diffutils)"
command -v install >/dev/null 2>&1 || die "install not found on PATH (coreutils)"
[ -f "${REPO_DIR}/Cargo.toml" ] || die "Cargo.toml not found in ${REPO_DIR} - this script must live in <repo>/scripts/"

echo "install-binaries: building release binaries (${BINARIES[*]})..."
build_args=()
for b in "${BINARIES[@]}"; do build_args+=(-p "$b"); done
(cd "$REPO_DIR" && cargo build --release --locked "${build_args[@]}") \
    || die "cargo build --release --locked failed - see the cargo output above"

changed=()
for b in "${BINARIES[@]}"; do
    built="${TARGET_DIR}/release/${b}"
    [ -x "$built" ] || die "expected build output missing: $built"
    if [ -f "${DEST_DIR}/${b}" ] && cmp -s "$built" "${DEST_DIR}/${b}"; then
        echo "install-binaries: ${DEST_DIR}/${b} already up to date"
    else
        changed+=("$built")
    fi
done

if [ "${#changed[@]}" -eq 0 ]; then
    echo "install-binaries: done, all ${#BINARIES[@]} binaries already installed and up to date, nothing to copy."
    exit 0
fi

SUDO=""
if [ ! -w "$DEST_DIR" ]; then
    command -v sudo >/dev/null 2>&1 || die "${DEST_DIR} is not writable and sudo is not available - run as root or install manually: install -Dm0755 -t ${DEST_DIR} ${changed[*]}"
    SUDO="sudo"
    echo "install-binaries: ${DEST_DIR} needs root - sudo will prompt for your password."
fi

echo "install-binaries: installing $(printf '%s ' "${changed[@]##*/}")-> ${DEST_DIR}"
$SUDO install -Dm0755 -t "$DEST_DIR" "${changed[@]}" \
    || die "install into ${DEST_DIR} failed (sudo denied or filesystem error) - nothing else was changed; re-run this script to retry"

# Confirm the end state actually landed - don't trust the exit code alone.
for b in "${BINARIES[@]}"; do
    cmp -s "${TARGET_DIR}/release/${b}" "${DEST_DIR}/${b}" \
        || die "${DEST_DIR}/${b} does not match the freshly built binary after install"
done

echo "install-binaries: done, (re)placed ${#changed[@]} of ${#BINARIES[@]} binaries in ${DEST_DIR}; all ${#BINARIES[@]} verified identical to the build."
