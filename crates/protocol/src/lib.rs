//! Devialet Expert / Expert Pro UDP protocol: packet encode/decode.
//!
//! Zero I/O by design - no sockets, no files, no async, no D-Bus. Pure
//! `Command -> [u8; 142]` and `&[u8] -> Result<Status, TooShort>` functions,
//! so this crate is unit-testable without a network or a physical amp. See
//! docs/protocol.md (spec) and docs/known-gotchas.md (bugs already found
//! and fixed once - don't reintroduce them) in the widget repo.
//!
//! Daemon and command-CLI binaries are thin I/O shims around this crate;
//! neither reimplements any encoding/decoding logic of their own.

mod command;
mod crc16;
mod dbconvert;
mod status;

pub use command::{
    build_command_packet, mute_packet, next_counter, power_packet, source_packet, volume_packet,
    MAX_VOLUME_DB, PACKET_LEN, SOURCE_SWITCH_VOLUME_DB,
};
pub use crc16::crc16_ccitt_false;
pub use dbconvert::db_convert;
pub use status::{parse_status, Source, Status, TooShort, SOURCE_SLOTS, STATUS_MIN_LEN};

/// Amp -> app status broadcast port. Ported from
/// `DevialetController.STATUS_PORT`.
pub const STATUS_PORT: u16 = 45454;

/// App -> amp command port. Ported from `DevialetController.COMMAND_PORT`.
pub const COMMAND_PORT: u16 = 45455;

/// App-side-only staleness threshold: an amp not heard from for this long
/// is treated as offline. Not a protocol feature - matches
/// `MainActivity.ampStaleTimeoutMs`.
pub const STALE_AFTER: std::time::Duration = std::time::Duration::from_secs(8);
