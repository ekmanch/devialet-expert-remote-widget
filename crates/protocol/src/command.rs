use crate::crc16::crc16_ccitt_false;
use crate::dbconvert::db_convert;

/// Fixed size of every command packet (header, counters, CRC, padding),
/// regardless of command type. See docs/protocol.md.
pub const PACKET_LEN: usize = 142;

/// Deliberate safety ceiling (matches Kotlin's `setVolumeDb` default
/// `maxDb`): the amp itself accepts up to +30dB, which is "dangerously
/// loud" on this hardware - see docs/known-gotchas.md #6. Enforced here,
/// not left to a caller/UI layer to remember.
pub const MAX_VOLUME_DB: f64 = -15.0;

/// Forced volume sent after every source switch, overriding the amp's own
/// inconsistent per-input startup volume memory. Not part of the wire
/// protocol itself - a deliberate product decision. See
/// docs/known-gotchas.md #5. Exported so callers (the command CLI) know to
/// send this as a second command after `source_packet`, matching
/// `DevialetController.selectSource()`'s sequencing exactly.
pub const SOURCE_SWITCH_VOLUME_DB: f64 = -40.0;

/// Given the current counter value, returns the next one to use next call,
/// wrapping `0xFFFF -> 0`. Ported from `DevialetController.nextCounter()`.
/// Usage: use `counter` in the packet being built now, then set
/// `counter = next_counter(counter)` for the following call.
pub fn next_counter(current: u16) -> u16 {
    if current == 0xFFFF {
        0
    } else {
        current + 1
    }
}

/// Builds one 142-byte command packet. Pure - no I/O, no implicit counter
/// state; callers supply the exact packet/command counter values to embed.
/// Ported from `DevialetController.buildCommand()`.
pub fn build_command_packet(
    byte6: u8,
    byte7: u8,
    byte8: u8,
    byte9: u8,
    packet_counter: u16,
    command_counter: u16,
) -> [u8; PACKET_LEN] {
    let mut data = [0u8; PACKET_LEN];
    data[0] = 0x44;
    data[1] = 0x72;
    data[2] = (packet_counter >> 8) as u8;
    data[3] = (packet_counter & 0xFF) as u8;
    data[4] = (command_counter >> 8) as u8;
    data[5] = (command_counter & 0xFF) as u8;
    data[6] = byte6;
    data[7] = byte7;
    data[8] = byte8;
    data[9] = byte9;
    // Offsets 10-11 stay zero.

    let first_12: [u8; 12] = data[0..12].try_into().expect("slice is exactly 12 bytes");
    let crc = crc16_ccitt_false(&first_12);
    data[12] = (crc >> 8) as u8;
    data[13] = (crc & 0xFF) as u8;
    // Offsets 14-141 stay zero (padding).

    data
}

/// Power on/off. Ported from `DevialetController.setPower()`.
pub fn power_packet(on: bool, packet_counter: u16, command_counter: u16) -> [u8; PACKET_LEN] {
    build_command_packet(
        if on { 0x01 } else { 0x00 },
        0x01,
        0x00,
        0x00,
        packet_counter,
        command_counter,
    )
}

/// Mute on/off. Ported from `DevialetController.setMute()`.
pub fn mute_packet(muted: bool, packet_counter: u16, command_counter: u16) -> [u8; PACKET_LEN] {
    build_command_packet(
        if muted { 0x01 } else { 0x00 },
        0x07,
        0x00,
        0x00,
        packet_counter,
        command_counter,
    )
}

/// Set volume. Clamps to `MAX_VOLUME_DB` internally (never left to a
/// caller), runs the clamped value through `db_convert`, and sets the sign
/// bit (`0x8000`) when the clamped value is negative. Ported from
/// `DevialetController.setVolumeDb()`.
pub fn volume_packet(db_in: f64, packet_counter: u16, command_counter: u16) -> [u8; PACKET_LEN] {
    let db = db_in.min(MAX_VOLUME_DB);
    let mut vol = db_convert(db);
    if db < 0.0 {
        vol |= 0x8000;
    }
    let hi = (vol >> 8) as u8;
    let lo = (vol & 0xFF) as u8;
    build_command_packet(0x00, 0x04, hi, lo, packet_counter, command_counter)
}

