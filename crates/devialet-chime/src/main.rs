//! `devialet-chime` - single-shot, gain-compensated volume-feedback chime.
//!
//! Spike (branch `spike/volume-audio-feedback`, see TODO.md's spike entry
//! and Phase 10.0.0 findings). Invoked from QML per discrete wheel tick via
//! `Plasma5Support.DataSource`'s executable engine, exactly like
//! `devialet-ctl`, and like it this binary never talks to the daemon or
//! D-Bus - the QML caller supplies both dB values it already holds:
//!
//! ```text
//! devialet-chime --target-db <db> --confirmed-db <db>
//!                [--headroom-db <db>] [--file <path>] [--tick <n>] [--dry-run]
//! ```
//!
//! - `--target-db`: the optimistic value this tick is scrolling to (the
//!   same number the OSD label shows).
//! - `--confirmed-db`: the amp's real last-broadcast dB (decoded from the
//!   daemon's unmasked `VolumeRaw`, never the 400 ms pending mask).
//! - `--headroom-db`: constant offset below unity, default 0 (gain.rs).
//! - `--file`: chime file. Default: the `audio-volume-change` sound of the
//!   theme kdeglobals `[Sounds] Theme` names (theme.rs) - the same file
//!   Audio Devices plays - falling back to ocean, then freedesktop.
//! - `--tick`: opaque counter from QML, only echoed in the log line. It
//!   exists to make every command string unique: Plasma's executable
//!   engine keys running jobs by command string process-wide, so two ticks
//!   with identical dB arguments would otherwise collapse into one process
//!   and the second chime would never play.
//! - `--dry-run`: compute and log, play nothing. Used for the hand check
//!   of expected vs computed volume before any live test.
//!
//! One stderr line per invocation carries every intermediate value; this is
//! the trail `journalctl --user | grep devialet-chime` relies on.

mod gain;
mod play;
mod sink;
mod theme;

use std::process::ExitCode;

#[derive(Debug, PartialEq)]
struct Args {
    target_db: f64,
    confirmed_db: f64,
    headroom_db: f64,
    /// `None` = resolve from the configured sound theme at run time.
    file: Option<String>,
    tick: Option<u64>,
    dry_run: bool,
}

fn usage() -> String {
    "usage: devialet-chime --target-db <db> --confirmed-db <db> [--headroom-db <db>] [--file <path>] [--tick <n>] [--dry-run]".to_string()
}

fn parse_args() -> Result<Args, String> {
    parse_args_from(std::env::args().skip(1).collect())
}

/// Pure parser over argv[1..] - unit-testable without a process. Accepts
/// both `--flag value` and `--flag=value`. The value after a known flag is
/// consumed unconditionally, so negative numbers (`--target-db -39.5`)
/// are fine as separate argv words.
fn parse_args_from(raw: Vec<String>) -> Result<Args, String> {
    let mut target_db = None;
    let mut confirmed_db = None;
    let mut headroom_db = gain::DEFAULT_HEADROOM_DB;
    let mut file = None;
    let mut tick = None;
    let mut dry_run = false;

    let mut i = 0;
    while i < raw.len() {
        let arg = raw[i].as_str();
        // Split `--flag=value` into (flag, Some(value)); otherwise the value
        // is raw[i + 1].
        let (flag, inline) = match arg.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f, Some(v.to_string())),
            _ => (arg, None),
        };
        let mut take_value = |name: &str| -> Result<String, String> {
            if let Some(v) = &inline {
                return Ok(v.clone());
            }
            let v = raw
                .get(i + 1)
                .ok_or_else(|| format!("{name} requires a value\n\n{}", usage()))?;
            i += 1;
            Ok(v.clone())
        };
        match flag {
            "--target-db" => target_db = Some(parse_f64(&take_value("--target-db")?, "--target-db")?),
            "--confirmed-db" => confirmed_db = Some(parse_f64(&take_value("--confirmed-db")?, "--confirmed-db")?),
            "--headroom-db" => headroom_db = parse_f64(&take_value("--headroom-db")?, "--headroom-db")?,
            "--file" => file = Some(take_value("--file")?),
            "--tick" => {
                let v = take_value("--tick")?;
                tick = Some(
                    v.parse::<u64>()
                        .map_err(|_| format!("expected an integer for --tick, got {v:?}"))?,
                );
            }
            "--dry-run" => {
                if inline.is_some() {
                    return Err(format!("--dry-run takes no value\n\n{}", usage()));
                }
                dry_run = true;
            }
            other => return Err(format!("unknown argument {other:?}\n\n{}", usage())),
        }
        i += 1;
    }

    Ok(Args {
        target_db: target_db.ok_or_else(|| format!("--target-db is required\n\n{}", usage()))?,
        confirmed_db: confirmed_db.ok_or_else(|| format!("--confirmed-db is required\n\n{}", usage()))?,
        headroom_db,
        file,
        tick,
        dry_run,
    })
}

