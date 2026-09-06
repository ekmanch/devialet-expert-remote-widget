//! Single-shot command CLI, invoked from QML via
//! `Plasma5Support.DataSource`'s executable engine. Builds one (or, for
//! `source`, two) logical UDP commands, sends each twice per
//! docs/protocol.md's `sendTwice()` behavior, and exits. No daemon
//! interaction, no D-Bus - see CLAUDE.md.
//!
//! Usage:
//!   devialet-ctl --ip <amp-ip> power <on|off>
//!   devialet-ctl --ip <amp-ip> mute <on|off>
//!   devialet-ctl --ip <amp-ip> volume <db, e.g. -20.0> --hard-limit-db <db|none>
//!   devialet-ctl --ip <amp-ip> source <status-broadcast index, 0-29> --hard-limit-db <db|none>
//!
//! `--ip` is required: unlike the original single-process Kotlin app (which
//! held the target IP as instance state across its whole session), this CLI
//! is a fresh process per invocation with no persisted "selected amp"
//! concept yet (amp discovery/selection UI is a later phase) - so the
//! caller (QML, eventually) must supply the target IP every time.
//!
//! `--hard-limit-db <db|none>` (Phase 8.1.0): **required** for `volume`
//! and `source` (a missing flag is a CLI error, not a silent gap) - applies
//! `devialet_protocol::volume_packet`'s hard-limit clamp to every
//! volume-set command this invocation sends (the plain `volume` command,
//! and `source`'s forced post-switch volume). The literal value `none`
//! (case-insensitive) means explicitly unbounded - a deliberate choice,
//! not a fallback for an omitted flag; see that function's own doc for why
//! unbounded isn't the same as reintroducing a hardcoded ceiling. A named
//! flag rather than a second positional value: `source` is expected to
//! gain its own optional trailing value in Phase 8.0.1 (startup/
//! source-switch volume) - two independent optional positional slots
//! would be ambiguous about which value fills which when only one is
//! given, where two independent named flags aren't.
//!
//! **This flag closes the hard-limit guarantee only for QML-originated
//! invocations** - QML passes `volumeSettings.hardLimitDb` on every call
//! (see plasmoid/contents/ui/FlyoutContent.qml, CompactRepresentation.qml).
//! A bare manual invocation of this binary from a terminal now has to
//! supply the flag explicitly (`--hard-limit-db none` for unbounded, or a
//! real number) - the CLI has no way to independently re-derive the
//! widget's configured limit itself without a value being passed in. See
//! TODO.md's Phase 8.1.0 entry for why a fully caller-independent
//! guarantee (e.g. this CLI reading Plasma's own KConfig directly) was
//! investigated and not pursued.

use devialet_protocol as proto;
use std::net::{ToSocketAddrs, UdpSocket};
use std::process::ExitCode;

struct Args {
    ip: String,
    command: String,
    value: String,
    /// `None` = flag not given at all (an error for `volume`/`source`,
    /// checked at the point of use, not here - `power`/`mute` don't need
    /// it). `Some(None)` = flag given as the literal `none` - explicitly
    /// unbounded. `Some(Some(db))` = flag given with a real limit.
    hard_limit_db: Option<Option<f64>>,
}

fn parse_args() -> Result<Args, String> {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    if raw.len() < 4 || raw[0] != "--ip" {
        return Err(usage());
    }
    let ip = raw[1].clone();
    let command = raw[2].clone();
    let value = raw[3].clone();

    let mut hard_limit_db = None;
    let mut i = 4;
    while i < raw.len() {
        match raw[i].as_str() {
            "--hard-limit-db" => {
                let v = raw
                    .get(i + 1)
                    .ok_or_else(|| format!("--hard-limit-db requires a value\n\n{}", usage()))?;
                hard_limit_db = Some(if v.eq_ignore_ascii_case("none") {
                    None
                } else {
                    Some(
                        v.parse::<f64>()
                            .map_err(|_| format!("expected a number or \"none\" for --hard-limit-db, got {:?}", v))?,
                    )
                });
                i += 2;
            }
            other => return Err(format!("unknown argument {other:?}\n\n{}", usage())),
        }
    }

    Ok(Args {
        ip,
        command,
        value,
        hard_limit_db,
    })
}

fn usage() -> String {
    "usage: devialet-ctl --ip <amp-ip> <power|mute|volume|source> <value> [--hard-limit-db <db|none>]\n\
     \n\
     \x20 power  on|off\n\
     \x20 mute   on|off\n\
     \x20 volume <db, e.g. -20.0>  --hard-limit-db <db|none>  (required; \"none\" = explicitly unbounded)\n\
     \x20 source <status-broadcast index, 0-29>  --hard-limit-db <db|none>  (required; applies to the forced post-switch volume)"
        .to_string()
}

