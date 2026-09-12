#!/usr/bin/env bash
# Phase 13.0.4 — uninstaller for devialet-expert-remote-kde: the
# near-mechanical reverse of install.sh's three steps, run in reverse
# order so the one step that needs root comes last (if sudo is declined
# or fails, everything user-level is already gone and a re-run only has
# the binaries left to do).
#
#   [1/3] remove the plasmoid           (reverse of scripts/install-plasmoid.sh)
#   [2/3] stop, disable and delete the  (reverse of scripts/install-daemon-unit.sh)
#         daemon's systemd --user unit
#   [3/3] delete the three binaries     (reverse of scripts/install-binaries.sh;
#         from /usr/local/bin            the only step that needs root)
#
# Step 2 uses `systemctl --user disable --now` - WITH --now, deliberately
# unlike the ConfigDialog's "Launch at login" toggle, which is plain
# `disable` and leaves a running daemon running (Phase 13.0.4's
# investigation confirmed that live). This script's whole point is to
# actually stop the daemon, not just prevent its next autostart.
#
# Idempotent: every step treats "already removed" as a clean no-op and
# says so (`nothing to remove`), so re-running after a complete or
# partial removal - by this script, by hand, or by an interrupted run -
# exits 0. Anything else that fails (kpackagetool6 --remove erroring for
# a reason other than "not installed", systemctl refusing to disable a
# unit that does exist, rm failing) is reported with the failing step
# and exits with that step's number, same format as install.sh. Nothing
# is silently skipped.
#
# Deliberately NOT removed: the daemon's persisted amp selection
# (~/.config/devialet-remote-daemon/) and the widget's own settings in
# Plasma's appletsrc - user data, and Plasma owns the second one. Both
# are named in the closing note so the user can delete them by hand.
# Removing the package also does not remove a widget instance from a
# panel; Plasma keeps a placeholder until the user removes it there.

set -u

UNIT_NAME="devialet-remote-daemon.service"
UNIT_DIR="${HOME}/.config/systemd/user"
UNIT_FILE="${UNIT_DIR}/${UNIT_NAME}"
UNIT_WANTS_LINK="${UNIT_DIR}/plasma-workspace.target.wants/${UNIT_NAME}"
PLUGIN_ID="com.ekmanch.devialetremote"
PACKAGE_TYPE="Plasma/Applet"
BIN_DIR="/usr/local/bin"
BINARIES=(devialet-ctl devialet-chime devialet-remote-daemon)
DAEMON_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/devialet-remote-daemon"

