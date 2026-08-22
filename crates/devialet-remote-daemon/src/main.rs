//! Status-listener daemon. Owns the UDP 45454 socket, parses every status
//! broadcast via `devialet_protocol`, and pushes the latest state out over
//! the session D-Bus bus (`com.ekmanch.DevialetRemote`, see interface.rs)
//! with `PropertiesChanged` signals - no polling, no status file. See
//! CLAUDE.md for the settled architecture this implements.
//!
//! Phase 3.5: every amp heard broadcasting is tracked (not just the most
//! recent), exposed via the `KnownAmps` property, alongside an explicit
//! `SelectedAmpIp`/`SelectAmp()` selection surface - see interface.rs's
//! `AmpState` doc for the full model (ported from the Kotlin app's
//! `discoveredAmps`/`selectedIp`). All of `AmpState`'s tracking/selection/
//! staleness logic lives in interface.rs; this file is just the I/O shim
//! around it (receive loop + D-Bus registration), consistent with the
//! protocol crate's own "logic has no I/O, I/O has no logic" split.

mod interface;

use devialet_protocol as proto;
use interface::AmpState;
use socket2::{Domain, Protocol, Socket, Type};
use std::net::{SocketAddr, UdpSocket};
use std::time::Duration;

/// How often the receive loop wakes up even with no incoming packet, purely
/// so it can re-evaluate staleness (see module doc / CLAUDE.md's
/// "Environment" section for why this exists despite the "no async
/// runtime, blocking loop" constraint: a plain indefinite blocking
/// `recv_from` would never notice an amp going silent, since nothing
/// happens to wake the loop up. A short read timeout keeps the loop
/// genuinely blocking/synchronous - not async - while still being able to
/// notice silence.)
const POLL_TICK: Duration = Duration::from_secs(1);

fn bind_status_socket() -> std::io::Result<UdpSocket> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    socket.set_reuse_address(true)?;
    let addr: SocketAddr = ([0, 0, 0, 0], proto::STATUS_PORT).into();
    socket.bind(&addr.into())?;
    socket.set_broadcast(true)?;
    socket.set_read_timeout(Some(POLL_TICK))?;
    Ok(socket.into())
}

/// Set `DEVIALET_DAEMON_DEBUG=1` to enable verbose per-packet diagnostics:
/// every `recv_from` outcome, a full hex dump of the first few real packets
/// received, parse success/failure detail, and a read-back check proving
/// the property getters see the same state the receive loop just wrote.
/// Off by default to avoid log spam at the amp's ~1-5Hz broadcast rate
/// during normal operation.
fn debug_enabled() -> bool {
    std::env::var("DEVIALET_DAEMON_DEBUG").as_deref() == Ok("1")
}

fn hex_dump(data: &[u8]) -> String {
    data.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join(" ")
}

