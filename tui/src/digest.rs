//! Serde mirrors of the engine's `LiveState` digest (Swift:
//! `Sources/UsageCore/Digests/LiveState.swift`). The TUI renders these and
//! computes nothing.
//!
//! Contract: the schema evolves additively; unknown fields are ignored
//! (serde's default), and ABSENT ≠ ZERO — every nullable arrives as an
//! `Option`, never a defaulted 0. The tests at the bottom decode the SAME
//! golden fixtures the Swift suite pins
//! (`Tests/UsageCoreTests/Fixtures/digest/`), so cross-language drift
//! fails a test on whichever side drifted.

// Mirror completeness beats field-by-field usage: every schema field is
// declared even before a surface reads it (T2 consumes most), so the
// contract tests exercise the WHOLE wire shape.
#![allow(dead_code)]

use serde::Deserialize;
use time::OffsetDateTime;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveState {
    pub schema_version: u32,
    pub engine: EngineStatus,
    pub meters: Vec<LiveMeter>,
    pub menu_bar: Vec<SegmentStatus>,
    pub models: Vec<ModelRow>,
    pub activity: ActivityRollup,
    /// Recent sessions, newest first. Default-empty so a digest from an
    /// engine that predates the section still decodes.
    #[serde(default)]
    pub sessions: Vec<SessionCard>,
    /// The provider's service health. `None` means this engine tracks no
    /// status (no feed declared, or a digest older than 0.86.0) — ABSENT IS
    /// NOT HEALTHY, so a renderer must show nothing rather than a green dot.
    #[serde(default)]
    pub service_status: Option<ServiceStatusCard>,
    /// The app's own newest published release. `None` means the updater has
    /// nothing to say (source-managed build, no releases, or a digest older
    /// than 0.87.0) — absent is never "up to date".
    #[serde(default)]
    pub app_update: Option<AppUpdateCard>,
}

/// Mirror of `AppUpdateCard` — the newest GitHub release the engine host
/// knows about. The TUI renders none of it today; the mirror exists because
/// mirror completeness IS the schema freeze.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppUpdateCard {
    /// The release tag with its leading "v" stripped — "0.87.0".
    pub latest_version: String,
    /// The release page for humans.
    pub url: String,
    #[serde(with = "time::serde::rfc3339::option", default)]
    pub published_at: Option<OffsetDateTime>,
    #[serde(default)]
    pub asset_name: Option<String>,
    /// Swift spells the property `assetURL` — the same acronym trap
    /// `pageURL` below sidesteps.
    #[serde(rename = "assetURL", default)]
    pub asset_url: Option<String>,
    #[serde(default)]
    pub asset_bytes: Option<i64>,
    #[serde(with = "time::serde::rfc3339")]
    pub checked_at: OffsetDateTime,
    /// Precomputed by the WRITER against its own version.
    pub update_available: bool,
}

/// Mirror of `ServiceStatusCard` — what the provider's own status page says,
/// normalized by the engine. The TUI renders this and polls nothing.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceStatusCard {
    #[serde(rename = "providerID")]
    pub provider_id: String,
    pub page_name: String,
    /// Swift spells the property `pageURL`, and camelCase would look for
    /// `pageUrl` — the same acronym trap `providerID` above sidesteps.
    #[serde(rename = "pageURL")]
    pub page_url: String,
    /// "none" | "minor" | "major" | "critical" | "maintenance" | "unknown".
    /// A String, not an enum: an indicator this build has never heard of must
    /// decode and render quietly rather than fail the whole digest.
    pub indicator: String,
    /// The page's own words ("All Systems Operational").
    pub description_text: String,
    #[serde(with = "time::serde::rfc3339")]
    pub checked_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339::option", default)]
    pub ok_at: Option<OffsetDateTime>,
    pub stale: bool,
    #[serde(default)]
    pub components: Vec<StatusComponent>,
    /// Unresolved, worst impact first.
    #[serde(default)]
    pub incidents: Vec<StatusIncident>,
    /// Resolved within the last hour — the quiet "all clear".
    #[serde(default)]
    pub recently_resolved: Vec<StatusIncident>,
    #[serde(default)]
    pub maintenances: Vec<StatusMaintenance>,
}

impl ServiceStatusCard {
    /// The incident driving the loud surfaces; maintenance is never one.
    pub fn active_incident(&self) -> Option<&StatusIncident> {
        self.incidents.first()
    }

