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
//!
//! Phase 3.7: resolves each known amp's real model name over mDNS
//! (`AmpModelNameResolver.kt`'s Devialet-side equivalent), best-effort in
//! the background - see `start_mdns_browse`/`drain_mdns_events` below.
//! Resolution policy (stated explicitly, not left implicit): one
//! continuous `browse()` session is started once at daemon startup for the
//! whole process lifetime, not restarted or re-queried per amp or on any
//! schedule - confirmed by reading `mdns-sd` 0.21.0's own source (not just
//! inferred from its description), `mdns-sd` already re-queries/refreshes
//! its cache internally: `dns_cache.rs`'s `refresh_due_ptr`/
//! `refresh_due_srv_txt`/`refresh_due_hosts` (citing RFC 6762 section 7.1
//! for the refresh timing) are called every iteration of the daemon's own
//! event loop via `refresh_active_services()`
//! (`service_daemon.rs:1622`), which sends real re-queries
//! (`send_query`/`send_query_vec`) whenever a cached record's TTL
//! approaches expiry. Android's `NsdManager` needed
//! `AmpModelNameResolver`'s own manual restart-burst workaround for
//! sluggish re-querying (that mechanism is Android-API-specific, not a
//! general mDNS requirement, so it isn't ported here). Every
//! `ServiceResolved` event the session ever produces is drained
//! non-blockingly and matched against known amps by IP; once an amp
//! resolves, it's never re-attempted or cleared (matches the Kotlin app -
//! see `AmpState::resolve_model_name`'s doc in interface.rs).

mod interface;

use devialet_protocol as proto;
use interface::AmpState;
use mdns_sd::{ServiceDaemon, ServiceEvent};
use socket2::{Domain, Protocol, Socket, Type};
use std::net::{SocketAddr, UdpSocket};
use std::time::Duration;

/// `_spotify-connect._tcp` - not Devialet-specific (see interface.rs's
/// `resolve_model_name` doc for why that's safe: matches are confirmed
/// against known amps before being trusted). Format confirmed against
/// `ServiceDaemon::browse`'s own validation
/// (`check_domain_suffix`/its doc: "must end with a valid mDNS domain:
/// '._tcp.local.' or '._udp.local.'").
const MDNS_SERVICE_TYPE: &str = "_spotify-connect._tcp.local.";

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

/// Starts the mDNS browse session used for Phase 3.7 model-name
/// resolution. Best-effort/cosmetic only, mirroring `AmpModelNameResolver`'s
/// own framing ("this is a cosmetic enhancement, not something the app
/// depends on"): if setup fails for any reason (no usable network
/// interface, permission issue, etc.), this logs a warning and returns
/// `None` - the daemon then runs exactly as it did before this phase
/// existed (raw UDP device names only). Never a fatal startup error.
fn start_mdns_browse() -> Option<mdns_sd::Receiver<ServiceEvent>> {
    let daemon = match ServiceDaemon::new() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("mDNS: failed to start service daemon, model name resolution disabled: {e}");
            return None;
        }
    };
    match daemon.browse(MDNS_SERVICE_TYPE) {
        Ok(receiver) => {
            eprintln!("mDNS: browsing {MDNS_SERVICE_TYPE} for amp model name resolution");
            Some(receiver)
        }
        Err(e) => {
            eprintln!("mDNS: failed to browse {MDNS_SERVICE_TYPE}, model name resolution disabled: {e}");
            None
        }
    }
}

/// Drains every mDNS event currently queued, non-blockingly (`try_recv`
/// returns immediately whether the queue is empty or not) - called once per
/// main-loop iteration, not just once per `POLL_TICK` tick, so a burst of
/// real UDP packets arriving back-to-back (the amp can broadcast up to
/// ~5Hz) can't starve this of a chance to run; either way it never adds any
/// blocking delay to UDP processing, since it's a separate non-blocking
/// check each time, not something UDP receipt waits on.
fn drain_mdns_events(
    receiver: &mdns_sd::Receiver<ServiceEvent>,
    iface_ref: &zbus::blocking::object_server::InterfaceRef<AmpState>,
    debug: bool,
) -> zbus::Result<()> {
    loop {
        let event = match receiver.try_recv() {
            Ok(event) => event,
            Err(_) => return Ok(()), // Empty (or the daemon thread exited) - nothing more to do right now.
        };
        let ServiceEvent::ServiceResolved(resolved) = event else {
            continue;
        };

        // Prefer IPv4 explicitly - same reasoning as
        // AmpModelNameResolver.onServiceResolved: `AmpState::amps` is keyed
        // by IPv4 dotted-quad strings (src.ip() off the IPv4-only socket
        // bound in bind_status_socket), so an IPv6-only match would never
        // find its known-amp entry and get silently dropped by
        // resolve_model_name's membership check - not wrong, just
        // pointless to even attempt.
        let Some(ip) = resolved.addresses.iter().find(|addr| addr.is_ipv4()).map(|addr| addr.to_ip_addr().to_string()) else {
            continue;
        };
        let Some(model_name) = proto::parse_model_name(&resolved.host) else {
            continue;
        };

        let mut iface = iface_ref.get_mut();
        let before = iface.clone();
        let applied = iface.resolve_model_name(&ip, model_name.clone());
        if debug {
            eprintln!(
                "[debug] mDNS: resolved host={:?} -> ip={ip} model_name={model_name:?} (matched a known amp: {applied})",
                resolved.host
            );
        }
        if applied {
            emit_if_changed(iface_ref, &iface, &before)?;
        }
    }
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

    let mdns_receiver = start_mdns_browse();

    let mut packets_seen: u64 = 0;

    let mut buf = [0u8; 2048];
    loop {
        // Runs every iteration (not gated on the WouldBlock/tick branch
        // below) - see drain_mdns_events's own doc for why.
        if let Some(receiver) = &mdns_receiver {
            drain_mdns_events(receiver, &iface_ref, debug).map_err(std::io::Error::other)?;
        }

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