STEP_LABELS=(
    "Remove the plasmoid"
    "Stop, disable and delete the daemon's systemd --user unit"
    "Delete the binaries from ${BIN_DIR}"
)
TOTAL=${#STEP_LABELS[@]}

fail() {
    echo "uninstall.sh: error: $*" >&2
    exit 1
}

# --- preflight ---
missing=()
for tool in systemctl kpackagetool6; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
[ "${#missing[@]}" -eq 0 ] || fail "missing required tool(s): ${missing[*]} (nothing has been changed)"

# ---------------------------------------------------------------------------
# Step bodies. Each returns 0 on success (including "nothing to remove"),
# non-zero after printing its own specific error.
# ---------------------------------------------------------------------------

plasmoid_installed() {
    kpackagetool6 --type "$PACKAGE_TYPE" --list 2>/dev/null | grep -qx -- "$PLUGIN_ID"
}

step_plasmoid() {
    if ! plasmoid_installed; then
        echo "uninstall: plasmoid ${PLUGIN_ID} is not installed, nothing to remove."
        return 0
    fi
    echo "uninstall: removing plasmoid ${PLUGIN_ID}..."
    if ! kpackagetool6 --type "$PACKAGE_TYPE" --remove "$PLUGIN_ID"; then
        echo "uninstall: error: kpackagetool6 --remove ${PLUGIN_ID} failed (it was listed as installed)" >&2
        return 1
    fi
    if plasmoid_installed; then
        echo "uninstall: error: kpackagetool6 reported success but ${PLUGIN_ID} is still in --list" >&2
        return 1
    fi
    echo "uninstall: plasmoid removed."
}

step_daemon_unit() {
    local enabled_state
    enabled_state="$(systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null || true)"
    local did_anything=0

    if [ "$enabled_state" != "not-found" ] && [ -n "$enabled_state" ]; then
        # The unit exists as far as systemd is concerned: stop it AND drop
        # its autostart in one go. --now is what makes this an uninstall
        # rather than the ConfigDialog toggle's disable-only behaviour.
        echo "uninstall: unit is ${enabled_state}, running systemctl --user disable --now ${UNIT_NAME}..."
        if ! systemctl --user disable --now "$UNIT_NAME"; then
            echo "uninstall: error: systemctl --user disable --now ${UNIT_NAME} failed - check: systemctl --user status ${UNIT_NAME}" >&2
            return 1
        fi
        did_anything=1
    else
        echo "uninstall: unit ${UNIT_NAME} is not known to systemd (${enabled_state:-not-found})."
    fi

    # Belt and braces: a manually deleted unit file can leave a dangling
    # wants-symlink behind, and a manually deleted symlink can leave the
    # unit file. Remove whatever is left of either.
    if [ -e "$UNIT_FILE" ] || [ -L "$UNIT_FILE" ]; then
        rm -f -- "$UNIT_FILE" || { echo "uninstall: error: could not delete ${UNIT_FILE}" >&2; return 1; }
        echo "uninstall: deleted ${UNIT_FILE}"
        did_anything=1
    fi
    if [ -e "$UNIT_WANTS_LINK" ] || [ -L "$UNIT_WANTS_LINK" ]; then
        rm -f -- "$UNIT_WANTS_LINK" || { echo "uninstall: error: could not delete ${UNIT_WANTS_LINK}" >&2; return 1; }
        echo "uninstall: deleted leftover ${UNIT_WANTS_LINK}"
        did_anything=1
    fi

    if [ "$did_anything" -eq 0 ]; then
        echo "uninstall: no unit file or autostart link present, nothing to remove."
    fi

    # Always reload so systemd forgets the deleted unit (and clears a
    # possible failed state), even on the nothing-to-do path - cheap and
    # it is what makes the post-check below meaningful.
    systemctl --user daemon-reload || { echo "uninstall: error: systemctl --user daemon-reload failed" >&2; return 1; }
    systemctl --user reset-failed "$UNIT_NAME" 2>/dev/null || true

    # Post-check: TODO's bar is "the unit is gone entirely, not just
    # disabled" - is-enabled must say not-found, and nothing may be
    # running.
    local after_enabled after_active
    after_enabled="$(systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null || true)"
    after_active="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)"
    if [ "$after_enabled" != "not-found" ]; then
        echo "uninstall: error: ${UNIT_NAME} still reports is-enabled='${after_enabled}' after removal (expected not-found) - a copy may exist elsewhere: systemctl --user show ${UNIT_NAME} -p FragmentPath" >&2
        return 1
    fi
    if [ "$after_active" = "active" ] || [ "$after_active" = "activating" ]; then
        echo "uninstall: error: ${UNIT_NAME} is still ${after_active} after disable --now" >&2
        return 1
    fi
    echo "uninstall: unit gone (is-enabled: ${after_enabled}, is-active: ${after_active})."
}

step_binaries() {
    local present=()
    local b
    for b in "${BINARIES[@]}"; do
        [ -e "${BIN_DIR}/${b}" ] && present+=("${BIN_DIR}/${b}")
    done
    if [ "${#present[@]}" -eq 0 ]; then
        echo "uninstall: none of ${BINARIES[*]} present in ${BIN_DIR}, nothing to remove."
        return 0
    fi

    local sudo_cmd=""
    if [ ! -w "$BIN_DIR" ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "uninstall: error: ${BIN_DIR} is not writable and sudo is not available - run as root or delete by hand: rm ${present[*]}" >&2
            return 1
        fi
        sudo_cmd="sudo"
        echo "uninstall: ${BIN_DIR} needs root - sudo will prompt for your password."
    fi

    echo "uninstall: deleting ${present[*]}"
    if ! $sudo_cmd rm -f -- "${present[@]}"; then
        echo "uninstall: error: rm failed (sudo denied or filesystem error) - re-run ./uninstall.sh to retry this step" >&2
        return 1
    fi
    for b in "${BINARIES[@]}"; do
        if [ -e "${BIN_DIR}/${b}" ]; then
            echo "uninstall: error: ${BIN_DIR}/${b} still present after rm" >&2
            return 1
        fi
    done
    echo "uninstall: ${#present[@]} binar$([ "${#present[@]}" -eq 1 ] && echo y || echo ies) deleted."
}

STEP_FUNCS=(step_plasmoid step_daemon_unit step_binaries)

echo "uninstall.sh: devialet-expert-remote-kde uninstaller - ${TOTAL} steps"
echo

completed=()
for i in "${!STEP_FUNCS[@]}"; do
    n=$((i + 1))
    label="${STEP_LABELS[$i]}"
    echo "==> [${n}/${TOTAL}] ${label}"
    if "${STEP_FUNCS[$i]}"; then
        echo "✔   [${n}/${TOTAL}] ${label}"
        echo
        completed+=("$n")
        continue
    fi

    echo >&2
    echo "✘   [${n}/${TOTAL}] FAILED: ${label}" >&2
    echo "    (the specific error is printed above)" >&2
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
    echo "    Fix the cause reported above, then re-run ./uninstall.sh: every step" >&2
    echo "    treats already-removed pieces as done, so completed steps become no-ops." >&2
    exit "$n"
done

echo "uninstall.sh: all ${TOTAL} steps done - daemon stopped and removed, plasmoid and binaries gone."
echo
echo "  Left in place (user data - delete by hand if you want a clean slate):"
if [ -d "$DAEMON_CONFIG_DIR" ]; then
    echo "    ${DAEMON_CONFIG_DIR}/   (daemon's remembered amp selection)"
else
    echo "    (no daemon config dir found at ${DAEMON_CONFIG_DIR})"
fi
echo "    the widget's settings inside ~/.config/plasma-org.kde.plasma.desktop-appletsrc (Plasma-owned)"
echo "  If the widget is still on a panel, remove it there (right-click -> Remove);"
echo "  Plasma shows a placeholder for the missing package after its next restart."
