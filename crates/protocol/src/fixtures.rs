//! Synthetic status-packet construction for tests, in this crate and in
//! downstream crates (`devialet-remote-daemon`'s multi-amp tracking tests in
//! particular). Not gated behind `#[cfg(test)]` so it's usable across crate
//! boundaries - it has zero I/O and negligible size, same as the rest of
//! this crate, so there's no real cost to always compiling it in.
//!
//! Mirrors the exact offsets from docs/protocol.md /
//! `DevialetStatusListener.parseStatus()` - kept in sync with `parse_status`
//! by construction, since `status.rs`'s own tests build fixtures with this
//! same builder and round-trip them through `parse_status`.

use crate::status::STATUS_MIN_LEN;

/// Builds a synthetic, minimum-length (566 byte) status packet with
/// controllable fields. Only the fields tests actually need to set are
/// exposed; unset fields keep their zero-value defaults (empty name, source
/// slot disabled, power/mute off, volume 0).
pub struct StatusFixtureBuilder {
    data: Vec<u8>,
}

impl StatusFixtureBuilder {
    pub fn new() -> Self {
        Self {
            data: vec![0u8; STATUS_MIN_LEN],
        }
    }

    pub fn device_name(mut self, name: &str) -> Self {
        let bytes = name.as_bytes();
        assert!(bytes.len() <= 31);
        self.data[19..19 + bytes.len()].copy_from_slice(bytes);
        self
    }

    pub fn source(mut self, i: usize, name: &str, enabled: bool) -> Self {
        let base = 52 + i * 17;
        self.data[base] = if enabled { b'1' } else { b'0' };
        let bytes = name.as_bytes();
        assert!(bytes.len() <= 16);
        self.data[base + 1..base + 1 + bytes.len()].copy_from_slice(bytes);
        self
    }

    pub fn power(mut self, on: bool) -> Self {
        if on {
            self.data[562] |= 0x80;
        } else {
            self.data[562] &= !0x80;
        }
        self
    }

    pub fn muted(mut self, muted: bool) -> Self {
        if muted {
            self.data[563] |= 0x02;
        } else {
            self.data[563] &= !0x02;
        }
        self
    }

    pub fn active_source_index(mut self, index: u8) -> Self {
        assert!(index <= 15);
        self.data[563] = (self.data[563] & !0x3C) | ((index << 2) & 0x3C);
        self
    }

    pub fn volume_raw(mut self, v: u8) -> Self {
        self.data[565] = v;
        self
    }

    pub fn build(self) -> Vec<u8> {
        self.data
    }
}

impl Default for StatusFixtureBuilder {
    fn default() -> Self {
        Self::new()
    }
}
