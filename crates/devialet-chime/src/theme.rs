//! Resolve the chime file the way KDE's own Audio Devices tone does:
//! plasma-pa's `SoundThemeConfig` reads `kdeglobals [Sounds] Theme`
//! (default "ocean") and libcanberra then plays
//! `/usr/share/sounds/<theme>/stereo/audio-volume-change.oga` (Phase
//! 10.0.0 Finding 4). The first build hardcoded ocean per the brief; the
//! owner's soak (2026-09-10) noticed it was not the same sound Audio
//! Devices plays on this box (kdeglobals says `freedesktop`), so the
//! default now follows the configured theme. `--file` still overrides.
//!
//! Deliberately small: no `Inherits=` chain walk (neither ocean nor
//! freedesktop declares one), no XDG data-dir search beyond
//! /usr/share/sounds - if the configured theme has no file there, fall
//! back to ocean, then freedesktop.

use std::path::{Path, PathBuf};

pub const EVENT_FILE: &str = "stereo/audio-volume-change.oga";
pub const SOUNDS_DIR: &str = "/usr/share/sounds";
pub const DEFAULT_THEME: &str = "ocean";

/// `[Sounds] Theme=` from kdeglobals text; `None` when absent.
pub fn parse_kdeglobals_theme(text: &str) -> Option<String> {
    let mut in_sounds = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_sounds = line == "[Sounds]";
            continue;
        }
        if in_sounds {
            if let Some((k, v)) = line.split_once('=') {
                if k.trim() == "Theme" {
                    let v = v.trim();
                    return if v.is_empty() { None } else { Some(v.to_string()) };
                }
            }
        }
    }
    None
}

fn kdeglobals_path() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("XDG_CONFIG_HOME") {
        if !dir.is_empty() {
            return Some(Path::new(&dir).join("kdeglobals"));
        }
    }
    std::env::var("HOME").ok().map(|h| Path::new(&h).join(".config").join("kdeglobals"))
}

/// The configured theme name, or the plasma-pa default when unset.
pub fn configured_theme() -> String {
    kdeglobals_path()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|t| parse_kdeglobals_theme(&t))
        .unwrap_or_else(|| DEFAULT_THEME.to_string())
}

pub fn theme_file(sounds_dir: &Path, theme: &str) -> PathBuf {
    sounds_dir.join(theme).join(EVENT_FILE)
}

/// First existing candidate: configured theme, then ocean, then
/// freedesktop. Returns the resolved path and the theme it came from.
pub fn resolve(sounds_dir: &Path, configured: &str) -> Option<(PathBuf, String)> {
    let mut order = vec![configured.to_string()];
    for fallback in [DEFAULT_THEME, "freedesktop"] {
        if !order.iter().any(|t| t == fallback) {
            order.push(fallback.to_string());
        }
    }
    order.into_iter().find_map(|t| {
        let p = theme_file(sounds_dir, &t);
        p.is_file().then_some((p, t))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_this_box_kdeglobals_shape() {
        let t = "[General]\nfoo=bar\n\n[Sounds]\nTheme=freedesktop\n\n[Other]\nTheme=ocean\n";
        assert_eq!(parse_kdeglobals_theme(t).as_deref(), Some("freedesktop"));
    }

    #[test]
    fn theme_key_outside_sounds_group_is_ignored() {
        assert_eq!(parse_kdeglobals_theme("[General]\nTheme=ocean\n"), None);
        assert_eq!(parse_kdeglobals_theme(""), None);
        assert_eq!(parse_kdeglobals_theme("[Sounds]\nTheme=\n"), None);
    }

    #[test]
    fn file_path_shape() {
        assert_eq!(
            theme_file(Path::new("/usr/share/sounds"), "ocean").to_str().unwrap(),
            "/usr/share/sounds/ocean/stereo/audio-volume-change.oga"
        );
    }

    #[test]
    fn resolve_falls_back_in_order() {
        let dir = std::env::temp_dir().join(format!("devialet-chime-theme-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        // Nothing installed at all -> None.
        assert!(resolve(&dir, "freedesktop").is_none());
        // Only ocean present -> a missing configured theme falls back to it.
        std::fs::create_dir_all(dir.join("ocean/stereo")).unwrap();
        std::fs::write(theme_file(&dir, "ocean"), b"x").unwrap();
        let (p, t) = resolve(&dir, "nosuchtheme").unwrap();
        assert_eq!(t, "ocean");
        assert_eq!(p, theme_file(&dir, "ocean"));
        // Configured theme present -> it wins.
        std::fs::create_dir_all(dir.join("freedesktop/stereo")).unwrap();
        std::fs::write(theme_file(&dir, "freedesktop"), b"x").unwrap();
        assert_eq!(resolve(&dir, "freedesktop").unwrap().1, "freedesktop");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