/// Status-broadcast source index (0-14) -> select-source command value.
/// Non-linear, empirically reverse-engineered - **do not** "clean up" or
/// re-derive this from a formula (see docs/known-gotchas.md #3). Unmapped
/// indices fall back to the raw index value, matching
/// `DevialetController.SOURCE_COMMAND_VALUE`'s `?: index` fallback exactly -
/// per docs/protocol.md this fallback is unverified for those indices.
///
/// The match arms below are keyed purely by numeric status index, **not**
/// by source name/type. Real-device testing (2026-08-21, see
/// docs/devialet_source_mapping.md) confirmed this is a fixed hardware-slot
/// association that holds across different amps/configurations, even
/// though what's actually connected/named at a given slot varies per unit:
/// the original per-arm name comments (e.g. "Phono", "UPnP") described one
/// specific reference amp's configuration and are **not** reliable labels
/// in general. Never hardcode a source name based on its status index
/// anywhere in this codebase - always read the name live from the status
/// broadcast (`Status.sources`).
fn source_command_value(status_index: u8) -> i32 {
    match status_index {
        0 => -1,  // hardware slot 0
        2 => 0,   // hardware slot 2
        3 => 3,   // hardware slot 3
        4 => 4,   // hardware slot 4
        5 => 5,   // hardware slot 5
        14 => 14, // hardware slot 14
        other => other as i32,
    }
}

