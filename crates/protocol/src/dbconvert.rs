/// Devialet's custom recursive dB -> 16-bit volume-word encoding, ported
/// from `DevialetController.dbConvert()` (Kotlin):
///
/// ```text
/// dbConvert(0.0)  == 0x0000
/// dbConvert(0.5)  == 0x3F00
/// dbConvert(|db|) == (256 >> ceil(1 + ln(|db|)/ln(2))) + dbConvert(|db| - 0.5)
/// ```
///
/// Sign is *not* applied here (matching the Kotlin function, which `abs()`s
/// its input) - callers OR in the `0x8000` sign bit themselves, see
/// `command::volume_packet`.
///
/// Implementation note (deliberate deviation from a literal transcription):
/// the Kotlin formula recurses on exact `f64` equality to `0.0`/`0.5`, which
/// only terminates because its only caller feeds it values from a UI
/// restricted to 0.5dB steps. A CLI accepting an arbitrary `--volume` float
/// has no such guarantee, and a non-multiple-of-0.5 input would recurse
/// forever (crashing the process) under a literal port. This implementation
/// rounds the input to the nearest 0.5dB step *before* running the
/// recursion, then recurses on an integer step count instead of a float, so
/// it terminates for any input while producing byte-identical output to the
/// original formula for every value the original code could ever actually
/// produce (i.e. every exact 0.5dB step).
pub fn db_convert(db_value: f64) -> u16 {
    let steps = (db_value.abs() / 0.5).round().max(0.0) as u32;
    db_convert_steps(steps)
}

fn db_convert_steps(steps: u32) -> u16 {
    match steps {
        0 => 0x0000,
        1 => 0x3F00,
        n => {
            let db_abs = n as f64 * 0.5;
            // Ported literally: `ceil(1 + ln(db_abs) / ln(2.0))`. `ln(2.0)`
            // is computed at runtime (not a precomputed constant) to mirror
            // the Kotlin call `ln(2.0)` as closely as floating point allows.
            let shift = (1.0 + db_abs.ln() / 2.0_f64.ln()).ceil();
            let term: u16 = if (0.0..32.0).contains(&shift) {
                (256u32 >> (shift as u32)) as u16
            } else {
                // Out of the range this formula was ever exercised at
                // (only reachable at extreme |db| far beyond the -15dB
                // safety ceiling or realistic amp range) - fail safe to 0
                // rather than a shift-amount panic.
                0
            };
            term.wrapping_add(db_convert_steps(n - 1))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Expected values computed with an independent Python re-implementation
    // of the literal Kotlin formula (float recursion, no step-rounding) at
    // exact 0.5dB multiples - see scratchpad/reference.py. Confirms the
    // step-based implementation above is byte-identical to the original
    // formula at every value the original code could produce.
    #[test]
    fn matches_reference_at_exact_half_db_steps() {
        assert_eq!(db_convert(0.0), 0x0000);
        assert_eq!(db_convert(0.5), 0x3F00);
        assert_eq!(db_convert(1.0), 0x3F80);
        assert_eq!(db_convert(1.5), 0x3FC0);
        assert_eq!(db_convert(2.0), 0x4000);
        assert_eq!(db_convert(4.0), 0x4080);
        assert_eq!(db_convert(8.0), 0x4100);
        assert_eq!(db_convert(15.0), 0x4170);
        assert_eq!(db_convert(40.0), 0x4220);
    }

    #[test]
    fn negative_input_uses_absolute_value() {
        // dbConvert itself never applies the sign bit - abs() only.
        assert_eq!(db_convert(-15.0), db_convert(15.0));
    }

    #[test]
    fn non_half_step_input_rounds_instead_of_hanging() {
        // -15.3 isn't an exact 0.5dB step; a literal port of the Kotlin
        // recursion would never hit the 0.0/0.5 base case and recurse
        // forever. This must terminate (and round to the nearest step,
        // -15.5 -> same encoding as db_convert(15.5)).
        assert_eq!(db_convert(-15.3), db_convert(15.5));
    }
}
