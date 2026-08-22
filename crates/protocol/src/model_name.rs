//! Maps a raw mDNS hostname (e.g. `"Expert140Pro"`) to a display-ready
//! Devialet model name (e.g. `"Devialet Expert 140 Pro"`).
//!
//! Ported from the Kotlin app's `AmpModelNameResolver.parseModelName`
//! (`AmpModelNameResolver.kt`, companion object):
//!
//! ```kotlin
//! fun parseModelName(mdnsHostname: String): String? {
//!     val raw = mdnsHostname.substringBefore('-').trim()
//!     if (raw.isEmpty()) return null
//!     val spaced = raw.replace(Regex("(?<=[a-zA-Z])(?=\\d)|(?<=\\d)(?=[A-Z])"), " ")
//!     return "Devialet $spaced"
//! }
//! ```
//!
//! This is a general algorithmic transform, **not** a per-model lookup
//! table (confirmed by reading the Kotlin source, not assumed from the one
//! "Expert140Pro" example) - it inserts a space at every letter->digit
//! boundary and every digit->uppercase-letter boundary, then prefixes
//! `"Devialet "`. Notably digit->lowercase-letter is *not* a boundary (so
//! e.g. a hypothetical "2go" stays "2go", not "2 go") - ported exactly as
//! written, not "cleaned up".

/// Splits `mdns_hostname` on its first `-` (Devialet's mDNS hostnames are
/// `"<Model><Digits><Suffix>-<serial>.local."` - see
/// `AmpModelNameResolver`'s class doc), inserts spaces at
/// letter->digit and digit->uppercase-letter boundaries, and prefixes
/// `"Devialet "`. Returns `None` if nothing precedes the first `-` (or the
/// whole hostname is empty), matching the Kotlin function's `return null`
/// on an empty `raw`.
pub fn parse_model_name(mdns_hostname: &str) -> Option<String> {
    // Kotlin's `substringBefore('-')` returns the original string
    // unchanged if the delimiter isn't found at all - `.split('-').next()`
    // matches that exactly (first split segment before any '-', or the
    // whole string if there's no '-').
    let raw = mdns_hostname.split('-').next().unwrap_or("").trim();
    if raw.is_empty() {
        return None;
    }

    let chars: Vec<char> = raw.chars().collect();
    let mut spaced = String::with_capacity(raw.len() + 1);
    for (i, &c) in chars.iter().enumerate() {
        if i > 0 {
            let prev = chars[i - 1];
            let is_boundary = (prev.is_ascii_alphabetic() && c.is_ascii_digit())
                || (prev.is_ascii_digit() && c.is_ascii_uppercase());
            if is_boundary {
                spaced.push(' ');
            }
        }
        spaced.push(c);
    }

    Some(format!("Devialet {spaced}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn confirmed_real_example_expert_140_pro() {
        // The one example actually confirmed against real hardware (see
        // AmpModelNameResolver's class doc: "Expert140Pro-<serial>.local",
        // via avahi-browse/avahi-resolve).
        assert_eq!(
            parse_model_name("Expert140Pro-AB12CD34.local."),
            Some("Devialet Expert 140 Pro".to_string())
        );
    }

    #[test]
    fn strips_everything_from_the_first_hyphen_onward() {
        assert_eq!(parse_model_name("Expert140Pro-1234.local."), parse_model_name("Expert140Pro-9999999.local."));
    }

    #[test]
    fn digit_to_lowercase_letter_is_not_a_boundary() {
        // Exercises the regex's asymmetry exactly as written: only
        // digit->UPPERCASE is a boundary, not digit->lowercase - ported
        // literally rather than "fixed" to insert a space there too.
        assert_eq!(parse_model_name("2go"), Some("Devialet 2go".to_string()));
    }

    #[test]
    fn multiple_letter_digit_and_digit_uppercase_boundaries_all_split() {
        // Synthetic (not a claimed real Devialet product name) - exercises
        // the general algorithm across more than one boundary of each kind
        // in a single string, since the one confirmed real example only
        // has one of each.
        assert_eq!(
            parse_model_name("Phantom2Reactor900-serial.local."),
            Some("Devialet Phantom 2 Reactor 900".to_string())
        );
    }

    #[test]
    fn no_digits_at_all_still_gets_the_devialet_prefix() {
        assert_eq!(parse_model_name("Konnect-serial.local."), Some("Devialet Konnect".to_string()));
    }

    #[test]
    fn leading_digits_do_not_get_a_leading_space() {
        assert_eq!(parse_model_name("900Something-serial.local."), Some("Devialet 900 Something".to_string()));
    }

    #[test]
    fn empty_before_the_first_hyphen_returns_none() {
        assert_eq!(parse_model_name("-serial.local."), None);
    }

    #[test]
    fn hostname_with_no_hyphen_is_used_in_full_matching_kotlins_substring_before_semantics() {
        // Kotlin's substringBefore('-') returns the whole string unchanged
        // when the delimiter isn't present - not expected on real Devialet
        // hostnames (see class doc), but the port must match that exact
        // fallback behavior rather than diverging on this edge case.
        assert_eq!(parse_model_name("NoHyphenHost"), Some("Devialet NoHyphenHost".to_string()));
    }

    #[test]
    fn blank_hostname_returns_none() {
        assert_eq!(parse_model_name(""), None);
        assert_eq!(parse_model_name("   "), None);
    }
}
