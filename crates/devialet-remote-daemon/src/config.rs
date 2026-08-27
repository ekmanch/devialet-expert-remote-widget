//! Small on-disk persistence for the explicitly-selected amp IP (Phase
//! 4.2). Plain text, no serde/JSON - matches this workspace's existing
//! "no JSON, nothing here needs it" stance (CLAUDE.md's Environment
//! section) and the file's own trivial shape: a single line holding either
//! an IP or an empty string (a persisted explicit "None" - see
//! `AmpState::set_persisted_selection`'s doc in interface.rs for why that
//! distinction matters).
//!
//! Location: `$XDG_CONFIG_HOME/devialet-remote-daemon/selected-amp-ip`,
//! falling back to `$HOME/.config/devialet-remote-daemon/selected-amp-ip`
//! when `XDG_CONFIG_HOME` is unset or empty - the standard XDG Base
//! Directory fallback (freedesktop.org Base Directory spec: "If
//! $XDG_CONFIG_HOME is either not set or empty, a default equal to
//! $HOME/.config should be used"). No `dirs`/`directories` crate added for
//! this - resolving two env vars doesn't justify a new dependency in a
//! workspace that's otherwise kept deliberately dependency-light (see
//! Cargo.toml's per-dependency justification comments for zbus/socket2/
//! mdns-sd).
//!
//! This module is pure path/file logic, no zbus/D-Bus awareness - callers
//! (`interface.rs`'s `select_amp`, `main.rs`'s startup) decide when to
//! call it, matching this daemon's existing "logic doesn't reach into I/O
//! it doesn't own" shape.

use std::env;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

const CONFIG_SUBDIR: &str = "devialet-remote-daemon";
const CONFIG_FILE: &str = "selected-amp-ip";

/// Pure resolution logic, factored out from `config_dir()` so tests can
/// exercise the XDG-vs-HOME fallback deterministically without mutating
/// real process env vars (which would be racy across parallel `cargo
/// test` threads).
fn resolve_config_dir(xdg_config_home: Option<String>, home: Option<String>) -> Option<PathBuf> {
    if let Some(xdg) = xdg_config_home {
        if !xdg.is_empty() {
            return Some(PathBuf::from(xdg).join(CONFIG_SUBDIR));
        }
    }
    let home = home?;
    if home.is_empty() {
        return None;
    }
    Some(PathBuf::from(home).join(".config").join(CONFIG_SUBDIR))
}

fn config_dir() -> Option<PathBuf> {
    resolve_config_dir(env::var("XDG_CONFIG_HOME").ok(), env::var("HOME").ok())
}

fn config_path() -> Option<PathBuf> {
    config_dir().map(|dir| dir.join(CONFIG_FILE))
}

/// Reads a persisted selection from an explicit path. `None` means
/// "nothing persisted here" (file absent, or unreadable for any other
/// reason - fails open to "never persisted" rather than treating a
/// transient read error as a fatal startup condition). `Some("")` is a
/// real, meaningful result, not an error case.
fn load_from_path(path: &Path) -> Option<String> {
    match fs::read_to_string(path) {
        Ok(contents) => Some(contents.trim().to_string()),
        Err(e) if e.kind() == ErrorKind::NotFound => None,
        Err(e) => {
            eprintln!("config: failed to read {path:?}, ignoring persisted selection: {e}");
            None
        }
    }
}

/// Writes a selection to an explicit path, creating the parent directory
/// if needed. Best-effort - matches this daemon's existing mDNS "cosmetic
/// enhancement, not depended on" framing (main.rs's `start_mdns_browse`
/// doc): a write failure (read-only filesystem, permissions, disk full)
/// is logged and otherwise ignored. `SelectAmp` must still succeed even if
/// persisting it to disk doesn't.
fn save_to_path(path: &Path, ip: &str) {
    let Some(dir) = path.parent() else { return };
    if let Err(e) = fs::create_dir_all(dir) {
        eprintln!("config: failed to create {dir:?}, selection not persisted: {e}");
        return;
    }
    if let Err(e) = fs::write(path, ip) {
        eprintln!("config: failed to write {path:?}, selection not persisted: {e}");
    }
}

