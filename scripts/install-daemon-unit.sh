#!/usr/bin/env bash
# Phase 13.0.2 — idempotent install/enable wrapper for the daemon's
# systemd --user unit.
#
# Copies systemd/devialet-remote-daemon.service into
# ~/.config/systemd/user/, daemon-reloads, enables it, and makes sure it
# is actually running the current /usr/local/bin/devialet-remote-daemon
# binary - starting it if it isn't running at all, restarting it if it's
# running a stale binary (e.g. this machine's pre-13.0.2 clone-pointed
# instance), and leaving it alone if it's already correct. Meant to be
# called directly or sequenced by the combined install.sh (Phase
# 13.0.3) - this script only handles the unit/service step, nothing
# about the daemon binary's own placement (that's Phase 13.0.0's
# `sudo install -Dm0755 -t /usr/local/bin`, a prerequisite this script
# checks for but does not perform) or the plasmoid (13.0.1).
#
# Why this doesn't just do `daemon-reload && enable --now` and call it
# done (measured live, not assumed from `man systemd.service`):
#   - `enable --now` behaves like `start` for the "already active" case,
#     and `start` on an already-active unit is a no-op - it does NOT
#     pick up a changed `ExecStart=` on disk. Verified with a disposable
#     probe unit: after rewriting ExecStart and running daemon-reload +
#     enable --now, `systemctl show -p ExecStart` immediately reflected
#     the new path (it re-parses the unit file), but the actual running
#     process was untouched - same PID, still executing the old command.
#   - An explicit `systemctl --user restart` is required to pick up a
#     changed ExecStart, and it does a clean sequenced stop-then-start
#     (confirmed via journalctl: "Stopping ... / Stopped ... / Started
#     ..."; the old PID was confirmed dead before the new one appeared).
#     This sequencing is also what makes a live migration on this
#     machine safe: no window where two daemon instances could both be
#     bound to UDP 45454 or racing for the D-Bus name.
#   - `enable` alone is idempotent (exit 0 whether or not already
#     enabled) and `restart` works fine even on a never-started/inactive
#     unit (starts it, exit 0) - so this script always uses `restart`
#     when a (re)start is needed, never `start`, and never has to branch
#     between the two.
#   - Restarting unconditionally on every re-run would still be
#     "no-op-equivalent" end-state-wise, but needlessly bounces the
#     daemon (a few seconds of `Online: false` in the widget) on a
#     genuine no-op re-run. So this script only restarts when the unit
#     is inactive, or when the *actually running* process (resolved via
#     `/proc/<MainPID>/exe`, not `systemctl show -p ExecStart` - which,
#     per the point above, reflects the unit file on disk rather than
#     what the running process was actually launched from) doesn't
#     match the canonical binary path.
#
# Failure modes handled explicitly below, matching install-plasmoid.sh's
# standard: missing systemctl, a missing unit file in the repo, a missing
# daemon binary at /usr/local/bin (this script does not build/place it -
# Phase 13.0.0 owns that), and daemon-reload/enable/restart themselves
# erroring - each exits non-zero with a clear message, never a silent
# no-op or a hang.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
UNIT_SOURCE="${1:-${SCRIPT_DIR}/../systemd/devialet-remote-daemon.service}"
UNIT_NAME="devialet-remote-daemon.service"
UNIT_DEST_DIR="${HOME}/.config/systemd/user"
UNIT_DEST="${UNIT_DEST_DIR}/${UNIT_NAME}"
DAEMON_BIN="/usr/local/bin/devialet-remote-daemon"

die() {
    echo "install-daemon-unit: error: $*" >&2
    exit 1
}

command -v systemctl >/dev/null 2>&1 || die "systemctl not found on PATH"

[ -f "$UNIT_SOURCE" ] || die "unit file not found: $UNIT_SOURCE"

[ -x "$DAEMON_BIN" ] || die "daemon binary not found (or not executable) at $DAEMON_BIN - run Phase 13.0.0's build+install step first (cargo build --release --locked -p devialet-remote-daemon && sudo install -Dm0755 -t /usr/local/bin target/release/devialet-remote-daemon)"

mkdir -p "$UNIT_DEST_DIR" || die "could not create $UNIT_DEST_DIR"

echo "install-daemon-unit: unit source: $UNIT_SOURCE"
echo "install-daemon-unit: installing to: $UNIT_DEST"
cp "$UNIT_SOURCE" "$UNIT_DEST" || die "failed to copy unit file to $UNIT_DEST"

systemctl --user daemon-reload || die "systemctl --user daemon-reload failed"
systemctl --user enable "$UNIT_NAME" || die "systemctl --user enable $UNIT_NAME failed"

CANONICAL_BIN="$(readlink -f "$DAEMON_BIN")"

is_running_canonical_binary() {
    local state
    state="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)"
    [ "$state" = "active" ] || return 1

    local main_pid
    main_pid="$(systemctl --user show "$UNIT_NAME" -p MainPID --value 2>/dev/null || true)"
    [ -n "$main_pid" ] && [ "$main_pid" != "0" ] || return 1

    local running_exe
    running_exe="$(readlink -f "/proc/${main_pid}/exe" 2>/dev/null || true)"
    [ -n "$running_exe" ] || return 1

    [ "$running_exe" = "$CANONICAL_BIN" ]
}

if is_running_canonical_binary; then
    echo "install-daemon-unit: already active and running the current binary, nothing to restart."
else
    echo "install-daemon-unit: (re)starting to pick up the current binary..."
    systemctl --user restart "$UNIT_NAME" || die "systemctl --user restart $UNIT_NAME failed"
fi

# Confirm the end state actually landed - don't trust the exit code alone.
sleep 1
FINAL_STATE="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)"
[ "$FINAL_STATE" = "active" ] || die "unit is not active after install (state: ${FINAL_STATE:-unknown}) - check: journalctl --user -u $UNIT_NAME"

if ! is_running_canonical_binary; then
    die "unit is active but not running $CANONICAL_BIN - check: systemctl --user status $UNIT_NAME"
fi

echo "install-daemon-unit: done, $UNIT_NAME is active and running $CANONICAL_BIN."