fn main() -> std::io::Result<()> {
    let debug = debug_enabled();

    eprintln!(
        "devialet-remote-daemon starting: status UDP {}, D-Bus name {}",
        proto::STATUS_PORT,
        interface::BUS_NAME
    );
    if debug {
        eprintln!("[debug] DEVIALET_DAEMON_DEBUG=1: verbose diagnostics on");
    }
    // Item 3 from the real-device debugging request: this receive loop runs
    // directly on main() - no thread::spawn anywhere in this binary. A
    // panic here would unwind out of main and kill the whole process
    // (D-Bus registration included), not silently freeze it while the
    // service stays responsive. If the daemon is observed staying
    // responsive on D-Bus while state is frozen, the cause is NOT a dead
    // background thread - this process has none.
    eprintln!("receive loop runs on main() directly - no spawned thread in this binary");

    let connection = zbus::blocking::connection::Builder::session()
        .and_then(|b| b.serve_at(interface::OBJECT_PATH, AmpState::default()))
        .and_then(|b| b.name(interface::BUS_NAME))
        .and_then(|b| b.build())
        .map_err(std::io::Error::other)?;

    let iface_ref: zbus::blocking::object_server::InterfaceRef<AmpState> = connection
        .object_server()
        .interface(interface::OBJECT_PATH)
        .map_err(std::io::Error::other)?;

    eprintln!(
        "registered {} at {} on {}",
        interface::INTERFACE_NAME,
        interface::OBJECT_PATH,
        interface::BUS_NAME
    );

    let socket = bind_status_socket()?;
    eprintln!("listening for status broadcasts on 0.0.0.0:{}", proto::STATUS_PORT);

    let mut packets_seen: u64 = 0;

    let mut buf = [0u8; 2048];
    loop {
        match socket.recv_from(&mut buf) {
            Ok((len, src)) => {
                packets_seen += 1;
                // Item 1: recv_from's actual outcome, unconditionally on
                // every real packet when debug is on.
                if debug {
                    eprintln!("[debug] recv_from: Ok, {len} bytes from {src} (packet #{packets_seen})");
                }
                // Item 2: raw bytes of the first few real packets, to
                // compare directly against docs/protocol.md's assumed
                // offsets/minimum length.
                if debug && packets_seen <= 3 {
                    eprintln!("[debug] raw bytes (packet #{packets_seen}, {len} bytes):\n{}", hex_dump(&buf[..len]));
                }

                let parse_result = proto::parse_status(&buf[..len]);
                if debug {
                    match &parse_result {
                        Ok(s) => eprintln!(
                            "[debug] parse_status: Ok - device_name={:?} power={} muted={} volume_raw={} source_index={}",
                            s.device_name, s.power_on, s.muted, s.volume_raw, s.source_index
                        ),
                        Err(e) => eprintln!("[debug] parse_status: Err({e:?}) for a {len}-byte packet (STATUS_MIN_LEN={})", proto::STATUS_MIN_LEN),
                    }
                }

                let Ok(status) = parse_result else {
                    // Too short / malformed - drop and keep listening,
                    // matching DevialetStatusListener.parseStatus()'s
                    // "catch, drop packet, keep running" behavior.
                    continue;
                };
                let ip = src.ip().to_string();
                let device_name = status.device_name.clone();

                ingest_and_maybe_emit(&iface_ref, ip.clone(), status).map_err(std::io::Error::other)?;

                // Item 4: read back through the SAME InterfaceRef the D-Bus
                // property getters are registered against, immediately
                // after writing, to prove this isn't a separate/stale copy.
                // Note device_name/online below reflect the *primary*
                // (selected/auto-selected) amp, which may differ from this
                // packet's own amp if it isn't the one currently selected -
                // see interface.rs's AmpState doc.
                if debug {
                    let read_back = iface_ref.get();
                    eprintln!(
                        "[debug] read-back via iface_ref.get() immediately after write: primary device_name={:?} online={} (packet was from {ip:?}, device_name={device_name:?})",
                        read_back.device_name(), read_back.online()
                    );
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {
                if debug {
                    eprintln!("[debug] recv_from: timed out (no packet in {POLL_TICK:?}) - loop is alive, {packets_seen} real packets seen so far");
                }
                // No packet within POLL_TICK - re-check staleness for every
                // known amp (not just the primary), since a non-primary amp
                // going quiet still needs to be reflected in KnownAmps.
                recompute_staleness_and_maybe_emit(&iface_ref).map_err(std::io::Error::other)?;
            }
            Err(e) => {
                // Transient receive error - matches
                // DevialetStatusListener's "loop continues, treated as
                // transient" behavior.
                eprintln!("recv_from error (continuing): {e}");
            }
        }
    }
}

/// Records a freshly-parsed status broadcast and, only if doing so actually
/// changed any exposed property (primary fields, `KnownAmps`, or
/// `SelectedAmpIp`), emits `PropertiesChanged` for all of them. Guarding on
/// an actual change (rather than Phase 1's unconditional re-emission) is
/// needed now that a packet from a non-primary amp can otherwise cause a
/// no-op emit every ~1s it broadcasts.
fn ingest_and_maybe_emit(
    iface_ref: &zbus::blocking::object_server::InterfaceRef<AmpState>,
    ip: String,
    status: proto::Status,
) -> zbus::Result<()> {
    let mut iface = iface_ref.get_mut();
    let before = iface.clone();
    iface.ingest_status(ip, status);
    emit_if_changed(iface_ref, &iface, &before)
}

/// Re-derives staleness for every known amp (no new packet) and emits only
/// if something actually changed - see `POLL_TICK`'s doc comment for why
/// this tick exists at all.
fn recompute_staleness_and_maybe_emit(
    iface_ref: &zbus::blocking::object_server::InterfaceRef<AmpState>,
) -> zbus::Result<()> {
    let mut iface = iface_ref.get_mut();
    let before = iface.clone();
    iface.recompute_staleness();
    emit_if_changed(iface_ref, &iface, &before)
}

fn emit_if_changed(
    iface_ref: &zbus::blocking::object_server::InterfaceRef<AmpState>,
    iface: &AmpState,
    before: &AmpState,
) -> zbus::Result<()> {
    if interface::states_equal(before, iface) {
        return Ok(());
    }
    let emitter = iface_ref.signal_emitter();
    async_io::block_on(interface::emit_all(iface, emitter))
}
