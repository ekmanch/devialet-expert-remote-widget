use devialet_protocol as proto;
use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::time::Instant;
use zbus::interface;

pub const BUS_NAME: &str = "com.ekmanch.DevialetRemote";
pub const OBJECT_PATH: &str = "/com/ekmanch/DevialetRemote/Amp";
pub const INTERFACE_NAME: &str = "com.ekmanch.DevialetRemote.Amp1";

/// One amp's last-known status broadcast, keyed by IP in `AmpState::amps`.
/// Never evicted once seen - matches the Kotlin app's `discoveredAmps`
/// (`LinkedHashMap`, entries linger forever, staleness is only checked at
/// read time via `isAmpRecentlyHeard`/`ampStaleTimeoutMs`), not pruned here
/// either.
#[derive(Debug, Clone)]
struct TrackedAmp {
    status: proto::Status,
    last_seen: Instant,
    /// Resolved via mDNS (Phase 3.7) - `None` until/unless resolution
    /// succeeds for this IP. Mirrors `DiscoveredAmp.modelName` (nullable,
    /// resolved separately, carried forward across UDP-driven updates - see
    /// `ingest_status`, ported from `DiscoveredAmp.kt`'s doc comment
    /// warning that recreating the record on every broadcast "gets wiped
    /// every ~1s" if the previous value isn't explicitly carried forward).
    /// Once set, never cleared - matches the Kotlin app, which also never
    /// resets a resolved `modelName` back to `null`.
    model_name: Option<String>,
}

/// D-Bus-exposed state, covering both the Phase 1-3 "primary amp" surface
/// (kept for backward compatibility with the already-verified Phase 3 QML)
/// and the Phase 3.5 multi-amp discovery/selection surface added alongside
/// it.
///
/// Ported concept, not guessed: `selected_ip` mirrors
/// `MainActivity.selectedIp` (an empty string is the "no amp selected"
/// sentinel, same value whether nothing has ever been chosen or "None" was
/// explicitly chosen - see `MainActivity.clearAmpSelection()`). `amps`
/// mirrors `MainActivity.discoveredAmps` (every amp ever heard broadcasting,
/// keyed by IP, regardless of selection).
///
/// Unlike the Kotlin app, there is no amp-picker UI yet (that's Phase 4), so
/// nothing calls `SelectAmp` in practice yet except manual `busctl`/testing
/// calls. To avoid regressing Phase 3's already-verified single-amp
/// behavior in the meantime: when `selected_ip` is empty AND exactly one amp
/// is currently known, that amp is auto-selected for the primary properties
/// below (see `effective_ip`). With zero or 2+ known amps and nothing
/// explicitly selected, the primary properties fall back to the empty
/// "not connected" state instead of guessing which one to show.
///
/// **Post-Phase-4.1 correction:** the paragraph above ("selected_ip... same
/// value whether nothing has ever been chosen or 'None' was explicitly
/// chosen") described Android's own collapsing of those two states, which
/// is fine for Android since it has no auto-select-if-alone behavior to
/// collapse *into*. Porting that collapse here was a real bug once Phase
/// 4.1 added a real picker: explicitly choosing "None" (`SelectAmp("")`)
/// left `selected_ip` empty exactly like "never chosen", so
/// `effective_ip()`'s auto-select-if-alone branch silently re-selected the
/// sole known amp anyway - the user's explicit clear appeared to do
/// nothing (picker closed, selection reverted). Fixed by adding
/// `has_explicit_selection` below, set the moment `SelectAmp` is ever
/// called (with any ip, including ""), which is what auto-select-if-alone
/// now actually gates on instead of `selected_ip.is_empty()` alone - see
/// `effective_ip`. This also matters for Phase 4.2 (persistence): loading a
/// persisted selection - even a persisted "" (a previously-explicit
/// None) - must also set `has_explicit_selection = true`, not just
/// `selected_ip`, or a restart would silently resurrect the auto-select
/// behavior for a user who'd explicitly opted out of it.
#[derive(Debug, Clone, Default)]
pub struct AmpState {
    amps: HashMap<String, TrackedAmp>,
    selected_ip: String,
    /// True from the first `SelectAmp` call onward (any ip, including ""),
    /// false only in the genuine "daemon just started, nothing has ever
    /// been chosen" state. See the struct doc's "Post-Phase-4.1 correction"
    /// above for why this exists separately from `selected_ip.is_empty()`.
    has_explicit_selection: bool,