/// Loads the persisted selected-amp IP, or `None` if nothing has ever been
/// persisted (first run, pre-Phase-4.2 install, or `$HOME`/
/// `$XDG_CONFIG_HOME` unresolvable). Called once at daemon startup, before
/// the D-Bus object server exists.
pub fn load_selected_ip() -> Option<String> {
    let path = config_path()?;
    load_from_path(&path)
}

/// Persists the selected-amp IP (or `""` for an explicit "None") so it
/// survives a daemon restart. Called from `AmpState::select_amp` on every
/// `SelectAmp` D-Bus call, including `SelectAmp("")`.
pub fn save_selected_ip(ip: &str) {
    let Some(path) = config_path() else {
        eprintln!("config: no usable XDG_CONFIG_HOME/HOME, cannot persist selected amp");
        return;
    };
    save_to_path(&path, ip);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xdg_config_home_takes_precedence_over_home() {
        let dir = resolve_config_dir(Some("/custom/xdg".to_string()), Some("/home/someone".to_string()));
        assert_eq!(dir, Some(PathBuf::from("/custom/xdg/devialet-remote-daemon")));
    }

    #[test]
    fn empty_xdg_config_home_falls_back_to_home_dot_config() {
        // Matches the XDG spec's explicit "not set OR empty" fallback
        // wording - an empty-but-set var must not be treated as a real
        // override.
        let dir = resolve_config_dir(Some(String::new()), Some("/home/someone".to_string()));
        assert_eq!(dir, Some(PathBuf::from("/home/someone/.config/devialet-remote-daemon")));
    }

    #[test]
    fn unset_xdg_config_home_falls_back_to_home_dot_config() {
        let dir = resolve_config_dir(None, Some("/home/someone".to_string()));
        assert_eq!(dir, Some(PathBuf::from("/home/someone/.config/devialet-remote-daemon")));
    }

    #[test]
    fn no_xdg_and_no_home_resolves_to_nothing() {
        assert_eq!(resolve_config_dir(None, None), None);
        assert_eq!(resolve_config_dir(Some(String::new()), None), None);
        assert_eq!(resolve_config_dir(Some(String::new()), Some(String::new())), None);
    }

    fn test_dir(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("devialet-daemon-config-test-{}-{}-{name}", std::process::id(), line!()))
    }

    #[test]
    fn nonexistent_file_loads_as_none_never_persisted() {
        let dir = test_dir("nonexistent");
        let path = dir.join(CONFIG_FILE);
        assert_eq!(load_from_path(&path), None, "a file that was never written must load as None, not Some(\"\")");
    }

    #[test]
    fn round_trips_a_real_ip() {
        let dir = test_dir("roundtrip-ip");
        let path = dir.join(CONFIG_FILE);
        save_to_path(&path, "192.168.1.50");
        assert_eq!(load_from_path(&path), Some("192.168.1.50".to_string()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn round_trips_an_explicit_empty_selection() {
        // The critical case: a persisted "" must load back as Some(""),
        // distinguishable from the nonexistent-file None case above - this
        // is what lets the caller set has_explicit_selection=true for a
        // persisted "None" instead of leaving it at the default false.
        let dir = test_dir("roundtrip-empty");
        let path = dir.join(CONFIG_FILE);
        save_to_path(&path, "");
        assert_eq!(load_from_path(&path), Some(String::new()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_later_save_overwrites_an_earlier_one() {
        let dir = test_dir("overwrite");
        let path = dir.join(CONFIG_FILE);
        save_to_path(&path, "192.168.1.50");
        save_to_path(&path, "192.168.1.51");
        assert_eq!(load_from_path(&path), Some("192.168.1.51".to_string()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn saved_content_is_trimmed_on_load() {
        let dir = test_dir("trim");
        let path = dir.join(CONFIG_FILE);
        fs::create_dir_all(&dir).unwrap();
        fs::write(&path, "192.168.1.50\n").unwrap();
        assert_eq!(load_from_path(&path), Some("192.168.1.50".to_string()));
        let _ = fs::remove_dir_all(&dir);
    }
}
