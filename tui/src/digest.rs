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

#[derive(Debug, Clone, Copy, Deserialize)]
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
