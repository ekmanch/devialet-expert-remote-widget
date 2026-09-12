#!/usr/bin/env bash
# Phase 13.0.1 — idempotent install/upgrade wrapper for the plasmoid.
#
# Installs the plasmoid at PLASMOID_DIR (default: ../plasmoid relative to
# this script) via `kpackagetool6 --install` if it isn't installed yet, or
# `kpackagetool6 --upgrade` if it already is. Meant to be called directly
# or sourced/invoked by the combined install.sh (Phase 13.0.3) — this
# script only handles the plasmoid step, nothing about devialet-ctl/chime
# placement (Phase 13.0.0) or the systemd unit (Phase 13.0.2).
#
# Why this branches itself instead of trusting kpackagetool6's own
# exit codes to pick install vs. upgrade (measured live, not assumed):
#   - `--install` on an already-installed plugin id fails (exit 4,
#     "... already exists") - it does not upgrade in place.
#   - `--upgrade` on a plugin id that isn't installed fails (exit 2,
#     "Plugin ... is not installed.") - it does not fall back to install.
# So the "already installed?" check has to happen before calling
# kpackagetool6 at all; this script does it by reading the real plugin id
# out of the plasmoid's own metadata.json (via jq) and checking it against
# `kpackagetool6 --type Plasma/Applet --list`, an exact line match, not
# assuming a hardcoded id.
#
# Failure modes measured live and handled explicitly below: missing
# kpackagetool6/jq, a missing plasmoid directory, a missing/malformed
# metadata.json (empty/unreadable plugin id), and kpackagetool6 itself
# erroring on install or upgrade - each exits non-zero with a clear
# message, never a silent no-op.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PLASMOID_DIR="${1:-${SCRIPT_DIR}/../plasmoid}"
PACKAGE_TYPE="Plasma/Applet"

die() {
    echo "install-plasmoid: error: $*" >&2
    exit 1
}

command -v kpackagetool6 >/dev/null 2>&1 || die "kpackagetool6 not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH (needed to read the plugin id from metadata.json)"

[ -d "$PLASMOID_DIR" ] || die "plasmoid directory not found: $PLASMOID_DIR"

METADATA_FILE="$PLASMOID_DIR/metadata.json"
[ -f "$METADATA_FILE" ] || die "metadata.json not found: $METADATA_FILE"

PLUGIN_ID="$(jq -r '.KPlugin.Id // empty' "$METADATA_FILE" 2>/dev/null || true)"
[ -n "$PLUGIN_ID" ] || die "could not read a valid KPlugin.Id out of $METADATA_FILE (malformed or missing field)"

echo "install-plasmoid: plugin id: $PLUGIN_ID"
echo "install-plasmoid: source: $PLASMOID_DIR"

if kpackagetool6 --type "$PACKAGE_TYPE" --list 2>/dev/null | grep -qx -- "$PLUGIN_ID"; then
    echo "install-plasmoid: already installed, upgrading..."
    kpackagetool6 --type "$PACKAGE_TYPE" --upgrade "$PLASMOID_DIR" \
        || die "kpackagetool6 --upgrade failed for $PLUGIN_ID"
else
    echo "install-plasmoid: not installed yet, installing..."
    kpackagetool6 --type "$PACKAGE_TYPE" --install "$PLASMOID_DIR" \
        || die "kpackagetool6 --install failed for $PLUGIN_ID"
fi

# Confirm the end state actually landed - kpackagetool6 exits 0 on success
# in every case measured, but re-checking --list closes the loop rather
# than trusting the exit code alone.
if ! kpackagetool6 --type "$PACKAGE_TYPE" --list 2>/dev/null | grep -qx -- "$PLUGIN_ID"; then
    die "kpackagetool6 reported success but $PLUGIN_ID is not in --list afterward"
fi

echo "install-plasmoid: done, $PLUGIN_ID is installed."
