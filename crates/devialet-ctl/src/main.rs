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
//!   devialet-ctl --ip <amp-ip> source <status-broadcast index, 0-29> --hard-limit-db <db|none> [--startup-volume-db <db>]
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
//!
//! `--startup-volume-db <db>` (Phase 8.0.1): **optional**, consumed only by
//! `source` - the post-switch volume to send instead of the hardcoded
//! `devialet_protocol::SOURCE_SWITCH_VOLUME_DB` (-40dB). Omitted → that
//! default, silently (deliberately NOT required, unlike `--hard-limit-db`:
//! an omitted safety ceiling used to mean "unbounded", a real gap, while
//! an omitted startup volume just means "the existing safe default", which
//! is already correct - see TODO.md's Phase 8.0.1 entry). Whatever value
//! is given still goes through `volume_packet`'s `--hard-limit-db` clamp
//! like every other volume-set command this binary sends. Parsed globally
//! like `--hard-limit-db` (accepted on any command, in either order
//! relative to it); only `source` reads it. Power-on has no equivalent
//! flag: the CLI is fire-and-exit and cannot wait ~16 s for the amp to
//! boot, so the widget sends a separate plain `volume` invocation once the
//! daemon confirms the boot (see plasmoid/contents/ui/FlyoutContent.qml).
//!
//! Gate #1 (2026-09-07, real amp): the same-invocation shape - source×2
//! then volume×2 back-to-back with zero settling time - was honored 6/6
//! against a pre-set, distinguishable per-input volume memory; the first
//! broadcast ~200 ms after the send already carried the new index and
//! the forced volume together. No delay is needed on this path.

use devialet_protocol as proto;
use std::net::{ToSocketAddrs, UdpSocket};
use std::process::ExitCode;

#[derive(Debug)]
struct Args {
    ip: String,
    command: String,
    value: String,
    /// `None` = flag not given at all (an error for `volume`/`source`,
    /// checked at the point of use, not here - `power`/`mute` don't need
    /// it). `Some(None)` = flag given as the literal `none` - explicitly
    /// unbounded. `Some(Some(db))` = flag given with a real limit.
    hard_limit_db: Option<Option<f64>>,
    /// `None` = flag not given - `source` falls back to
    /// `proto::SOURCE_SWITCH_VOLUME_DB`, no error (see module doc for why
    /// this is optional where `--hard-limit-db` is required).
    startup_volume_db: Option<f64>,
}

fn parse_args() -> Result<Args, String> {
    parse_args_from(std::env::args().skip(1).collect())
}

/// Pure parser over an already-collected argument list (everything after
/// argv[0]) - split from `parse_args()` so it is unit-testable without a
/// process.
fn parse_args_from(raw: Vec<String>) -> Result<Args, String> {
    if raw.len() < 4 || raw[0] != "--ip" {
        return Err(usage());
    }
    let ip = raw[1].clone();
    let command = raw[2].clone();
    let value = raw[3].clone();

    let mut hard_limit_db = None;
    let mut startup_volume_db = None;
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
            "--startup-volume-db" => {
                let v = raw
                    .get(i + 1)
                    .ok_or_else(|| format!("--startup-volume-db requires a value\n\n{}", usage()))?;
                startup_volume_db = Some(
                    v.parse::<f64>()
                        .map_err(|_| format!("expected a number for --startup-volume-db, got {:?}", v))?,
                );
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
        startup_volume_db,
    })
}

/// The volume `source` sends right after the switch: the caller's
/// `--startup-volume-db` when given, else the hardcoded default that has
/// applied since Phase 3 (docs/known-gotchas.md #5). The hard-limit clamp
/// is applied later by `volume_packet`, not here.
fn post_switch_volume_db(args: &Args) -> f64 {
    args.startup_volume_db.unwrap_or(proto::SOURCE_SWITCH_VOLUME_DB)
}