    // ---- exposed fields below, all derived from the two above by
    // `recompute()` - never written to directly outside of it. ----
    device_name: String,
    amp_ip: String,
    online: bool,
    power: bool,
    muted: bool,
    volume_raw: u8,
    volume_db: f64,
    active_source_index: u8,
    active_source_name: String,
    sources: Vec<(String, u8, bool, bool)>,
    known_amps: Vec<(String, String, bool, String)>,
}

#[interface(name = "com.ekmanch.DevialetRemote.Amp1")]
impl AmpState {
    #[zbus(property, name = "DeviceName")]
    pub fn device_name(&self) -> String {
        self.device_name.clone()
    }

    #[zbus(property, name = "AmpIp")]
    pub fn amp_ip(&self) -> String {
        self.amp_ip.clone()
    }

    /// Whether the *selected* (or auto-selected, see struct doc) amp has
    /// been heard from within `devialet_protocol::STALE_AFTER` (8s). False
    /// when nothing is selected/auto-selected at all, not just when the
    /// selected amp goes quiet.
    #[zbus(property, name = "Online")]
    pub fn online(&self) -> bool {
        self.online
    }

    #[zbus(property, name = "Power")]
    pub fn power(&self) -> bool {
        self.power
    }

    #[zbus(property, name = "Muted")]
    pub fn muted(&self) -> bool {
        self.muted
    }

    /// Raw 0-255 status byte, exposed alongside the decoded dB value for
    /// manual/debug verification (busctl etc.) independent of the dB
    /// formula.
    #[zbus(property, name = "VolumeRaw")]
    pub fn volume_raw(&self) -> u8 {
        self.volume_raw
    }

    #[zbus(property, name = "VolumeDb")]
    pub fn volume_db(&self) -> f64 {
        self.volume_db
    }

    #[zbus(property, name = "ActiveSourceIndex")]
    pub fn active_source_index(&self) -> u8 {
        self.active_source_index
    }

    #[zbus(property, name = "ActiveSourceName")]
    pub fn active_source_name(&self) -> String {
        self.active_source_name.clone()
    }

    /// Full 30-slot source table (name, index, enabled, selected) for the
    /// selected/auto-selected amp - see struct doc. Empty (not 30 blank
    /// entries) when nothing is selected/auto-selected, distinguishing "no
    /// amp" from "a real amp with mostly-disabled slots".
    #[zbus(property, name = "Sources")]
    pub fn sources(&self) -> Vec<(String, u8, bool, bool)> {
        self.sources.clone()
    }

    /// Every amp ever heard broadcasting on the LAN, not just the selected
    /// one - `(ip, device_name, online, model_name)` tuples. `device_name`
    /// is always the raw UDP-broadcast name (unlike the primary
    /// `DeviceName` property, this one deliberately does *not* prefer
    /// `model_name` - a future picker needs both, e.g. to show "Devialet
    /// Expert 140 Pro" as the main label and the raw UDP name as a
    /// subtitle, the way the Kotlin app's device card does). `online`
    /// computed with the same 8s staleness rule as the `Online` property
    /// above. `model_name` is `""` until mDNS resolution succeeds for that
    /// IP (Phase 3.7 - see `resolve_model_name`); never cleared once
    /// resolved, matching the Kotlin app. Never pruned; a since-gone amp
    /// just shows `online = false` forever rather than disappearing
    /// (mirrors `discoveredAmps` never being pruned in the Kotlin app -
    /// only the picker *view* there filters stale entries, this property
    /// intentionally doesn't so a future picker can decide its own
    /// filtering/sorting). Sorted numerically by IP (octet-wise, e.g.
    /// `192.168.0.9` before `192.168.0.10`), not lexicographically as a
    /// string - for a stable order across emissions: the list only
    /// reorders when the known-IP set itself changes (a new amp is first
    /// heard), never as a side effect of an entry's `online` or
    /// `model_name` fields changing.
    #[zbus(property, name = "KnownAmps")]
    pub fn known_amps(&self) -> Vec<(String, String, bool, String)> {
        self.known_amps.clone()
    }

