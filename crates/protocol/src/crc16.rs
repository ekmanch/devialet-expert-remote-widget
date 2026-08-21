/// Core CRC16/CCITT-FALSE bit loop (poly `0x1021`, init `0xFFFF`, no final
/// XOR), for an arbitrary-length input. `crc16_ccitt_false` (the function
/// actually used by the packet builder) always feeds this exactly 12 bytes,
/// but keeping the loop length-generic lets it be checked against the
/// standard published CRC-16/CCITT-FALSE test vector below, which is 9 bytes
/// — there's no real captured 12-byte packet prefix with an independently
/// known CRC to check against yet (see docs/protocol.md's open questions).
fn crc16_ccitt_false_over(data: &[u8]) -> u16 {
    let mut crc: u32 = 0xFFFF;
    for &byte in data {
        crc ^= (byte as u32) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 {
                ((crc << 1) ^ 0x1021) & 0xFFFF
            } else {
                (crc << 1) & 0xFFFF
            };
        }
    }
    crc as u16
}

/// CRC16/CCITT-FALSE over exactly the first 12 bytes of a command packet
/// (offsets 0-11). Ported bit-for-bit from `DevialetController.crc16()` in
/// the Kotlin app — see docs/protocol.md.
pub fn crc16_ccitt_false(bytes_0_to_11: &[u8; 12]) -> u16 {
    crc16_ccitt_false_over(bytes_0_to_11)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Standard published CRC-16/CCITT-FALSE check value: running the
    /// algorithm (poly 0x1021, init 0xFFFF, no refin/refout, no xorout) over
    /// the ASCII bytes of "123456789" must yield 0x29B1. This is the
    /// standard conformance vector for this exact CRC variant (independent
    /// of this codebase or the Devialet protocol), so it validates the bit
    /// loop itself against an external source of truth rather than just
    /// checking the implementation agrees with itself.
    #[test]
    fn matches_standard_ccitt_false_check_value() {
        assert_eq!(crc16_ccitt_false_over(b"123456789"), 0x29B1);
    }

    #[test]
    fn all_zero_12_bytes_is_deterministic() {
        // Expected value computed with an independent Python
        // implementation of this exact algorithm (verified against the
        // standard vector above first) - see scratchpad/reference.py.
        assert_eq!(crc16_ccitt_false(&[0u8; 12]), 0x84F9);
    }

    #[test]
    fn real_power_on_header_crc_is_deterministic() {
        // Real command header: 0x44 0x72 (magic) + counters 0,0 + byte6/7 =
        // power-on (0x01, 0x01) + payload 0x00 0x00 + 2 unused zero bytes.
        // Expected value computed with the same independent Python
        // implementation as above.
        let data: [u8; 12] = [0x44, 0x72, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00];
        assert_eq!(crc16_ccitt_false(&data), 0xA0BD);
    }
}
