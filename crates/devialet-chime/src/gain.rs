//! Pure gain math for the compensated chime - no I/O, fully unit-tested.
//!
//! The chime is meant to sound approximately as loud as the amp *will*
//! sound at the tick's target dB, while the amp is still at its last
//! confirmed dB. Chime and media both pass through the same PipeWire sink
//! gain and the same amp gain, so the sink volume cancels (owner decision,
//! 2026-09-10) and the only per-tick term is the amp's own not-yet-applied
//! delta:
//!
//! ```text
//! delta_db = clamp(target_db - confirmed_db, -DELTA_CLAMP_DB, +DELTA_CLAMP_DB)
//! gain_db  = min(headroom_db + delta_db, 0)
//! V        = clamp(round(PA_VOLUME_NORM * 10^(gain_db / 60)), 0, PA_VOLUME_NORM)
//! ```
//!
//! `V` is what `paplay --volume=` takes: an integer on PulseAudio's *cubic*
//! software-volume scale (`pa_sw_volume_from_dB`: amplitude = (V/65536)^3,
//! so dB -> V uses an exponent of dB/60, not dB/20). The help text's
//! "(linear)" refers to the integer scale, not amplitude. Verified
//! empirically against PipeWire's applied `channelVolumes` in the spike
//! (see TODO.md), not just taken from the PulseAudio source.
//!
//! `headroom_db` is a constant offset so a positive delta (scrolling up
//! faster than the amp confirms) has room under unity. Its absolute value
//! is arbitrary - the same way plasma-pa's tone plays the file at its own
//! fixed level - only the relative compensation between ticks matters. The
//! gain is never allowed above 0 dB, so `V` never exceeds unity and a sign
//! error in the delta is bounded by construction.

/// PulseAudio's `PA_VOLUME_NORM`: 100 %, 0 dB, unity amplitude.
pub const PA_VOLUME_NORM: u32 = 65536;

/// Default constant offset below unity - tune by ear via `--headroom-db`.
// -6.0 at first build, then -3.0, then -1.0; the owner's soaks
// (2026-09-10) found each too quiet and settled on 0: the file plays at
// its own level for a zero delta, exactly as plasma-pa's tone does. Note
// this leaves NO upward compensation - any positive delta clips to unity
// - only downward deltas are compensated.
pub const DEFAULT_HEADROOM_DB: f64 = 0.0;

/// Sanity clamp on |target - confirmed|. A real tick never exceeds a few
/// dB of lag; anything beyond this is a bug upstream, not a real delta.
pub const DELTA_CLAMP_DB: f64 = 20.0;

#[derive(Debug, Clone, PartialEq)]
pub struct Computation {
    /// `target_db - confirmed_db` before clamping (logged for the hand
    /// check).
    pub delta_raw_db: f64,
    /// Clamped to `[-DELTA_CLAMP_DB, +DELTA_CLAMP_DB]`.
    pub delta_db: f64,
    /// `headroom_db + delta_db` before the unity cap (logged).
    pub gain_raw_db: f64,
    /// Capped at 0 dB - what actually goes to `pa_volume_from_db`.
    pub gain_db: f64,
    /// `paplay --volume=` integer, 0..=65536.
    pub volume: u32,
    /// True when `gain_raw_db` exceeded 0 dB and was capped.
    pub clipped_to_unity: bool,
}

pub fn compute(target_db: f64, confirmed_db: f64, headroom_db: f64) -> Computation {
    let delta_raw_db = target_db - confirmed_db;
    let delta_db = delta_raw_db.clamp(-DELTA_CLAMP_DB, DELTA_CLAMP_DB);
    let gain_raw_db = headroom_db + delta_db;
    let clipped_to_unity = gain_raw_db > 0.0;
    let gain_db = gain_raw_db.min(0.0);
    Computation {
        delta_raw_db,
        delta_db,
        gain_raw_db,
        gain_db,
        volume: pa_volume_from_db(gain_db),
        clipped_to_unity,
    }
}