    /// Explicitly selected amp's IP, or "" if none - mirrors
    /// `MainActivity.selectedIp`/its SharedPreferences `amp_ip` sentinel.
    /// Note this is the *explicit* selection only - it stays "" even while
    /// the single-known-amp auto-select behavior (see struct doc) is
    /// driving the primary properties above from exactly one known amp.
    #[zbus(property, name = "SelectedAmpIp")]
    pub fn selected_amp_ip(&self) -> String {
        self.selected_ip.clone()
    }

    /// Selects an amp by IP for the primary properties above; pass "" to
    /// explicitly clear the selection (the "None" option in the Kotlin
    /// app's amp sheet). Accepts any IP, including one never heard
    /// broadcasting yet (mirrors the Kotlin app's manual-IP-entry fallback
    /// for when discovery doesn't work) - the primary properties then show
    /// that IP with the empty/not-connected state until/unless a broadcast
    /// from it arrives.
    ///
    /// Always sets `has_explicit_selection`, even when `ip` is "" - that's
    /// the whole fix for the bug described on the struct doc's "Post-
    /// Phase-4.1 correction": without this, `SelectAmp("")` was
    /// indistinguishable from "never called" and got silently overridden
    /// by `effective_ip()`'s auto-select-if-alone branch.
    #[zbus(name = "SelectAmp")]
    async fn select_amp(
        &mut self,
        ip: String,
        #[zbus(signal_emitter)] emitter: zbus::object_server::SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        let before = self.clone();
        self.selected_ip = ip;
        self.has_explicit_selection = true;
        self.recompute();
        if !states_equal(&before, self) {
            emit_all(self, &emitter)
                .await
                .map_err(|e| zbus::fdo::Error::Failed(e.to_string()))?;
        }
        Ok(())
    }
}

impl AmpState {
    /// Records a freshly-received, already-parsed status broadcast from
    /// `ip` and re-derives every exposed field. Called once per real UDP
    /// packet from the daemon's receive loop.
    pub fn ingest_status(&mut self, ip: String, status: proto::Status) {
        // Carry forward any already-resolved model name - ported from
        // DiscoveredAmp.kt's doc comment (see TrackedAmp's own doc): a
        // naive overwrite here would wipe a Phase 3.7 mDNS resolution on
        // every single ~1s UDP broadcast from that amp.
        let model_name = self.amps.get(&ip).and_then(|amp| amp.model_name.clone());
        self.amps.insert(ip, TrackedAmp { status, last_seen: Instant::now(), model_name });
        self.recompute();
    }

    /// Applies an mDNS-resolved model name to a *known* amp (one already
    /// present in `amps` from a real UDP broadcast) and re-derives every
    /// exposed field. Returns `false` (no-op, nothing recomputed) if `ip`
    /// isn't a known amp - mirrors the Kotlin app's own guard
    /// (`discoveredAmps[ip]?.let { ... }` in `MainActivity`'s
    /// `AmpModelNameResolver` callback), needed because the mDNS service
    /// type being browsed (`_spotify-connect._tcp`, see main.rs's mDNS
    /// setup doc for why) isn't Devialet-specific, so an arbitrary Spotify
    /// Connect receiver's resolved name must never be trusted for an IP
    /// that was never actually heard broadcasting the Devialet UDP
    /// protocol.
    pub fn resolve_model_name(&mut self, ip: &str, model_name: String) -> bool {
        let Some(amp) = self.amps.get_mut(ip) else {
            return false;
        };
        amp.model_name = Some(model_name);
        self.recompute();
        true
    }

    /// Re-derives every exposed field with no new packet - only staleness
    /// (elapsed time since each amp's `last_seen`) can have changed. Called
    /// once per receive-loop tick even with no incoming packet, so an amp
    /// going quiet is still noticed and reflected (both in `Online` for the
    /// primary amp and per-entry in `KnownAmps`).
    pub fn recompute_staleness(&mut self) {
        self.recompute();
    }

