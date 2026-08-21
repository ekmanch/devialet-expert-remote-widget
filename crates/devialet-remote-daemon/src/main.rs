//! Status-listener daemon. Owns the UDP 45454 socket, parses every status
//! broadcast via `devialet_protocol`, and pushes the latest state out over
//! the session D-Bus bus (`com.ekmanch.DevialetRemote`, see interface.rs)
//! with `PropertiesChanged` signals - no polling, no status file. See
//! CLAUDE.md for the settled architecture this implements.
//!
//! Phase 1 scope note: amp *selection* (a persisted "chosen amp" the way
//! the Kotlin app's `SharedPreferences amp_ip`/`amp_name` worked) isn't
//! implemented yet - there's no picker UI in this phase. "Primary" here
//! just means "whichever amp's status packet arrived most recently"; the
//! full per-amp map is tracked internally (`known_amps`) so a later
//! amp-picker phase has real data to work from, but only the primary's
//! state is exposed over D-Bus right now. On a LAN with more than one amp
//! broadcasting, the exposed properties will visibly flip between them as
//! their ~1s broadcasts interleave - a known, deliberately deferred
//! limitation, not a bug.

mod interface;

use devialet_protocol as proto;
use interface::AmpState;
use socket2::{Domain, Protocol, Socket, Type};
use std::collections::HashMap;
use std::net::{SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

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

struct KnownAmp {
    status: proto::Status,
    last_seen: Instant,
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

    let mut known_amps: HashMap<String, KnownAmp> = HashMap::new();
    let mut primary_ip: Option<String> = None;
    let mut last_emitted_online: Option<bool> = None;
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
                let now = Instant::now();
                known_amps.insert(
                    ip.clone(),
                    KnownAmp {
                        status: status.clone(),
                        last_seen: now,
                    },
                );
                primary_ip = Some(ip.clone());

                let new_state = AmpState::from_status(&status, ip, true);
                apply_and_emit(&iface_ref, &new_state).map_err(std::io::Error::other)?;
                last_emitted_online = Some(true);

                // Item 4: read back through the SAME InterfaceRef the D-Bus
                // property getters are registered against, immediately
                // after writing, to prove this isn't a separate/stale copy.
                if debug {
                    let read_back = iface_ref.get();
                    eprintln!(
                        "[debug] read-back via iface_ref.get() immediately after write: device_name={:?} online={} (should match what was just written: {:?}, true)",
                        read_back.device_name, read_back.online, new_state.device_name
                    );
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {
                if debug {
                    eprintln!("[debug] recv_from: timed out (no packet in {POLL_TICK:?}) - loop is alive, {packets_seen} real packets seen so far");
                }
                // No packet within POLL_TICK - re-check staleness for the
                // primary amp only (Phase 1 scope, see module doc).
                if let Some(ip) = &primary_ip {
                    if let Some(entry) = known_amps.get(ip) {
                        let online = entry.last_seen.elapsed() < proto::STALE_AFTER;
                        if last_emitted_online != Some(online) {
                            let mut state = AmpState::from_status(&entry.status, ip.clone(), online);
                            state.online = online;
                            apply_and_emit(&iface_ref, &state).map_err(std::io::Error::other)?;
                            last_emitted_online = Some(online);
                        }
                    }
                }
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

/// Writes the new state into the registered interface and unconditionally
/// emits every property's `PropertiesChanged` signal. Phase 1 keeps this
/// simple (no before/after diff to decide which fields actually changed) -
/// the amp only broadcasts ~1x/sec, so unconditional re-emission at that
/// rate is cheap; a future pass could diff and emit only changed
/// properties.
fn apply_and_emit(
    iface_ref: &zbus::blocking::object_server::InterfaceRef<AmpState>,
    new_state: &AmpState,
) -> zbus::Result<()> {
    // `<property>_changed` is an inherent async method zbus generates
    // directly on AmpState itself (not a separate trait) - called via the
    // get_mut() guard, mutation and emission both happening while it's
    // held, matching zbus's own documented pattern for this exact case
    // (emitting PropertiesChanged from outside a property setter).
    let mut iface = iface_ref.get_mut();
    *iface = new_state.clone();

    let emitter = iface_ref.signal_emitter();
    async_io::block_on(async {
        iface.device_name_changed(emitter).await?;
        iface.amp_ip_changed(emitter).await?;
        iface.online_changed(emitter).await?;
        iface.power_changed(emitter).await?;
        iface.muted_changed(emitter).await?;
        iface.volume_raw_changed(emitter).await?;
        iface.volume_db_changed(emitter).await?;
        iface.active_source_index_changed(emitter).await?;
        iface.active_source_name_changed(emitter).await?;
        iface.sources_changed(emitter).await?;
        Ok(())
    })
}
