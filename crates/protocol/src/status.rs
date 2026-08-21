/// Minimum status packet length the amp is ever expected to send; anything
/// shorter is treated as malformed/irrelevant and dropped, no error
/// surfaced beyond that. Ported from `DevialetStatusListener.parseStatus()`.
pub const STATUS_MIN_LEN: usize = 566;

/// Fixed number of source slots in every status broadcast, regardless of
/// how many the amp actually reports as enabled.
pub const SOURCE_SLOTS: usize = 30;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Source {
    pub name: String,
    pub index: u8,
    pub enabled: bool,
    pub selected: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Status {
    pub device_name: String,
    pub power_on: bool,
    pub muted: bool,
    /// Raw 0-255 byte from the status packet - see `volume_db` for the
    /// decoded dB value. Kept alongside the decoded value since it's useful
    /// for debugging/manual verification (busctl etc.) independent of the
    /// dB formula.
    pub volume_raw: u8,
    pub source_index: u8,
    /// Always exactly `SOURCE_SLOTS` (30) entries, including disabled ones -
    /// matches the amp's fixed-size broadcast layout. Use `enabled_sources`
    /// to filter.
    pub sources: Vec<Source>,
}

impl Status {
    /// Status-broadcast volume decoding. **Not the inverse of
    /// `command::volume_packet`'s `db_convert`** - two independently
    /// reverse-engineered encodings for two different packet directions, do
    /// not assume symmetry. Ported from `DevialetStatus.volumeDb`.
    pub fn volume_db(&self) -> f64 {
        (self.volume_raw as f64 - 195.0) / 2.0
    }

    pub fn current_source_name(&self) -> Option<&str> {
        self.sources
            .get(self.source_index as usize)
            .map(|s| s.name.as_str())
    }

    pub fn enabled_sources(&self) -> impl Iterator<Item = &Source> {
        self.sources.iter().filter(|s| s.enabled)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TooShort {
    pub len: usize,
}

/// Parses one status broadcast packet. Ported from
/// `DevialetStatusListener.parseStatus()`. Only structural failure (packet
/// too short) is a hard error - trimmed name fields simply become the empty
/// string rather than erroring, and any invalid UTF-8 in a name field is
/// lossily replaced rather than rejecting the packet, matching the original
/// broad "catch anything, drop the packet, keep the listener running"
/// behavior without needing a catch-all error path (every index this
/// function reads is bounds-checked by the length check up front, so there
/// is no possible panic path left to guard against, unlike the Kotlin
/// version's explicit try/catch).
pub fn parse_status(data: &[u8]) -> Result<Status, TooShort> {
    if data.len() < STATUS_MIN_LEN {
        return Err(TooShort { len: data.len() });
    }

    let device_name = trimmed_utf8(&data[19..19 + 31]);
    let source_index = (data[563] & 0x3C) >> 2;

    let mut sources = Vec::with_capacity(SOURCE_SLOTS);
    for i in 0..SOURCE_SLOTS as u8 {
        let base = 52 + (i as usize) * 17;
        let enabled = data[base] == b'1';
        let name = trimmed_utf8(&data[base + 1..base + 1 + 16]);
        sources.push(Source {
            name,
            index: i,
            enabled,
            selected: i == source_index,
        });
    }

    let power_on = data[562] & 0x80 != 0;
    let muted = data[563] & 0x02 != 0;
    let volume_raw = data[565];

    Ok(Status {
        device_name,
        power_on,
        muted,
        volume_raw,
        source_index,
        sources,
    })
}

fn trimmed_utf8(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .trim_matches(|c: char| c == '\u{0}' || c == ' ')
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a synthetic, minimum-length (566 byte) status packet with
    /// controllable fields, mirroring the exact offsets from
    /// docs/protocol.md / DevialetStatusListener.parseStatus(). Test-only.
    struct FixtureBuilder {
        data: Vec<u8>,
    }

    impl FixtureBuilder {
        fn new() -> Self {
            Self {
                data: vec![0u8; STATUS_MIN_LEN],
            }
        }

        fn device_name(mut self, name: &str) -> Self {
            let bytes = name.as_bytes();
            assert!(bytes.len() <= 31);
            self.data[19..19 + bytes.len()].copy_from_slice(bytes);
            self
        }

        fn source(mut self, i: usize, name: &str, enabled: bool) -> Self {
            let base = 52 + i * 17;
            self.data[base] = if enabled { b'1' } else { b'0' };
            let bytes = name.as_bytes();
            assert!(bytes.len() <= 16);
            self.data[base + 1..base + 1 + bytes.len()].copy_from_slice(bytes);
            self
        }

        fn power(mut self, on: bool) -> Self {
            if on {
                self.data[562] |= 0x80;
            } else {
                self.data[562] &= !0x80;
            }
            self
        }

        fn muted(mut self, muted: bool) -> Self {
            if muted {
                self.data[563] |= 0x02;
            } else {
                self.data[563] &= !0x02;
            }
            self
        }

        fn active_source_index(mut self, index: u8) -> Self {
            assert!(index <= 15);
            self.data[563] = (self.data[563] & !0x3C) | ((index << 2) & 0x3C);
            self
        }

        fn volume_raw(mut self, v: u8) -> Self {
            self.data[565] = v;
            self
        }

        fn build(self) -> Vec<u8> {
            self.data
        }
    }

    #[test]
    fn too_short_packet_is_rejected() {
        let short = vec![0u8; STATUS_MIN_LEN - 1];
        assert_eq!(parse_status(&short), Err(TooShort { len: STATUS_MIN_LEN - 1 }));
    }

    #[test]
    fn minimum_length_packet_is_accepted() {
        let data = FixtureBuilder::new().build();
        assert_eq!(data.len(), STATUS_MIN_LEN);
        assert!(parse_status(&data).is_ok());
    }

    #[test]
    fn device_name_is_trimmed_of_nul_and_space_padding() {
        let data = FixtureBuilder::new().device_name("My Devialet-ETH").build();
        let status = parse_status(&data).unwrap();
        assert_eq!(status.device_name, "My Devialet-ETH");
    }

    #[test]
    fn power_and_mute_bits_decode_independently() {
        let data = FixtureBuilder::new().power(true).muted(true).build();
        let status = parse_status(&data).unwrap();
        assert!(status.power_on);
        assert!(status.muted);

        let data_off = FixtureBuilder::new().power(false).muted(false).build();
        let status_off = parse_status(&data_off).unwrap();
        assert!(!status_off.power_on);
        assert!(!status_off.muted);
    }

    #[test]
    fn volume_raw_decodes_to_documented_db_formula() {
        // (volumeInt - 195) / 2.0 - deliberately NOT the inverse of
        // command::db_convert, see Status::volume_db's doc comment.
        let data = FixtureBuilder::new().volume_raw(195).build();
        assert_eq!(parse_status(&data).unwrap().volume_db(), 0.0);

        let data = FixtureBuilder::new().volume_raw(165).build();
        assert_eq!(parse_status(&data).unwrap().volume_db(), -15.0);
    }

    #[test]
    fn all_30_source_slots_are_present_including_disabled_ones() {
        let data = FixtureBuilder::new()
            .source(0, "Optical 1", true)
            .source(1, "Phono", false)
            .build();
        let status = parse_status(&data).unwrap();
        assert_eq!(status.sources.len(), SOURCE_SLOTS);
        assert_eq!(status.sources[0].name, "Optical 1");
        assert!(status.sources[0].enabled);
        assert_eq!(status.sources[1].name, "Phono");
        assert!(!status.sources[1].enabled);
        // Untouched slots are present but blank/disabled, not absent.
        assert_eq!(status.sources[2].name, "");
        assert!(!status.sources[2].enabled);
    }

    #[test]
    fn enabled_sources_filters_disabled_slots() {
        let data = FixtureBuilder::new()
            .source(0, "Optical 1", true)
            .source(1, "Phono", false)
            .source(2, "UPnP", true)
            .build();
        let status = parse_status(&data).unwrap();
        let enabled: Vec<&str> = status.enabled_sources().map(|s| s.name.as_str()).collect();
        assert_eq!(enabled, vec!["Optical 1", "UPnP"]);
    }

    #[test]
    fn active_source_index_marks_matching_slot_selected() {
        let data = FixtureBuilder::new()
            .source(3, "Roon Ready", true)
            .active_source_index(3)
            .build();
        let status = parse_status(&data).unwrap();
        assert_eq!(status.source_index, 3);
        assert!(status.sources[3].selected);
        assert!(!status.sources[0].selected);
        assert_eq!(status.current_source_name(), Some("Roon Ready"));
    }
}