    /// The IP whose status should drive the primary properties: the
    /// explicit selection if one exists, else the sole known amp if there's
    /// exactly one AND nothing has ever been explicitly selected (including
    /// an explicit "None"), else nothing. See struct doc for the rationale.
    /// The `!self.has_explicit_selection` guard is what makes an explicit
    /// `SelectAmp("")` actually stick instead of being silently
    /// re-overridden by the auto-select-if-alone branch below it.
    fn effective_ip(&self) -> Option<String> {
        if !self.selected_ip.is_empty() {
            return Some(self.selected_ip.clone());
        }
        if !self.has_explicit_selection && self.amps.len() == 1 {
            return self.amps.keys().next().cloned();
        }
        None
    }

    fn recompute(&mut self) {
        let mut known_amps: Vec<(String, String, bool, String)> = self
            .amps
            .iter()
            .map(|(ip, amp)| {
                (
                    ip.clone(),
                    amp.status.device_name.clone(),
                    amp.last_seen.elapsed() < proto::STALE_AFTER,
                    amp.model_name.clone().unwrap_or_default(),
                )
            })
            .collect();
        // Numeric (octet-wise), not lexicographic - a plain string sort
        // would put "192.168.0.10" before "192.168.0.9". IPs in `amps` are
        // always valid IPv4 dotted-quads (the only way one gets inserted is
        // via `ingest_status`, fed by `src.ip().to_string()` off the
        // IPv4-only socket bound in `bind_status_socket`), so parse failure
        // here would mean that invariant broke, not a normal runtime case.
        known_amps.sort_by_key(|(ip, _, _, _)| {
            ip.parse::<Ipv4Addr>()
                .expect("amp IPs are always valid IPv4 dotted-quads - see bind_status_socket")
        });
        self.known_amps = known_amps;

        let effective_ip = self.effective_ip();
        self.amp_ip = effective_ip.clone().unwrap_or_default();

        match effective_ip.and_then(|ip| self.amps.get(&ip)) {
            Some(amp) => {
                // `modelName ?: udpName` - ported from
                // AmpModelNameResolver.kt's usage in
                // MainActivity.updateDeviceCard()
                // (`discoveredAmps[selectedIp]?.modelName ?: selectedName...`).
                // The raw UDP name is still available unprefixed in
                // `KnownAmps` above for anything that wants it regardless.
                self.device_name = amp
                    .model_name
                    .clone()
                    .filter(|name| !name.is_empty())
                    .unwrap_or_else(|| amp.status.device_name.clone());
                self.online = amp.last_seen.elapsed() < proto::STALE_AFTER;
                self.power = amp.status.power_on;
                self.muted = amp.status.muted;
                self.volume_raw = amp.status.volume_raw;
                self.volume_db = amp.status.volume_db();
                self.active_source_index = amp.status.source_index;
                self.active_source_name = amp.status.current_source_name().unwrap_or("").to_string();
                self.sources = amp
                    .status
                    .sources
                    .iter()
                    .map(|s| (s.name.clone(), s.index, s.enabled, s.selected))
                    .collect();
            }
            None => {
                self.device_name = String::new();
                self.online = false;
                self.power = false;
                self.muted = false;
                self.volume_raw = 0;
                self.volume_db = 0.0;
                self.active_source_index = 0;
                self.active_source_name = String::new();
                self.sources = Vec::new();
            }
        }
    }
}

/// Compares every exposed field (deliberately excluding `amps`/its
/// `Instant` timestamps, which change every tick regardless of anything
/// worth emitting a signal over) - used to decide whether a `PropertiesChanged`
/// round is actually needed. `pub(crate)` so main.rs's receive loop can
/// gate its own emits on it too, not just the `SelectAmp` method above.
pub(crate) fn states_equal(a: &AmpState, b: &AmpState) -> bool {
    a.device_name == b.device_name
        && a.amp_ip == b.amp_ip
        && a.online == b.online
        && a.power == b.power
        && a.muted == b.muted
        && a.volume_raw == b.volume_raw
        && a.volume_db == b.volume_db
        && a.active_source_index == b.active_source_index
        && a.active_source_name == b.active_source_name
        && a.sources == b.sources
        && a.known_amps == b.known_amps
        && a.selected_ip == b.selected_ip
}

