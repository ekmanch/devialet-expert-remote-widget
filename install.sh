#!/usr/bin/env bash
# Phase 13.0.3 — one-shot installer for devialet-expert-remote-kde.
#
# Run once after cloning (and again after any rebuild - every step is
# idempotent, so re-running on an already-installed system is safe: it
# re-places only binaries that changed, restarts the daemon only if it
# is not already running the current binary, and upgrades the plasmoid
# in place). Sequences the three standalone step scripts in scripts/;
# it contains none of their logic itself:
#
#   [1/3] scripts/install-binaries.sh    cargo build --release, copy
#         devialet-ctl / devialet-chime / devialet-remote-daemon into
#         /usr/local/bin (the only step that needs root - one sudo prompt,
#         and none at all when the installed copies are already current)
#   [2/3] scripts/install-daemon-unit.sh  copy the systemd --user unit,
#         enable it, (re)start only when needed
#   [3/3] scripts/install-plasmoid.sh    kpackagetool6 install or upgrade
#
# Order matters: step 2 hard-depends on the daemon binary from step 1
# (it fails fast with its own message otherwise); step 3 is last because
# the widget only works once the other two are in place, and because
# putting the cargo/sudo step first means the most likely failures (no
# Rust toolchain, wrong password) happen before anything is touched.
#
# Partial failure is a deliberate decision, not `set -e` fallout: on any
# step failing this script stops, names the failed step, lists which
# steps completed and which were skipped, and exits with the failing
# step's number (1/2/3). Nothing is rolled back - each completed step is
# a valid state on its own (binaries alone are inert; the daemon without
# the plasmoid just runs; the plasmoid without the daemon shows "Not
# connected"), and undoing a working daemon because the plasmoid step
# failed would help nobody. Fix the reported cause and re-run.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
STEPS_DIR="${SCRIPT_DIR}/scripts"

STEP_LABELS=(
    "Build and place the Rust binaries in /usr/local/bin"
    "Install and start the daemon's systemd --user unit"
    "Install or upgrade the plasmoid"
)
STEP_SCRIPTS=(
    "install-binaries.sh"
    "install-daemon-unit.sh"
    "install-plasmoid.sh"
)
TOTAL=${#STEP_SCRIPTS[@]}

fail() {
    echo "install.sh: error: $*" >&2
    exit 1
}

# --- preflight: every tool any step needs, before anything is touched ---
missing=()
for tool in cargo cmp install systemctl kpackagetool6 jq; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    fail "missing required tool(s): ${missing[*]} - install them and re-run (nothing has been changed)"
fi
if [ ! -w /usr/local/bin ] && ! command -v sudo >/dev/null 2>&1; then
    fail "/usr/local/bin is not writable and sudo is not available - run as root, or install sudo and re-run (nothing has been changed)"
fi
for s in "${STEP_SCRIPTS[@]}"; do
    [ -x "${STEPS_DIR}/${s}" ] || fail "step script missing or not executable: ${STEPS_DIR}/${s} (is this a complete checkout?)"
done

echo "install.sh: devialet-expert-remote-kde installer - ${TOTAL} steps"
echo

completed=()
for i in "${!STEP_SCRIPTS[@]}"; do
    n=$((i + 1))
    label="${STEP_LABELS[$i]}"
    script="${STEPS_DIR}/${STEP_SCRIPTS[$i]}"

    echo "==> [${n}/${TOTAL}] ${label}"
    if "$script"; then
        echo "✔   [${n}/${TOTAL}] ${label}"
        echo
        completed+=("${n}")
        continue
    fi

    # --- failure report ---
    echo >&2
    echo "✘   [${n}/${TOTAL}] FAILED: ${label}" >&2
    echo "    (scripts/${STEP_SCRIPTS[$i]} exited non-zero - its own error message is printed above)" >&2
    if [ "${#completed[@]}" -eq 0 ]; then
        echo "    completed: none" >&2
    else
        echo "    completed:" >&2
        for c in "${completed[@]}"; do echo "      [${c}/${TOTAL}] ${STEP_LABELS[$((c - 1))]}" >&2; done
    fi
    if [ "$n" -lt "$TOTAL" ]; then
        echo "    skipped:" >&2
        for ((k = n + 1; k <= TOTAL; k++)); do echo "      [${k}/${TOTAL}] ${STEP_LABELS[$((k - 1))]}" >&2; done
    else
        echo "    skipped:   none" >&2
    fi
    echo "    Nothing has been rolled back - the completed steps are valid on their own." >&2
    echo "    Fix the cause reported above, then re-run ./install.sh: every step is" >&2
    echo "    idempotent, so the completed steps become no-ops." >&2
    exit "$n"
done

echo "install.sh: all ${TOTAL} steps done."
echo
echo "  Widget:  add \"Devialet Remote\" to a panel via Add Widgets, if not already there."
echo "  Daemon:  systemctl --user status devialet-remote-daemon.service"
echo "  Note:    if the widget was already on your panel, Plasma keeps the old"
echo "           QML loaded until the shell restarts - run 'plasmashell --replace &'"
echo "           (or log out and back in) to pick up the upgraded plasmoid."