/// `volume`/`source` both require the flag - a missing `--hard-limit-db`
/// is a CLI usage error, not a silent "unbounded" default. Only an
/// explicit `none` means unbounded.
fn require_hard_limit(args: &Args) -> Result<Option<f64>, String> {
    args.hard_limit_db
        .ok_or_else(|| format!("--hard-limit-db is required (pass a number, or \"none\" to explicitly send unbounded)\n\n{}", usage()))
}

fn parse_on_off(value: &str) -> Result<bool, String> {
    match value {
        "on" => Ok(true),
        "off" => Ok(false),
        other => Err(format!("expected \"on\" or \"off\", got {other:?}")),
    }
}

/// Sends one logical command twice, per docs/protocol.md's `sendTwice()` -
/// the two wire copies carry different counter values (see
/// `next_counter`), not identical bytes. `counters` is `(packet, command)`
/// and is advanced by 2 (once per send) so a caller sending multiple
/// logical commands in one process invocation (`source` + the forced
/// follow-up volume) keeps counters moving forward across both, matching
/// the original single-process app's behavior of never resetting counters
/// between logical commands within one session.
fn send_twice(
    socket: &UdpSocket,
    build: impl Fn(u16, u16) -> [u8; proto::PACKET_LEN],
    counters: &mut (u16, u16),
) -> std::io::Result<()> {
    for _ in 0..2 {
        let packet = build(counters.0, counters.1);
        socket.send(&packet)?;
        counters.0 = proto::next_counter(counters.0);
        counters.1 = proto::next_counter(counters.1);
    }
    Ok(())
}

fn run() -> Result<(), String> {
    let args = parse_args()?;

    let addr = (args.ip.as_str(), proto::COMMAND_PORT)
        .to_socket_addrs()
        .map_err(|e| format!("invalid --ip {:?}: {e}", args.ip))?
        .next()
        .ok_or_else(|| format!("could not resolve --ip {:?}", args.ip))?;

    let socket = UdpSocket::bind("0.0.0.0:0").map_err(|e| format!("failed to open socket: {e}"))?;
    socket
        .connect(addr)
        .map_err(|e| format!("failed to target {addr}: {e}"))?;

    // Counter state for this process invocation only - see CLAUDE.md /
    // module doc: whether the amp requires counters to stay contiguous
    // *across* separate CLI invocations is explicitly flagged
    // "inferred, not confirmed" in docs/protocol.md and unverified here.
    // Each invocation currently starts from (0, 0); if real-device testing
    // shows the amp cares about cross-invocation continuity, this is the
    // place to switch to a persisted counter (e.g. a small state file)
    // instead.
    let mut counters: (u16, u16) = (0, 0);

    match args.command.as_str() {
        "power" => {
            let on = parse_on_off(&args.value)?;
            send_twice(&socket, |p, c| proto::power_packet(on, p, c), &mut counters)
                .map_err(|e| format!("send failed: {e}"))?;
        }
        "mute" => {
            let muted = parse_on_off(&args.value)?;
            send_twice(&socket, |p, c| proto::mute_packet(muted, p, c), &mut counters)
                .map_err(|e| format!("send failed: {e}"))?;
        }
        "volume" => {
            let db: f64 = args
                .value
                .parse()
                .map_err(|_| format!("expected a number for volume, got {:?}", args.value))?;
            let hard_limit_db = require_hard_limit(&args)?;
            send_twice(
                &socket,
                |p, c| proto::volume_packet(db, hard_limit_db, p, c),
                &mut counters,
            )
            .map_err(|e| format!("send failed: {e}"))?;
        }
        "source" => {
            let index: u8 = args
                .value
                .parse()
                .map_err(|_| format!("expected an integer 0-29 for source, got {:?}", args.value))?;
            let hard_limit_db = require_hard_limit(&args)?;
            send_twice(&socket, |p, c| proto::source_packet(index, p, c), &mut counters)
                .map_err(|e| format!("send failed: {e}"))?;
            // Forced follow-up volume after every source switch - not
            // optional, not source-dependent. See
            // docs/known-gotchas.md #5 and proto::SOURCE_SWITCH_VOLUME_DB's
            // doc comment. Continues the same counter sequence. Also
            // subject to the configured hard limit (Phase 8.1.0) like any
            // other volume-set command - SOURCE_SWITCH_VOLUME_DB (-40dB)
            // is normally well below any real limit, but a caller could in
            // principle configure a stricter one.
            send_twice(
                &socket,
                |p, c| proto::volume_packet(proto::SOURCE_SWITCH_VOLUME_DB, hard_limit_db, p, c),
                &mut counters,
            )
            .map_err(|e| format!("send failed: {e}"))?;
        }
        other => return Err(format!("unknown command {other:?}\n\n{}", usage())),
    }

    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(msg) => {
            eprintln!("{msg}");
            ExitCode::FAILURE
        }
    }
}