/// Emits every property's `PropertiesChanged` signal unconditionally, given
/// `state` already reflects the desired new values (callers decide whether
/// it's worth calling at all via `states_equal`). Shared between the
/// receive-loop-driven path (main.rs) and the `SelectAmp` D-Bus method
/// above, which has no other way to notify clients of a selection change.
pub async fn emit_all(state: &AmpState, emitter: &zbus::object_server::SignalEmitter<'_>) -> zbus::Result<()> {
    state.device_name_changed(emitter).await?;
    state.amp_ip_changed(emitter).await?;
    state.online_changed(emitter).await?;
    state.power_changed(emitter).await?;
    state.muted_changed(emitter).await?;
    state.volume_raw_changed(emitter).await?;
    state.volume_db_changed(emitter).await?;
    state.active_source_index_changed(emitter).await?;
    state.active_source_name_changed(emitter).await?;
    state.sources_changed(emitter).await?;
    state.known_amps_changed(emitter).await?;
    state.selected_amp_ip_changed(emitter).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use devialet_protocol::fixtures::StatusFixtureBuilder;

    /// Builds bytes via the protocol crate's own fixture builder, then
    /// parses them via the real `parse_status` - end-to-end realism (bytes
    /// -> parse -> track) rather than hand-constructing a `Status` literal,
    /// per the Phase 3.5 testing strategy.
    fn parsed_status(device_name: &str) -> proto::Status {
        let bytes = StatusFixtureBuilder::new()
            .device_name(device_name)
            .source(0, "Optical 1", true)
            .active_source_index(0)
            .power(true)
            .volume_raw(195)
            .build();
        proto::parse_status(&bytes).expect("fixture packet should parse")
    }

    #[test]
    fn two_distinct_amps_are_tracked_as_separate_known_amps_entries() {
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.50".to_string(), parsed_status("Living Room Amp"));
        state.ingest_status("192.168.1.51".to_string(), parsed_status("Bedroom Amp"));

        assert_eq!(state.known_amps.len(), 2, "second amp must not overwrite the first");
        let mut names: Vec<&str> = state.known_amps.iter().map(|(_, name, _, _)| name.as_str()).collect();
        names.sort();
        assert_eq!(names, vec!["Bedroom Amp", "Living Room Amp"]);
        assert!(state.known_amps.iter().all(|(_, _, online, _)| *online), "freshly-ingested amps are online");
    }

    #[test]
    fn re_ingesting_the_same_ip_updates_in_place_rather_than_duplicating() {
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.50".to_string(), parsed_status("Living Room Amp"));
        state.ingest_status("192.168.1.50".to_string(), parsed_status("Renamed Amp"));

        assert_eq!(state.known_amps.len(), 1);
        assert_eq!(state.known_amps[0].1, "Renamed Amp");
    }

    #[test]
    fn with_exactly_one_known_amp_and_no_explicit_selection_it_is_auto_selected() {
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.50".to_string(), parsed_status("Living Room Amp"));

        assert_eq!(state.selected_ip, "", "auto-select must not itself set an explicit selection");
        assert_eq!(state.device_name, "Living Room Amp");
        assert_eq!(state.amp_ip, "192.168.1.50");
        assert!(state.online);
    }

    #[test]
    fn with_two_known_amps_and_no_explicit_selection_primary_falls_back_to_not_connected() {
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.50".to_string(), parsed_status("Living Room Amp"));
        state.ingest_status("192.168.1.51".to_string(), parsed_status("Bedroom Amp"));

        assert_eq!(state.device_name, "");
        assert_eq!(state.amp_ip, "");
        assert!(!state.online);
        assert!(state.sources.is_empty());
        // The discovery list itself is unaffected by there being no primary.
        assert_eq!(state.known_amps.len(), 2);
    }

    #[test]
    fn explicit_selection_picks_the_named_amp_regardless_of_known_amp_count() {
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.50".to_string(), parsed_status("Living Room Amp"));
        state.ingest_status("192.168.1.51".to_string(), parsed_status("Bedroom Amp"));

        state.selected_ip = "192.168.1.51".to_string();
        state.recompute();

        assert_eq!(state.device_name, "Bedroom Amp");
        assert_eq!(state.amp_ip, "192.168.1.51");
        assert!(state.online);
    }

    #[test]
    fn explicit_selection_of_an_unknown_ip_shows_the_ip_but_not_connected() {
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.50".to_string(), parsed_status("Living Room Amp"));

        state.selected_ip = "192.168.1.99".to_string();
        state.recompute();

        assert_eq!(state.amp_ip, "192.168.1.99");
        assert_eq!(state.device_name, "");
        assert!(!state.online);
    }

    // Regression test for the bug reported after Phase 4.1 shipped a real
    // amp picker: SelectAmp("") (choosing "None") left `selected_ip` empty
    // exactly like "never selected", so `effective_ip()`'s
    // auto-select-if-alone branch silently re-selected the sole known amp
    // anyway - the user's explicit clear appeared to do nothing (picker
    // closed, selection reverted). `has_explicit_selection` is set by the
    // real `select_amp()` D-Bus method regardless of what `ip` is; mirrored
    // by hand here since `select_amp` is an async zbus method this test
    // module doesn't have an interface context to call directly - matches
    // the existing pattern of the other tests in this file poking
    // `selected_ip` directly rather than going through the D-Bus method.
    //
    // This replaces a previous test of the same name
    // ("clearing_selection_back_to_empty_string_returns_to_auto_select_
    // behavior") that asserted the OLD, buggy behavior (auto-select résumés
    // after a raw `selected_ip = ""` write) - that assertion is exactly the
    // bug, not a real invariant: a raw field write without also setting
    // `has_explicit_selection` never happens in production code (only
    // `select_amp()` ever writes `selected_ip`, and it always sets both
    // together now), so the old test wasn't exercising anything a real
    // client could actually trigger.
    #[test]
    fn explicit_none_selection_does_not_fall_back_to_auto_select() {
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.50".to_string(), parsed_status("Living Room Amp"));
        state.selected_ip = "192.168.1.50".to_string();
        state.has_explicit_selection = true;
        state.recompute();
        assert_eq!(state.device_name, "Living Room Amp");

        // Explicitly clearing back to "" - matches what a real
        // SelectAmp("") call does.
        state.selected_ip = String::new();
        state.has_explicit_selection = true;
        state.recompute();

        assert_eq!(state.selected_ip, "");
        assert_eq!(state.amp_ip, "", "an explicit clear must NOT fall back to auto-select, even with exactly one known amp");
        assert_eq!(state.device_name, "");
        assert!(!state.online);
    }

    #[test]
    fn never_explicitly_selected_still_auto_selects_the_sole_known_amp() {
        // Companion to the regression test above: confirms the fix didn't
        // overcorrect into disabling auto-select-if-alone entirely - it
        // must still apply for the genuine "nothing has ever been chosen"
        // case (has_explicit_selection left at its Default::default()
        // value, false), which is what a fresh daemon startup with no
        // persisted selection looks like.
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.50".to_string(), parsed_status("Living Room Amp"));
        state.selected_ip = "192.168.1.50".to_string();
        state.has_explicit_selection = true;
        state.recompute();

        // Simulates a second amp being explicitly selected, then a fresh
        // "never chosen" AmpState (e.g. after a restart with nothing
        // persisted yet, pre-Phase-4.2) seeing only one amp - not a
        // continuation of the state above.
        let mut fresh_state = AmpState::default();
        fresh_state.ingest_status("192.168.1.50".to_string(), parsed_status("Living Room Amp"));

        assert_eq!(fresh_state.selected_ip, "");
        assert!(!fresh_state.has_explicit_selection);
        assert_eq!(fresh_state.amp_ip, "192.168.1.50", "auto-select-if-alone must still work when nothing was ever explicitly chosen");
        assert_eq!(fresh_state.device_name, "Living Room Amp");
    }

    #[test]
    fn known_amps_is_sorted_by_ip_for_a_stable_emission_order() {
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.99".to_string(), parsed_status("Z Amp"));
        state.ingest_status("192.168.1.10".to_string(), parsed_status("A Amp"));

        let ips: Vec<&str> = state.known_amps.iter().map(|(ip, _, _, _)| ip.as_str()).collect();
        assert_eq!(ips, vec!["192.168.1.10", "192.168.1.99"]);
    }

    /// `.9` vs `.10` is the case that actually distinguishes numeric from
    /// lexicographic sorting - the test above (`.10` vs `.99`) happens to
    /// agree under both, so it wouldn't have caught a regression back to
    /// plain string comparison on its own.
    #[test]
    fn known_amps_sorts_numerically_not_lexicographically() {
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.10".to_string(), parsed_status("Ten"));
        state.ingest_status("192.168.1.9".to_string(), parsed_status("Nine"));

        let ips: Vec<&str> = state.known_amps.iter().map(|(ip, _, _, _)| ip.as_str()).collect();
        // Lexicographically "192.168.1.10" < "192.168.1.9" (the '1' after
        // the shared "192.168.1." prefix sorts before '9'), which is the
        // wrong order for what a human expects from "sorted by IP".
        assert_eq!(ips, vec!["192.168.1.9", "192.168.1.10"]);
    }

    #[test]
    fn resolving_a_known_amp_updates_known_amps_and_becomes_the_primary_device_name() {
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.50".to_string(), parsed_status("My Devialet-ETH"));

        let applied = state.resolve_model_name("192.168.1.50", "Devialet Expert 140 Pro".to_string());

        assert!(applied);
        assert_eq!(
            state.known_amps.iter().find(|(ip, ..)| ip == "192.168.1.50").unwrap().3,
            "Devialet Expert 140 Pro"
        );
        // modelName ?: udpName - the primary DeviceName property prefers
        // the resolved model name over the raw UDP broadcast name.
        assert_eq!(state.device_name, "Devialet Expert 140 Pro");
    }

    #[test]
    fn resolving_an_ip_never_heard_over_udp_is_rejected() {
        // _spotify-connect._tcp isn't Devialet-specific - a resolution for
        // an IP this daemon never saw a real UDP broadcast from must be
        // discarded, not trusted as if it were a known amp.
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.50".to_string(), parsed_status("My Devialet-ETH"));

        let applied = state.resolve_model_name("192.168.1.77", "Some Other Spotify Speaker".to_string());

        assert!(!applied);
        assert_eq!(state.known_amps.len(), 1, "no new entry should be created for an unknown IP");
        assert!(state.known_amps.iter().all(|(_, _, _, model)| model.is_empty()));
    }

    #[test]
    fn unresolved_model_name_falls_back_to_raw_udp_device_name() {
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.50".to_string(), parsed_status("My Devialet-ETH"));

        // No resolve_model_name call at all - mirrors "resolution hasn't
        // completed yet, or never succeeds" (e.g. no mDNS on the network).
        assert_eq!(state.device_name, "My Devialet-ETH");
        assert_eq!(state.known_amps[0].3, "", "unresolved model name is empty, not absent/blank-but-set");
    }

    #[test]
    fn resolved_model_name_survives_a_later_udp_broadcast_from_the_same_amp() {
        // Ported behavior, not incidental: DiscoveredAmp.kt's doc comment
        // warns this is exactly the kind of thing that "gets wiped every
        // ~1s" if the previous value isn't carried forward across re-ingestion.
        let mut state = AmpState::default();
        state.ingest_status("192.168.1.50".to_string(), parsed_status("My Devialet-ETH"));
        state.resolve_model_name("192.168.1.50", "Devialet Expert 140 Pro".to_string());

        // A later UDP broadcast from the same amp (e.g. next ~1s status
        // packet) must not wipe the already-resolved model name.
        state.ingest_status("192.168.1.50".to_string(), parsed_status("My Devialet-ETH"));

        assert_eq!(state.device_name, "Devialet Expert 140 Pro");
        assert_eq!(state.known_amps[0].3, "Devialet Expert 140 Pro");
    }
}
