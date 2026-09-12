// Phase 11.0.0: the ONE place that knows how the daemon's launch-at-login
// state is read and changed - `systemctl --user is-enabled` /
// `enable` / `disable` on devialet-remote-daemon.service, per CLAUDE.md's
// "Persistence" decision: systemd's own enablement state is the storage,
// there is no KConfig bool anywhere (and never should be - see the
// "must persist" exception in CLAUDE.md's Settings ConfigDialog section).
// ConfigGeneral.qml instantiates one per dialog open; nothing on the
// widget side reads it yet. Lives in contents/ui/ like SoundThemes.qml so
// a later phase could, without moving it.
//
// Plain QtObject (no qmldir/singleton in this KPackage) holding its
// P5Support.DataSource as an object-typed property, the way
// SoundThemes.qml does. Deliberately does not import
// org.kde.plasma.plasmoid (see VolumeSettings.qml's header for why bare
// QtObject files here never do).
//
// Why the query result is classified by the stdout TOKEN and not the
// exit code (measured on this machine, systemd 261, before writing this):
//   enabled        -> stdout "enabled",   exit 0
//   disabled       -> stdout "disabled",  exit 1   (a normal answer)
//   unit missing   -> stdout "not-found", exit 4
//   user bus down  -> stdout EMPTY, exit 1, stderr "Failed to connect to
//                     user scope bus ..."   (same exit code as disabled!)
//   systemctl not on PATH -> exit 127, shell stderr, empty stdout
// So exit 1 alone cannot tell "genuinely disabled" from "the query itself
// failed"; the token can. The exit code and stderr are only consulted
// when there is no token at all. Full token list is systemctl(1)'s
// "is-enabled output" table: enabled, enabled-runtime, linked,
// linked-runtime, alias, masked, masked-runtime, static, indirect,
// disabled, generated, transient, not-found.
//
// For enable/disable the exit code IS the verdict: both print
// "Created symlink ..." / "Removed ..." on stderr with exit 0, so stderr
// is informational unless the exit code is non-zero.
import QtQuick
import org.kde.plasma.plasma5support as P5Support

QtObject {
    id: root

    readonly property string unitName: "devialet-remote-daemon.service"

    // Real default. Only a standalone test driver ever overrides this
    // (e.g. to "/nonexistent/systemctl --user") to exercise the failing-
    // query path hands-free; ConfigGeneral.qml never sets it.
    property string systemctl: "systemctl --user"

    // One of: "unknown" (never queried), "querying", "enabled",
    // "disabled", "not-found" (unit file missing - exit 4),
    // "unsupported" (a real token this toggle can't act on: static,
    // masked, indirect, linked, alias, generated, transient,
    // enabled-runtime - the last doesn't survive a reboot, so it is not
    // "launch at login" either), "error" (no token at all: bus
    // unreachable, systemctl missing, anything unexpected).
    property string state: "unknown"
    // Raw first stdout line of the last query ("" when there was none).
    property string token: ""
    // First stderr line of the last FAILED query; "" when the last
    // query produced a token.
    property string detail: ""

    property bool writing: false
    // Set when the last enable/disable exited non-zero, with its first
    // stderr line in writeDetail; both cleared by the next apply(). Kept
    // separate from `detail` on purpose: the re-query that follows a
    // failed write overwrites `detail`, and the page still needs to say
    // "couldn't change it" next to the real, re-queried state.
    property bool lastWriteFailed: false
    property string writeDetail: ""

    // The only two states a toggle may act on.
    readonly property bool toggleable: root.state === "enabled" || root.state === "disabled"

    // Emitted once per apply(), after the re-query has been ISSUED (not
    // completed): ok = the enable/disable command exited 0.
    signal applied(bool ok)

    // Every command string must be unique: the executable engine is
    // shared process-wide and keys running jobs by command string, so a
    // second identical is-enabled while the first is still in flight
    // would collapse into it (same DEVIALET_*_TICK=<n> no-op env-prefix
    // trick as ConfigGeneral.previewChime() and maybeChime()'s --tick).
    // The exact strings are also the dispatch keys in onNewData below.
    property int tick: 0
    property string pendingQuery: ""
    property string pendingWrite: ""

    function nextPrefix() {
        const p = "DEVIALET_SYSTEMD_TICK=" + root.tick + " ";
        root.tick += 1;
        return p;
    }

    function firstLine(s) {
        return String(s || "").split("\n")[0].trim();
    }

    function refresh() {
        root.state = "querying";
        root.pendingQuery = root.nextPrefix() + root.systemctl + " is-enabled " + root.unitName;
        root.probe.connectSource(root.pendingQuery);
    }

    // Plain enable/disable, no --now (owner decision, Phase 11.0.0): the
    // toggle means "launch at login", not "run the daemon now" - a
    // running daemon keeps running after disable, and enabling doesn't
    // start a stopped one before the next login.
    function apply(enable) {
        root.lastWriteFailed = false;
        root.writeDetail = "";
        root.writing = true;
        root.pendingWrite = root.nextPrefix() + root.systemctl + (enable ? " enable " : " disable ") + root.unitName;
        console.log("[DaemonAutostart] running:", root.pendingWrite);
        root.probe.connectSource(root.pendingWrite);
    }

    function classify(code, stdout, stderr) {
        root.token = root.firstLine(stdout);
        switch (root.token) {
        case "enabled":
            root.state = "enabled";
            root.detail = "";
            return;
        case "disabled":
            root.state = "disabled";
            root.detail = "";
            return;
        case "not-found":
            root.state = "not-found";
            root.detail = "";
            break;
        case "":
            root.state = "error";
            root.detail = root.firstLine(stderr);
            if (root.detail === "") root.detail = "exit code " + code;
            break;
        default:
            root.state = "unsupported";
            root.detail = "";
            break;
        }
        console.warn("[DaemonAutostart] is-enabled ->", root.state, "- exit code:", code, "token:", root.token, "stderr:", root.firstLine(stderr));
    }

    readonly property P5Support.DataSource probe: P5Support.DataSource {
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            const code = data["exit code"];
            if (source === root.pendingQuery) {
                root.pendingQuery = "";
                root.classify(code, data["stdout"], data["stderr"]);
            } else if (source === root.pendingWrite) {
                root.pendingWrite = "";
                const ok = code === 0;
                if (!ok) {
                    root.lastWriteFailed = true;
                    root.writeDetail = root.firstLine(data["stderr"]);
                    if (root.writeDetail === "") root.writeDetail = "exit code " + code;
                    console.warn("[DaemonAutostart] enable/disable FAILED - exit code:", code, "stderr:", data["stderr"], "command:", source);
                } else {
                    console.log("[DaemonAutostart] enable/disable ok:", root.firstLine(data["stderr"]));
                }
                root.writing = false;
                // Never trust the click: the toggle is re-derived from
                // what systemd says now, whether the write worked or not.
                root.refresh();
                root.applied(ok);
            } else {
                console.log("[DaemonAutostart] ignoring stale result for:", source);
            }
            disconnectSource(source);
        }
    }
}