fn usage() -> String {
    "usage: devialet-ctl --ip <amp-ip> <power|mute|volume|source> <value> [--hard-limit-db <db|none>] [--startup-volume-db <db>]\n\
     \n\
     \x20 power  on|off\n\
     \x20 mute   on|off\n\
     \x20 volume <db, e.g. -20.0>  --hard-limit-db <db|none>  (required; \"none\" = explicitly unbounded)\n\
     \x20 source <status-broadcast index, 0-29>  --hard-limit-db <db|none>  (required; applies to the forced post-switch volume)\n\
     \x20        [--startup-volume-db <db>]  (optional; post-switch volume instead of the default -40, still clamped by --hard-limit-db)"
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
            // doc comment. Continues the same counter sequence. Phase
            // 8.0.1: the value is the caller's `--startup-volume-db` when
            // given (the widget passes its configured startup volume),
            // else the hardcoded -40dB default, unchanged. Either way it
            // is subject to the configured hard limit (Phase 8.1.0) like
            // any other volume-set command - `volume_packet` clamps to
            // `hard_limit_db` itself, so a startup volume configured above
            // the limit lands on the limit (covered by a test below).
            let post_switch_db = post_switch_volume_db(&args);
            send_twice(
                &socket,
                |p, c| proto::volume_packet(post_switch_db, hard_limit_db, p, c),
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

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Result<Args, String> {
        parse_args_from(list.iter().map(|s| s.to_string()).collect())
    }

    #[test]
    fn startup_volume_omitted_falls_back_to_default_without_error() {
        let a = args(&["--ip", "1.2.3.4", "source", "3", "--hard-limit-db", "-10"]).unwrap();
        assert_eq!(a.startup_volume_db, None);
        assert_eq!(post_switch_volume_db(&a), proto::SOURCE_SWITCH_VOLUME_DB);
        assert_eq!(a.hard_limit_db, Some(Some(-10.0)));
    }

    #[test]
    fn startup_volume_given_is_used() {
        let a = args(&["--ip", "1.2.3.4", "source", "3", "--hard-limit-db", "-10", "--startup-volume-db", "-33"]).unwrap();
        assert_eq!(a.startup_volume_db, Some(-33.0));
        assert_eq!(post_switch_volume_db(&a), -33.0);
    }

    #[test]
    fn both_flags_accepted_in_either_order() {
        let a = args(&["--ip", "1.2.3.4", "source", "0", "--startup-volume-db", "-30.5", "--hard-limit-db", "none"]).unwrap();
        assert_eq!(a.startup_volume_db, Some(-30.5));
        assert_eq!(a.hard_limit_db, Some(None));
        let b = args(&["--ip", "1.2.3.4", "source", "0", "--hard-limit-db", "none", "--startup-volume-db", "-30.5"]).unwrap();
        assert_eq!(b.startup_volume_db, Some(-30.5));
        assert_eq!(b.hard_limit_db, Some(None));
    }

    #[test]
    fn startup_volume_missing_value_is_an_error() {
        let e = args(&["--ip", "1.2.3.4", "source", "0", "--hard-limit-db", "-10", "--startup-volume-db"]).unwrap_err();
        assert!(e.contains("--startup-volume-db requires a value"), "{e}");
    }

    #[test]
    fn startup_volume_non_numeric_is_an_error() {
        let e = args(&["--ip", "1.2.3.4", "source", "0", "--hard-limit-db", "-10", "--startup-volume-db", "loud"]).unwrap_err();
        assert!(e.contains("expected a number for --startup-volume-db"), "{e}");
        // No `none` literal for this flag, unlike --hard-limit-db.
        let e = args(&["--ip", "1.2.3.4", "source", "0", "--hard-limit-db", "-10", "--startup-volume-db", "none"]).unwrap_err();
        assert!(e.contains("expected a number for --startup-volume-db"), "{e}");
    }

    #[test]
    fn power_on_is_unaffected_by_the_flag() {
        let a = args(&["--ip", "1.2.3.4", "power", "on"]).unwrap();
        assert_eq!(a.command, "power");
        assert_eq!(a.startup_volume_db, None);
        assert_eq!(a.hard_limit_db, None);
        // Parsed globally, ignored by power - not an error either.
        let b = args(&["--ip", "1.2.3.4", "power", "on", "--startup-volume-db", "-20"]).unwrap();
        assert_eq!(b.startup_volume_db, Some(-20.0));
    }

    #[test]
    fn hard_limit_still_required_for_source_with_startup_volume() {
        let a = args(&["--ip", "1.2.3.4", "source", "0", "--startup-volume-db", "-20"]).unwrap();
        assert!(require_hard_limit(&a).unwrap_err().contains("--hard-limit-db is required"));
    }

    /// Documents the clamp on exactly the composition `source` uses:
    /// a startup volume above the hard limit produces the same packet as
    /// the limit itself.
    #[test]
    fn startup_volume_above_hard_limit_is_clamped_in_the_packet() {
        let a = args(&["--ip", "1.2.3.4", "source", "0", "--hard-limit-db", "-10", "--startup-volume-db", "-5"]).unwrap();
        let limit = require_hard_limit(&a).unwrap();
        let clamped = proto::volume_packet(post_switch_volume_db(&a), limit, 0, 0);
        let expected = proto::volume_packet(-10.0, limit, 0, 0);
        assert_eq!(clamped, expected);
        // And a startup volume below the limit is passed through untouched.
        let b = args(&["--ip", "1.2.3.4", "source", "0", "--hard-limit-db", "-10", "--startup-volume-db", "-33"]).unwrap();
        assert_eq!(
            proto::volume_packet(post_switch_volume_db(&b), limit, 0, 0),
            proto::volume_packet(-33.0, None, 0, 0)
        );
    }
}