/// `pa_sw_volume_from_dB` semantics: cubic scale, 65536 = 0 dB. Clamped to
/// `0..=PA_VOLUME_NORM` - never above unity by design (see module doc).
pub fn pa_volume_from_db(gain_db: f64) -> u32 {
    if !gain_db.is_finite() {
        return 0;
    }
    let v = (PA_VOLUME_NORM as f64) * 10f64.powf(gain_db / 60.0);
    let v = v.round();
    if v <= 0.0 {
        0
    } else if v >= PA_VOLUME_NORM as f64 {
        PA_VOLUME_NORM
    } else {
        v as u32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn within(a: u32, b: u32, tol: u32) -> bool {
        a.abs_diff(b) <= tol
    }

    #[test]
    fn default_headroom_is_owner_tuned_value() {
        assert_eq!(DEFAULT_HEADROOM_DB, 0.0);
        // Default path: zero delta -> 0 dB -> unity, not flagged as clipped.
        let c = compute(-40.0, -40.0, DEFAULT_HEADROOM_DB);
        assert_eq!(c.volume, 65536);
        assert!(!c.clipped_to_unity);
        // Any upward delta clips at this headroom - by owner decision.
        assert!(compute(-39.0, -40.0, DEFAULT_HEADROOM_DB).clipped_to_unity);
    }

    #[test]
    fn unity_is_65536() {
        assert_eq!(pa_volume_from_db(0.0), 65536);
    }

    #[test]
    fn half_amplitude_on_cubic_scale_is_minus_18_db() {
        // (32768/65536)^3 = 0.125 amplitude = -18.06 dB. If someone "fixes"
        // the exponent to /20 this becomes 32768 * ~0.5 and fails loudly.
        assert!(within(pa_volume_from_db(-18.06), 32768, 2));
    }

    #[test]
    fn minus_six_db_hand_value() {
        // 65536 * 10^(-6/60) = 52057.1
        assert!(within(pa_volume_from_db(-6.0), 52057, 1));
    }

    #[test]
    fn minus_sixty_db_hand_value() {
        // 65536 * 10^(-1) = 6553.6
        assert!(within(pa_volume_from_db(-60.0), 6554, 1));
    }

    #[test]
    fn positive_gain_clamps_to_unity() {
        assert_eq!(pa_volume_from_db(20.0), 65536);
        assert_eq!(pa_volume_from_db(0.1), 65536);
    }

    #[test]
    fn very_negative_gain_is_silent() {
        assert_eq!(pa_volume_from_db(-200.0), 30); // 65536 * 10^(-3.33) = 30.4
        assert_eq!(pa_volume_from_db(-600.0), 0);
        assert_eq!(pa_volume_from_db(f64::NEG_INFINITY), 0);
        assert_eq!(pa_volume_from_db(f64::NAN), 0);
    }

    #[test]
    fn zero_delta_gives_headroom_only() {
        let c = compute(-40.0, -40.0, -6.0);
        assert_eq!(c.delta_db, 0.0);
        assert_eq!(c.gain_db, -6.0);
        assert!(within(c.volume, 52057, 1));
        assert!(!c.clipped_to_unity);
    }

    #[test]
    fn sign_check_higher_target_is_louder() {
        let up = compute(-39.0, -40.0, -6.0);
        let flat = compute(-40.0, -40.0, -6.0);
        let down = compute(-41.0, -40.0, -6.0);
        assert_eq!(up.delta_db, 1.0);
        assert_eq!(up.gain_db, -5.0);
        assert!(within(up.volume, 54094, 1));
        assert!(within(down.volume, 50097, 1));
        assert!(up.volume > flat.volume && flat.volume > down.volume);
    }

    #[test]
    fn delta_clamps_both_ends() {
        let up = compute(-10.0, -40.0, -6.0);
        assert_eq!(up.delta_raw_db, 30.0);
        assert_eq!(up.delta_db, DELTA_CLAMP_DB);
        let down = compute(-70.0, -40.0, -6.0);
        assert_eq!(down.delta_raw_db, -30.0);
        assert_eq!(down.delta_db, -DELTA_CLAMP_DB);
    }

    #[test]
    fn gain_above_unity_is_capped_and_flagged() {
        let c = compute(-30.0, -40.0, -6.0); // +10 - 6 = +4
        assert_eq!(c.gain_raw_db, 4.0);
        assert_eq!(c.gain_db, 0.0);
        assert_eq!(c.volume, 65536);
        assert!(c.clipped_to_unity);
        let exact = compute(-34.0, -40.0, -6.0); // +6 - 6 = 0
        assert_eq!(exact.volume, 65536);
        assert!(!exact.clipped_to_unity);
    }

    #[test]
    fn minus_ten_delta_hand_value() {
        let c = compute(-50.0, -40.0, -6.0); // -16 dB
        assert!(within(c.volume, 35466, 1));
    }
}