/// Select source, by status-broadcast index (0-14, from the amp's own
/// status packet - *not* a command value, see `source_command_value`).
///
/// Status index 1 is a hardcoded-byte special case that doesn't follow the
/// general bit-packing formula (found via packet capture per
/// docs/protocol.md, not derivable). It was originally labeled "Phono"
/// after the reference amp's configuration at the time - **that name is
/// confirmed stale, not a fixed fact**: real-device testing (2026-08-21,
/// see docs/devialet_source_mapping.md) sent these exact bytes to a
/// different amp, which correctly switched to status index 1 - broadcast
/// by that amp's own status packet as "UPnP", not Phono. The *slot*
/// (index 1) is what's fixed and confirmed correct; the name attached to
/// it is per-unit and must never be hardcoded or assumed from this
/// comment or from docs/protocol.md's example labels. Every other index
/// goes through the index-remap + bit-packing steps ported from
/// `DevialetController.selectSource()`.
///
/// This does **not** send the forced post-switch volume
/// (`SOURCE_SWITCH_VOLUME_DB`) - that's a second, separate command the
/// caller must also send (see `SOURCE_SWITCH_VOLUME_DB`'s docs), since this
/// crate only builds one packet at a time and has no I/O/sequencing.
pub fn source_packet(status_index: u8, packet_counter: u16, command_counter: u16) -> [u8; PACKET_LEN] {
    if status_index == 1 {
        return build_command_packet(0x00, 0x05, 0x3F, 0x80, packet_counter, command_counter);
    }

    let cmd_value = source_command_value(status_index);
    // Ported with i32 arithmetic to match Kotlin's Int (32-bit signed,
    // arithmetic shr) semantics exactly - cmd_value can be -1 (Optical 1).
    let out_val: i32 = 0x4000 | (cmd_value << 5);
    let hi = ((out_val >> 8) & 0xFF) as u8;
    let lo = if cmd_value > 7 {
        ((out_val & 0xFF) >> 1) as u8
    } else {
        (out_val & 0xFF) as u8
    };
    build_command_packet(0x00, 0x05, hi, lo, packet_counter, command_counter)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hdr(counter_bytes: [u8; 4], byte6: u8, byte7: u8, byte8: u8, byte9: u8, crc: [u8; 2]) -> Vec<u8> {
        let mut v = vec![0x44, 0x72];
        v.extend_from_slice(&counter_bytes);
        v.extend_from_slice(&[byte6, byte7, byte8, byte9, 0x00, 0x00]);
        v.extend_from_slice(&crc);
        v
    }

    // All expected bytes below (payload + CRC) computed with an independent
    // Python re-implementation of DevialetController.kt - see
    // scratchpad/reference.py. Source-index 9 and 14 byte8/byte9 values also
    // independently cross-checked against the real-device-confirmed wire
    // bytes recorded in docs/protocol.md ("Source selection encoding").

    #[test]
    fn packet_is_142_bytes_and_zero_padded() {
        let p = power_packet(true, 0, 0);
        assert_eq!(p.len(), PACKET_LEN);
        assert!(p[14..].iter().all(|&b| b == 0));
    }

    #[test]
    fn power_on_off() {
        let on = power_packet(true, 0, 0);
        assert_eq!(&on[..14], hdr([0, 0, 0, 0], 0x01, 0x01, 0x00, 0x00, [0xA0, 0xBD]).as_slice());

        let off = power_packet(false, 0, 0);
        assert_eq!(&off[..14], hdr([0, 0, 0, 0], 0x00, 0x01, 0x00, 0x00, [0xE5, 0x1D]).as_slice());
    }

    #[test]
    fn mute_on_off() {
        let on = mute_packet(true, 0, 0);
        assert_eq!(&on[..14], hdr([0, 0, 0, 0], 0x01, 0x07, 0x00, 0x00, [0x6D, 0x38]).as_slice());

        let off = mute_packet(false, 0, 0);
        assert_eq!(&off[..14], hdr([0, 0, 0, 0], 0x00, 0x07, 0x00, 0x00, [0x28, 0x98]).as_slice());
    }

    #[test]
    fn volume_at_safety_ceiling() {
        let p = volume_packet(-15.0, 0, 0);
        assert_eq!(&p[..14], hdr([0, 0, 0, 0], 0x00, 0x04, 0xC1, 0x70, [0xDB, 0x52]).as_slice());
    }

    #[test]
    fn volume_above_ceiling_is_clamped_down_to_it() {
        // -10dB is "louder" than the -15dB ceiling and must be clamped to
        // produce byte-identical output to requesting -15dB directly.
        let requested_loud = volume_packet(-10.0, 0, 0);
        let at_ceiling = volume_packet(-15.0, 0, 0);
        assert_eq!(requested_loud, at_ceiling);
    }

    #[test]
    fn volume_quieter_than_ceiling_is_not_clamped() {
        // -40dB (the forced post-source-switch volume) is quieter than the
        // -15dB ceiling and must pass through unclamped.
        let p = volume_packet(SOURCE_SWITCH_VOLUME_DB, 0, 0);
        assert_eq!(&p[..14], hdr([0, 0, 0, 0], 0x00, 0x04, 0xC2, 0x20, [0x1E, 0x40]).as_slice());
    }

    #[test]
    fn volume_zero_db_is_clamped_to_ceiling_not_allowed_through() {
        // Regression guard for known-gotchas.md #6: 0dB must never reach
        // the wire - it has to come out byte-identical to the -15dB ceiling.
        let zero = volume_packet(0.0, 0, 0);
        let ceiling = volume_packet(-15.0, 0, 0);
        assert_eq!(zero, ceiling);
    }

    #[test]
    fn source_index_1_hardcoded_bytes() {
        // Status index 1 - hardcoded 0x3F 0x80, not the general formula.
        // Originally labeled "Phono"; confirmed via real-device testing
        // (2026-08-21, docs/devialet_source_mapping.md) to be a fixed
        // hardware slot, not necessarily connected to a phono input on
        // every amp - the wire bytes are what's fixed, not the name.
        let p = source_packet(1, 0, 0);
        assert_eq!(&p[..14], hdr([0, 0, 0, 0], 0x00, 0x05, 0x3F, 0x80, [0xAF, 0x46]).as_slice());
    }

    /// Regression test for known-gotchas.md #3: "Wrong source selected -
    /// Optical 1 selection played Roon Ready instead". The bug was passing
    /// the raw status-broadcast index straight through as the command
    /// value. This asserts the full mapped table produces the
    /// known-correct, non-linear command bytes - if source_command_value
    /// were ever "simplified" back to an identity function (index ==
    /// command value), every assertion except index 2 would fail.
    ///
    /// The inline names below are known-gotchas.md's own historical labels
    /// for these indices at the time bug #3 was found - kept for
    /// readability, not as a claim about what's connected at each index on
    /// any given amp (see docs/devialet_source_mapping.md - those labels
    /// are confirmed per-unit, not universal). Only the numeric index and
    /// expected bytes are asserted.
    #[test]
    fn source_index_to_command_value_regression_bug_3() {
        let cases: &[(u8, u8, u8)] = &[
            // (status_index, expected byte8, expected byte9)
            (0, 0xFF, 0xE0),  // Optical 1  -> cmd_value -1 (NOT index 0's own bytes)
            (2, 0x40, 0x00),  // UPnP       -> cmd_value 0
            (3, 0x40, 0x60),  // Roon Ready -> cmd_value 3
            (4, 0x40, 0x80),  // AirPlay    -> cmd_value 4
            (5, 0x40, 0xA0),  // Spotify    -> cmd_value 5
            (14, 0x41, 0x60), // Air (BT)   -> cmd_value 14
        ];
        for &(status_index, expected_hi, expected_lo) in cases {
            let p = source_packet(status_index, 0, 0);
            assert_eq!(
                (p[8], p[9]),
                (expected_hi, expected_lo),
                "status_index {status_index} produced wrong command bytes"
            );
        }
    }

    /// Cross-checked directly against docs/protocol.md's real-device
    /// findings: sending status index 9 (unmapped -> raw-index fallback,
    /// cmd_value 9) produced wire bytes 0x41 0x10; status index 14
    /// (cmd_value 14, the confirmed Air/Bluetooth mapping) produced 0x41
    /// 0x60 - these are the *only* two wire-byte values independently
    /// confirmed against a physical amp in the source docs, not just
    /// derived from the formula.
    #[test]
    fn source_bytes_match_real_device_confirmed_values() {
        let index_9 = source_packet(9, 0, 0);
        assert_eq!((index_9[8], index_9[9]), (0x41, 0x10));

        let index_14 = source_packet(14, 0, 0);
        assert_eq!((index_14[8], index_14[9]), (0x41, 0x60));
    }

    #[test]
    fn unmapped_source_index_falls_back_to_raw_index() {
        // Index 9 isn't in SOURCE_COMMAND_VALUE - falls back to cmd_value =
        // 9 directly (the ">7" bit-packing branch applies). Docs flag this
        // fallback path as unverified for *meaning* (does it select
        // anything sensible on the amp), but the wire-byte *value* it
        // produces is deterministic and this is what regresses if the
        // fallback logic changes.
        let p = source_packet(9, 0, 0);
        assert_eq!((p[8], p[9]), (0x41, 0x10));
    }

    #[test]
    fn counters_are_embedded_big_endian_and_independent_of_payload() {
        let p = power_packet(true, 0x0102, 0x0304);
        assert_eq!(&p[2..6], &[0x01, 0x02, 0x03, 0x04]);
    }

    #[test]
    fn counter_wraps_at_0xffff() {
        assert_eq!(next_counter(0xFFFE), 0xFFFF);
        assert_eq!(next_counter(0xFFFF), 0x0000);
        assert_eq!(next_counter(0x0000), 0x0001);
    }

    #[test]
    fn same_logical_command_with_different_counters_has_different_crc() {
        // Mirrors DevialetController.sendTwice(): the two wire copies of
        // "the same" command do NOT have identical bytes, since counters
        // (and therefore the CRC) differ between them.
        let first = power_packet(true, 0, 0);
        let second = power_packet(true, 1, 1);
        assert_ne!(first, second);
        assert_eq!(&first[6..10], &second[6..10]); // same command bytes
    }
}
