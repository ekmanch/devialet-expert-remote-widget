//! Live read of the default PipeWire/PulseAudio sink's volume and mute
//! state via `pactl`. Logged every tick, never cached - but NOT part of the
//! gain formula (the sink gain applies to chime and media alike, so it
//! cancels; owner decision 2026-09-10). A failed read is a warning, never a
//! reason to skip the chime.
//!
//! `pactl get-sink-volume @DEFAULT_SINK@` prints, on this machine's
//! decimal-comma locale:
//!
//! ```text
//! Volume: front-left: 65536 / 100% / 0,00 dB,   front-right: 65536 / 100% / 0,00 dB
//!         balance 0,00
//! ```
//!
//! The parser takes the first whitespace token that parses as `u32` *and*
//! is followed by a `/` token - which skips channel names and never touches
//! the locale-formatted dB/balance fields. `LC_ALL=C` is set on the child
//! as a belt anyway. `wpctl get-volume` was rejected: it prints a
//! locale-sensitive cubic float, not the raw integer.

use std::process::Command;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SinkState {
    /// Raw `pa_volume_t` of the first channel, 65536 = 100 % / 0 dB.
    pub raw: u32,
    pub muted: bool,
}

pub fn read_default_sink() -> Result<SinkState, String> {
    let volume_out = pactl(&["get-sink-volume", "@DEFAULT_SINK@"])?;
    let mute_out = pactl(&["get-sink-mute", "@DEFAULT_SINK@"])?;
    let raw = parse_sink_volume(&volume_out)
        .ok_or_else(|| format!("could not parse pactl get-sink-volume output: {volume_out:?}"))?;
    let muted = parse_sink_mute(&mute_out)
        .ok_or_else(|| format!("could not parse pactl get-sink-mute output: {mute_out:?}"))?;
    Ok(SinkState { raw, muted })
}

fn pactl(args: &[&str]) -> Result<String, String> {
    let out = Command::new("pactl")
        .args(args)
        .env("LC_ALL", "C")
        .output()
        .map_err(|e| format!("failed to run pactl {}: {e}", args.join(" ")))?;
    if !out.status.success() {
        return Err(format!(
            "pactl {} exited with {}: {}",
            args.join(" "),
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// First integer token immediately followed by a `/` token.
pub fn parse_sink_volume(out: &str) -> Option<u32> {
    let toks: Vec<&str> = out.split_whitespace().collect();
    toks.windows(2)
        .find(|w| w[1] == "/")
        .and_then(|w| w[0].parse::<u32>().ok())
}

/// `Mute: yes` / `Mute: no`.
pub fn parse_sink_mute(out: &str) -> Option<bool> {
    let line = out.lines().find(|l| l.trim_start().starts_with("Mute:"))?;
    match line.trim_start().trim_start_matches("Mute:").trim() {
        "yes" => Some(true),
        "no" => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const COMMA_LOCALE: &str =
        "Volume: front-left: 65536 / 100% / 0,00 dB,   front-right: 65536 / 100% / 0,00 dB\n        balance 0,00\n";
    const C_LOCALE: &str =
        "Volume: front-left: 65536 / 100% / 0.00 dB,   front-right: 65536 / 100% / 0.00 dB\n        balance 0.00\n";
    const HALF: &str =
        "Volume: front-left: 32768 / 50% / -18,06 dB,   front-right: 32768 / 50% / -18,06 dB\n        balance 0,00\n";

    #[test]
    fn parses_comma_locale_line_captured_on_this_box() {
        assert_eq!(parse_sink_volume(COMMA_LOCALE), Some(65536));
    }

    #[test]
    fn parses_c_locale_line() {
        assert_eq!(parse_sink_volume(C_LOCALE), Some(65536));
    }

    #[test]
    fn parses_non_unity_volume() {
        assert_eq!(parse_sink_volume(HALF), Some(32768));
    }

    #[test]
    fn mono_sink_without_channel_name() {
        assert_eq!(parse_sink_volume("Volume: mono: 40000 / 61% / -12,85 dB\n"), Some(40000));
    }

    #[test]
    fn garbage_is_none() {
        assert_eq!(parse_sink_volume(""), None);
        assert_eq!(parse_sink_volume("Failed to get sink information: No such entity\n"), None);
        assert_eq!(parse_sink_volume("Volume: front-left: abc / 100%"), None);
    }

    #[test]
    fn mute_lines() {
        assert_eq!(parse_sink_mute("Mute: no\n"), Some(false));
        assert_eq!(parse_sink_mute("Mute: yes\n"), Some(true));
        assert_eq!(parse_sink_mute("Mute: maybe\n"), None);
        assert_eq!(parse_sink_mute(""), None);
    }
}