fn parse_f64(v: &str, name: &str) -> Result<f64, String> {
    let n = v
        .parse::<f64>()
        .map_err(|_| format!("expected a number for {name}, got {v:?}"))?;
    if !n.is_finite() {
        return Err(format!("expected a finite number for {name}, got {v:?}"));
    }
    Ok(n)
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(a) => a,
        Err(msg) => {
            eprintln!("{msg}");
            return ExitCode::FAILURE;
        }
    };

    // Live every tick, never cached. Not in the formula - logged so the
    // trail shows what the chime actually went out through.
    let sink = match sink::read_default_sink() {
        Ok(s) => Some(s),
        Err(e) => {
            eprintln!("devialet-chime: warn: sink read failed, continuing: {e}");
            None
        }
    };

    let c = gain::compute(args.target_db, args.confirmed_db, args.headroom_db);

    // Same lookup Audio Devices' tone makes (theme.rs), unless overridden.
    let configured = theme::configured_theme();
    let (file, theme_used) = match &args.file {
        Some(f) => (f.clone(), "override".to_string()),
        None => match theme::resolve(std::path::Path::new(theme::SOUNDS_DIR), &configured) {
            Some((p, t)) => (p.to_string_lossy().into_owned(), t),
            None => {
                eprintln!("devialet-chime: no audio-volume-change.oga found under {} for theme {configured:?} or its fallbacks", theme::SOUNDS_DIR);
                return ExitCode::FAILURE;
            }
        },
    };

    let (sink_raw, sink_muted) = match sink {
        Some(s) => (s.raw.to_string(), if s.muted { "yes" } else { "no" }.to_string()),
        None => ("unknown".to_string(), "unknown".to_string()),
    };
    eprintln!(
        "devialet-chime: tick={} target={:.1} confirmed={:.1} delta={:+.1} delta_clamped={:+.1} headroom={:+.1} gain_raw={:+.2} gain_db={:+.2} sink_raw={} sink_muted={} volume={} mode={} theme={} file={}",
        args.tick.map(|t| t.to_string()).unwrap_or_else(|| "-".to_string()),
        args.target_db,
        args.confirmed_db,
        c.delta_raw_db,
        c.delta_db,
        args.headroom_db,
        c.gain_raw_db,
        c.gain_db,
        sink_raw,
        sink_muted,
        c.volume,
        if args.dry_run { "dry-run" } else { "play" },
        theme_used,
        file,
    );
    if c.delta_raw_db != c.delta_db {
        eprintln!("devialet-chime: warn: delta {:+.1} dB clamped to {:+.1} dB", c.delta_raw_db, c.delta_db);
    }
    if c.clipped_to_unity {
        eprintln!("devialet-chime: warn: gain {:+.2} dB > 0, clipped to unity (volume 65536)", c.gain_raw_db);
    }
    if theme_used != "override" && theme_used != configured {
        eprintln!("devialet-chime: warn: configured sound theme {configured:?} has no audio-volume-change.oga, using {theme_used:?}");
    }
    if let Some(s) = sink {
        if s.raw != gain::PA_VOLUME_NORM {
            eprintln!("devialet-chime: warn: default sink volume is {} not 65536 (not compensated - sink cancels)", s.raw);
        }
        if s.muted {
            eprintln!("devialet-chime: warn: default sink is muted - chime will be inaudible");
        }
    }

    if args.dry_run {
        return ExitCode::SUCCESS;
    }
    play::play(c.volume, &file)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Result<Args, String> {
        parse_args_from(list.iter().map(|s| s.to_string()).collect())
    }

    #[test]
    fn minimal_separate_words_with_negative_values() {
        let a = args(&["--target-db", "-39.5", "--confirmed-db", "-40.0"]).unwrap();
        assert_eq!(a.target_db, -39.5);
        assert_eq!(a.confirmed_db, -40.0);
        assert_eq!(a.headroom_db, gain::DEFAULT_HEADROOM_DB);
        assert_eq!(a.file, None);
        assert_eq!(a.tick, None);
        assert!(!a.dry_run);
    }

    #[test]
    fn equals_form() {
        let a = args(&["--target-db=-39.0", "--confirmed-db=-40", "--headroom-db=0", "--tick=7", "--dry-run"]).unwrap();
        assert_eq!(a.target_db, -39.0);
        assert_eq!(a.confirmed_db, -40.0);
        assert_eq!(a.headroom_db, 0.0);
        assert_eq!(a.tick, Some(7));
        assert!(a.dry_run);
    }

    #[test]
    fn qml_shaped_invocation() {
        // Exactly what maybeChime() builds.
        let a = args(&["--target-db", "-44.0", "--confirmed-db", "-45.0", "--tick", "3"]).unwrap();
        assert_eq!(a.tick, Some(3));
        assert!(!a.dry_run);
    }

    #[test]
    fn missing_required_flags() {
        assert!(args(&["--target-db", "-40"]).unwrap_err().contains("--confirmed-db is required"));
        assert!(args(&["--confirmed-db", "-40"]).unwrap_err().contains("--target-db is required"));
        assert!(args(&[]).unwrap_err().contains("required"));
    }

    #[test]
    fn missing_value_and_bad_values() {
        assert!(args(&["--target-db"]).unwrap_err().contains("requires a value"));
        assert!(args(&["--target-db", "x", "--confirmed-db", "-40"]).unwrap_err().contains("expected a number"));
        assert!(args(&["--target-db", "nan", "--confirmed-db", "-40"]).unwrap_err().contains("finite"));
        assert!(args(&["--target-db", "-40", "--confirmed-db", "-40", "--tick", "-1"]).unwrap_err().contains("--tick"));
    }

    #[test]
    fn unknown_argument_rejected() {
        assert!(args(&["--target-db", "-40", "--confirmed-db", "-40", "--loud"]).unwrap_err().contains("unknown argument"));
        assert!(args(&["--target-db", "-40", "--confirmed-db", "-40", "--dry-run=yes"]).unwrap_err().contains("takes no value"));
    }
}
