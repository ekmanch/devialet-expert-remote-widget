//! Single-shot command CLI, invoked from QML via
//! `Plasma5Support.DataSource`'s executable engine. Builds one (or, for
//! `source`, two) logical UDP commands, sends each twice per
//! docs/protocol.md's `sendTwice()` behavior, and exits. No daemon
//! interaction, no D-Bus - see CLAUDE.md.
//!
//! Usage:
//!   devialet-ctl --ip <amp-ip> power <on|off>
//!   devialet-ctl --ip <amp-ip> mute <on|off>
//!   devialet-ctl --ip <amp-ip> volume <db, e.g. -20.0>
//!   devialet-ctl --ip <amp-ip> source <status-broadcast index, 0-29>
//!
//! `--ip` is required: unlike the original single-process Kotlin app (which
//! held the target IP as instance state across its whole session), this CLI
//! is a fresh process per invocation with no persisted "selected amp"
//! concept yet (amp discovery/selection UI is a later phase) - so the
//! caller (QML, eventually) must supply the target IP every time.

use devialet_protocol as proto;
use std::net::{ToSocketAddrs, UdpSocket};
use std::process::ExitCode;

struct Args {
    ip: String,
    command: String,
    value: String,
}

fn parse_args() -> Result<Args, String> {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    if raw.len() != 4 || raw[0] != "--ip" {
        return Err(usage());
    }
    Ok(Args {
        ip: raw[1].clone(),
        command: raw[2].clone(),
        value: raw[3].clone(),
    })
}

fn usage() -> String {
    "usage: devialet-ctl --ip <amp-ip> <power|mute|volume|source> <value>\n\
     \n\
     \x20 power  on|off\n\
     \x20 mute   on|off\n\
     \x20 volume <db, e.g. -20.0>  (clamped to -15.0 max, never sent louder)\n\
     \x20 source <status-broadcast index, 0-29>"
        .to_string()
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
            send_twice(&socket, |p, c| proto::volume_packet(db, p, c), &mut counters)
                .map_err(|e| format!("send failed: {e}"))?;
        }
        "source" => {
            let index: u8 = args
                .value
                .parse()
                .map_err(|_| format!("expected an integer 0-29 for source, got {:?}", args.value))?;
            send_twice(&socket, |p, c| proto::source_packet(index, p, c), &mut counters)
                .map_err(|e| format!("send failed: {e}"))?;
            // Forced follow-up volume after every source switch - not
            // optional, not source-dependent. See
            // docs/known-gotchas.md #5 and proto::SOURCE_SWITCH_VOLUME_DB's
            // doc comment. Continues the same counter sequence.
            send_twice(
                &socket,
                |p, c| proto::volume_packet(proto::SOURCE_SWITCH_VOLUME_DB, p, c),
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