    pub fn has_incident(&self) -> bool {
        !self.incidents.is_empty()
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusComponent {
    pub name: String,
    /// The feed's own vocabulary: operational, degraded_performance,
    /// partial_outage, major_outage, under_maintenance.
    pub status: String,
}

impl StatusComponent {
    pub fn is_operational(&self) -> bool {
        self.status == "operational"
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusIncident {
    pub id: String,
    pub name: String,
    /// "none" | "minor" | "major" | "critical".
    pub impact: String,
    /// "investigating" | "identified" | "monitoring" | "resolved".
    pub phase: String,
    #[serde(with = "time::serde::rfc3339")]
    pub started_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339::option", default)]
    pub last_update_at: Option<OffsetDateTime>,
    pub last_message: Option<String>,
    pub url: Option<String>,
    #[serde(default)]
    pub component_names: Vec<String>,
    #[serde(with = "time::serde::rfc3339::option", default)]
    pub resolved_at: Option<OffsetDateTime>,
}

impl StatusIncident {
    /// Seconds since it started — to resolution if it got there, else to
    /// `now`. The banner's "going 1h 12m".
    pub fn duration_seconds(&self, now: OffsetDateTime) -> f64 {
        let end = self.resolved_at.unwrap_or(now);
        (end - self.started_at).as_seconds_f64().max(0.0)
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusMaintenance {
    pub id: String,
    pub name: String,
    /// "scheduled" | "in_progress" | "verifying" | "completed".
    pub phase: String,
    #[serde(with = "time::serde::rfc3339::option", default)]
    pub window_start: Option<OffsetDateTime>,
    #[serde(with = "time::serde::rfc3339::option", default)]
    pub window_end: Option<OffsetDateTime>,
}

impl StatusMaintenance {
    pub fn is_active(&self) -> bool {
        self.phase == "in_progress" || self.phase == "verifying"
    }
}

/// One recent session, render-ready. Titles and a basename-only project
/// label are permitted by the digest's dated 2026-08-17 §10 re-amendment;
/// no field here may carry a path, and the TUI never derives one.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionCard {
    pub id: String,
    pub title: String,
    pub project: Option<String>,
    pub branch: Option<String>,
    #[serde(with = "time::serde::rfc3339")]
    pub started_at: OffsetDateTime,
    pub active_seconds: f64,
    /// None = nothing priceable — absent, never 0.
    pub cost: Option<f64>,
    pub tokens: i64,
    pub prompts: i64,
    pub api_calls: i64,
    pub model_colors: Vec<Rgb>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineStatus {
    #[serde(rename = "providerID")]
    pub provider_id: String,
    pub service_name: String,
    pub agent_name: String,
    pub glyph: String,
    pub accent: Rgb,
    /// The host Mac's control accent (dark-appearance sRGB); absent from
    /// engines that predate the field — fall back to the provider accent.
    #[serde(default)]
    pub system_accent: Option<Rgb>,
    pub plan_label: Option<String>,
    pub app_version: String,
    pub pid: i64,
    /// "app" | "daemon".
    pub host: String,
    #[serde(with = "time::serde::rfc3339")]
    pub generated_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339::option", default)]
    pub fetched_at: Option<OffsetDateTime>,
    #[serde(with = "time::serde::rfc3339::option", default)]
    pub next_poll_at: Option<OffsetDateTime>,
    #[serde(with = "time::serde::rfc3339::option", default)]
    pub backoff_until: Option<OffsetDateTime>,
    pub stale: bool,
    pub is_local_provider: bool,
    pub active_interval_seconds: f64,
    pub pace_multiplier: i32,
    pub api_budget_used: Option<i64>,
    pub api_budget_ceiling: Option<i64>,
    pub api_budget_fraction: Option<f64>,
    pub error: Option<ErrorStatus>,
    /// The provider's extra-usage credits line, when one was sent.
    #[serde(default)]
    pub spend: Option<SpendStatus>,
    /// How far along the learned weekly rhythm is. Absent only from
    /// engines that predate the field — a machine with no profile yet
    /// still publishes one carrying the full countdown.
    #[serde(default)]
    pub forecast_profile: Option<ForecastProfile>,
}

/// Mirror of ForecastProfile — the maturity of the weekly rhythm behind
/// the personalized forecast. The caption is pre-phrased by the engine and
/// goes silent once ready; we render it, we never count days ourselves.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ForecastProfile {
    pub is_ready: bool,
    pub history_span_seconds: f64,
    /// None once ready — absent, not zero.
    pub remaining_seconds: Option<f64>,
    pub caption: Option<String>,
}

/// Mirror of SpendStatus — minor units + currency; formatting is ours.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpendStatus {
    pub used_minor: i64,
    pub limit_minor: Option<i64>,
    pub currency: String,
    pub exponent: i32,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorStatus {
    pub text: String,
    pub hint: Option<String>,
    pub code: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
pub struct Rgb {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveMeter {
    pub id: String,
    pub label: String,
    pub tag: String,
    pub percent: Option<i64>,
    /// "normal" | "warning" | "critical".
    pub level: String,
    pub rank: i32,
    pub risk: Option<Rgb>,
    #[serde(with = "time::serde::rfc3339::option", default)]
    pub resets_at: Option<OffsetDateTime>,
    pub limit_window: Option<f64>,
    pub scoped_model_name: Option<String>,
    pub reset_caption: Option<String>,
    pub forecast: Option<MeterForecast>,
    pub series: Vec<SeriesPoint>,
    pub stretches: Vec<Stretch>,
    /// Per-model cumulative curves over this window, on `series`' own
    /// percent axis, coloured by the engine's ledger — never re-derived
    /// here. Default-empty for engines that predate the field.
    #[serde(default)]
    pub model_series: Vec<ModelSeries>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelSeries {
    pub model: String,
    pub display_name: String,
    pub color: Rgb,
    pub points: Vec<SeriesPoint>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeterForecast {
    pub projected_at_reset: Option<i64>,
    #[serde(with = "time::serde::rfc3339::option", default)]
    pub exhausts_at: Option<OffsetDateTime>,
    /// "green" | "yellow" | "red".
    pub verdict: String,
    pub severity: f64,
    pub caption: Option<String>,
    pub curve: Vec<SeriesPoint>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
pub struct SeriesPoint {
    #[serde(with = "time::serde::rfc3339")]
    pub t: OffsetDateTime,
    pub percent: f64,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Stretch {
    #[serde(with = "time::serde::rfc3339")]
    pub start: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub end: OffsetDateTime,
    pub exhausted: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SegmentStatus {
    pub tag: String,
    pub percent: Option<i64>,
    pub level: String,
    pub severity: Option<f64>,
    pub risk: Option<Rgb>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelRow {
    pub id: String,
    pub display_name: String,
    pub color: Rgb,
    pub tally: Tally,
    /// None = unpriced. Never 0 for "unknown".
    pub cost: Option<f64>,
}

#[derive(Debug, Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tally {
    pub input: i64,
    pub output: i64,
    pub cache_creation: i64,
    pub cache_read: i64,
    #[serde(default)]
    pub cache_creation1h: i64,
}

impl Tally {
    pub fn total(&self) -> i64 {
        self.input + self.cache_creation + self.cache_read + self.output
    }

    /// Input the model processed anew — fresh prompt plus cache writes.
    /// The app's tables show this apart from cache re-reads, which dwarf
    /// it in an agentic loop and would misread as typed prompt volume.
    pub fn uncached_input(&self) -> i64 {
        self.input + self.cache_creation
    }

    /// `cacheCreation1h` is a SLICE of cacheCreation (a costlier TTL), not
    /// a fifth class — summing it here would double-count.
    pub fn add(&mut self, other: Tally) {
        self.input += other.input;
        self.output += other.output;
        self.cache_creation += other.cache_creation;
        self.cache_read += other.cache_read;
        self.cache_creation1h += other.cache_creation1h;
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityRollup {
    pub time_zone: String,
    pub today_hours: Vec<HourBucket>,
    pub today_tokens: i64,
    pub today_prompts: i64,
    pub today_cost: Option<f64>,
    pub days: Vec<DayRollup>,
    pub model_days: Vec<ModelDayRollup>,
    pub hour_days: Vec<DayHours>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
pub struct HourBucket {
    pub hour: u8,
    pub tokens: i64,
    pub cost: Option<f64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DayRollup {
    pub day_key: String,
    pub tokens: i64,
    pub prompts: i64,
    pub cost: Option<f64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelDayRollup {
    pub day_key: String,
    pub models: Vec<ModelRow>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DayHours {
    pub day_key: String,
    pub hours: Vec<HourBucket>,
}

impl LiveState {
    pub fn parse(bytes: &[u8]) -> Result<Self, serde_json::Error> {
        serde_json::from_slice(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// The Swift suite's golden — one file, two decoders, zero drift.
    fn golden() -> Vec<u8> {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../Tests/UsageCoreTests/Fixtures/digest/live-state-v1.json");
        std::fs::read(&path)
            .unwrap_or_else(|e| panic!("missing golden fixture {}: {e}", path.display()))
    }

    #[test]
    fn golden_fixture_decodes() {
        let state = LiveState::parse(&golden()).expect("golden must decode");
        assert_eq!(state.schema_version, 1);
        assert_eq!(state.engine.provider_id, "claude");
        assert_eq!(state.engine.host, "app");
        assert_eq!(state.meters.len(), 2);
        assert_eq!(state.menu_bar.len(), 3);
        let accent = state.engine.system_accent.expect("golden carries systemAccent");
        assert!((accent.blue - 1.0).abs() < 1e-9);
        // The maturity countdown, phrased once by the engine: three days
        // of the fourteen collected, so the note is still owed.
        let profile = state
            .engine
            .forecast_profile
            .as_ref()
            .expect("golden carries forecastProfile");
        assert!(!profile.is_ready);
        assert_eq!(profile.remaining_seconds, Some(11.0 * 86400.0));
        assert_eq!(
            profile.caption.as_deref(),
            Some("Personalized forecast activates in 11 days — learning your weekly rhythm.")
        );
    }

    #[test]
    fn absent_is_none_never_zero() {
        let state = LiveState::parse(&golden()).unwrap();
        let weekly = state
            .meters
            .iter()
            .find(|m| m.id == "weekly_all")
            .expect("weekly meter in golden");
        assert!(weekly.percent.is_none(), "unreported percent must be None");
        assert!(weekly.forecast.is_none());
        let mystery = state
            .models
            .iter()
            .find(|m| m.id == "mystery-model")
            .expect("unpriced model in golden");
        assert!(mystery.cost.is_none(), "unpriced cost must be None");
        let priced = state.models.iter().find(|m| m.id == "claude-fable-5").unwrap();
        assert!(priced.cost.is_some());
        // The prompt-only day has no cost key at all.
        let prompt_only = state
            .activity
            .days
            .iter()
            .find(|d| d.day_key == "2026-08-14")
            .unwrap();
        assert!(prompt_only.cost.is_none());
        assert_eq!(prompt_only.prompts, 4);
    }

    #[test]
    fn meter_vocabulary_and_series_arrive() {
        let state = LiveState::parse(&golden()).unwrap();
        let session = state.meters.iter().find(|m| m.id == "session").unwrap();
        assert_eq!(session.tag, "S");
        assert_eq!(session.level, "normal");
        assert_eq!(session.rank, 0);
        assert_eq!(session.reset_caption.as_deref(), Some("resets in 2h"));
        assert!(session.risk.is_some());
        assert!(!session.series.is_empty());
        assert_eq!(session.stretches.len(), 2);
        let forecast = session.forecast.as_ref().unwrap();
        assert_eq!(forecast.verdict, "green");
        assert_eq!(forecast.projected_at_reset, Some(78));
    }

    /// Additive evolution: a reader must survive fields it has never heard
    /// of, at every level.
    #[test]
    fn unknown_fields_are_ignored() {
        let mut value: serde_json::Value = serde_json::from_slice(&golden()).unwrap();
        value["someFutureField"] = serde_json::json!({"deep": [1, 2, 3]});
        value["engine"]["futureEngineFact"] = serde_json::json!(42);
        value["meters"][0]["futureMeterFact"] = serde_json::json!("yes");
        let bytes = serde_json::to_vec(&value).unwrap();
        LiveState::parse(&bytes).expect("unknown fields must not break decode");
    }
}

#[cfg(test)]
mod wave4_tests {
    use super::*;

    fn golden_bytes() -> Vec<u8> {
        std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../Tests/UsageCoreTests/Fixtures/digest/live-state-v1.json"
        ))
        .expect("golden fixture")
    }

    fn golden() -> LiveState {
        serde_json::from_slice(&golden_bytes()).expect("golden decodes")
    }

    /// Item 20: the per-model curves arrive with the engine's ledger colour
    /// attached, so the TUI paints the app's colours instead of guessing.
    #[test]
    fn per_model_series_arrive_coloured() {
        let state = golden();
        let meter = state
            .meters
            .iter()
            .find(|m| m.id == "session")
            .expect("session meter");

        assert!(!meter.model_series.is_empty());
        let curve = meter
            .model_series
            .iter()
            .find(|c| c.model == "claude-fable-5")
            .expect("fable curve");
        assert!(!curve.display_name.is_empty());
        assert!(!curve.points.is_empty());
        // Cumulative and inside one limit — the engine caps a meter window.
        let values: Vec<f64> = curve.points.iter().map(|p| p.percent).collect();
        assert!(values.windows(2).all(|w| w[0] <= w[1]));
        assert!(values.iter().all(|v| *v <= 100.0));
        // The same colour the models table publishes.
        let row = state
            .models
            .iter()
            .find(|m| m.id == "claude-fable-5")
            .expect("fable row");
        assert_eq!(curve.color, row.color);
    }

    /// Item 25: sessions decode, and the §10 promise holds on the wire —
    /// the project is a basename and nothing carries a path.
    #[test]
    fn sessions_decode_without_paths() {
        let state = golden();
        assert_eq!(state.sessions.len(), 2);

        let first = &state.sessions[0];
        assert_eq!(first.id, "session-a");
        assert_eq!(first.project.as_deref(), Some("main"));
        assert_eq!(first.tokens, 9535);
        assert_eq!(first.prompts, 12);
        assert!(!first.model_colors.is_empty());

        for card in &state.sessions {
            for field in [Some(card.title.clone()), card.project.clone(), card.branch.clone()]
                .into_iter()
                .flatten()
            {
                assert!(!field.contains('/'), "path leaked: {field}");
                assert!(!field.contains('~'), "home leaked: {field}");
            }
        }
    }

    /// The status card crosses the language boundary whole — every arm the
    /// Swift golden exercises has to arrive here too.
    #[test]
    fn service_status_decodes_with_every_arm() {
        let state = golden();
        let card = state
            .service_status
            .as_ref()
            .expect("golden carries serviceStatus");

        assert_eq!(card.indicator, "minor");
        assert_eq!(card.description_text, "Partially Degraded Service");
        assert_eq!(card.page_url, "https://status.claude.com");
        assert!(!card.stale);
        assert!(card.has_incident());

        let incident = card.active_incident().expect("active incident");
        assert_eq!(incident.name, "Degraded performance for multiple models");
        assert_eq!(incident.phase, "monitoring");
        assert!(incident
            .last_message
            .as_deref()
            .unwrap()
            .starts_with("A fix has been implemented"));
        assert_eq!(incident.component_names, vec!["claude.ai"]);
        assert!(incident.resolved_at.is_none());
        // Going 1h 12m at the digest's own `now`.
        let now = OffsetDateTime::parse(
            "2026-08-16T12:01:00Z",
            &time::format_description::well_known::Rfc3339,
        )
        .unwrap();
        assert_eq!(incident.duration_seconds(now), 4320.0);

        // A degraded component and an operational one both arrive.
        assert_eq!(card.components.len(), 3);
        assert!(!card.components[0].is_operational());
        assert!(card.components[1].is_operational());

        // The hour-long resolved memory is separate from the active list.
        assert_eq!(card.recently_resolved.len(), 1);
        assert!(card.recently_resolved[0].resolved_at.is_some());

        // A scheduled (not in-progress) maintenance is not active.
        assert_eq!(card.maintenances.len(), 1);
        assert!(!card.maintenances[0].is_active());
    }

    /// A digest from before the feature must decode with no card at all —
    /// and a missing card is NOT a healthy one.
    #[test]
    fn an_absent_status_card_is_none_not_healthy() {
        let mut value: serde_json::Value = serde_json::from_slice(&golden_bytes()).unwrap();
        value
            .as_object_mut()
            .unwrap()
            .remove("serviceStatus")
            .expect("golden had one to remove");
        let bytes = serde_json::to_vec(&value).unwrap();
        let state = LiveState::parse(&bytes).expect("older digests still decode");
        assert!(state.service_status.is_none());
    }

    /// The update card crosses the language boundary whole — including the
    /// `assetURL` spelling, which camelCase alone would miss.
    #[test]
    fn app_update_decodes_with_the_asset() {
        let state = golden();
        let card = state.app_update.as_ref().expect("golden carries appUpdate");

        assert_eq!(card.latest_version, "0.99.0");
        assert!(card.update_available);
        assert_eq!(card.asset_name.as_deref(), Some("ClaudeUsage-0.99.0.zip"));
        assert!(card.asset_url.as_deref().unwrap().ends_with(".zip"));
        assert_eq!(card.asset_bytes, Some(6_234_881));
        assert!(card.published_at.is_some());
    }

    /// A pre-0.87.0 digest has no update card — None, never "up to date".
    #[test]
    fn an_absent_update_card_is_none_not_current() {
        let mut value: serde_json::Value = serde_json::from_slice(&golden_bytes()).unwrap();
        value
            .as_object_mut()
            .unwrap()
            .remove("appUpdate")
            .expect("golden had one to remove");
        let bytes = serde_json::to_vec(&value).unwrap();
        let state = LiveState::parse(&bytes).expect("older digests still decode");
        assert!(state.app_update.is_none());
    }

    /// Absent is None, never 0 — an unpriced session reports no cost.
    #[test]
    fn an_unpriced_session_has_no_cost() {
        let state = golden();
        let background = state
            .sessions
            .iter()
            .find(|s| s.id == "session-b")
            .expect("background session");

        assert!(background.cost.is_none());
        assert!(background.project.is_none());
    }
}
