//! Period-scoped activity math: which days a span covers, what each day is
//! worth in the chosen dimension, the per-model rollups the table shows,
//! and the stacked segments a day's bar is built from.
//!
//! Pure arrangement of published rows — the TUI still computes no usage.
//! Every figure here is a sum or a ratio of digest fields, and absent stays
//! absent: an unpriced model's cost is None all the way through, never 0.

use crate::digest::{ActivityRollup, DayRollup, ModelRow, Rgb, Tally};
use crate::state::{Dimension, Period};
use std::collections::HashMap;
use time::Date;

/// One model's totals across the scoped days, in the ledger's color.
#[derive(Debug, Clone)]
pub struct ModelTotal {
    pub id: String,
    pub display_name: String,
    pub color: Rgb,
    pub tally: Tally,
    /// None = nothing in scope was priceable. Never 0 for "unknown".
    pub cost: Option<f64>,
}

impl ModelTotal {
    /// What this row is worth in the active dimension — the value bars,
    /// heat, and ordering all read.
    pub fn value(&self, dimension: Dimension) -> f64 {
        match dimension {
            Dimension::Tokens => self.tally.total() as f64,
            Dimension::Cost => self.cost.unwrap_or(0.0),
        }
    }
}

impl From<&ModelRow> for ModelTotal {
    fn from(row: &ModelRow) -> Self {
        Self {
            id: row.id.clone(),
            display_name: row.display_name.clone(),
            color: row.color,
            tally: row.tally,
            cost: row.cost,
        }
    }
}

pub fn day_key(date: Date) -> String {
    date.format(crate::surfaces::DAY_KEY).unwrap_or_default()
}

/// The inclusive day span a period covers, `page` whole windows back. All
/// reaches to the oldest day the digest carries and ignores paging — it
/// already shows everything the calendar can.
pub fn span(period: Period, page: usize, today: Date, days: &[DayRollup]) -> (Date, Date) {
    let step = |length: i64| -> (Date, Date) {
        let end = today - time::Duration::days(length * page as i64);
        (end - time::Duration::days(length - 1), end)
    };
    match period {
        Period::Week => step(7),
        Period::Month => step(30),
        Period::All => {
            let oldest = days
                .first()
                .and_then(|day| Date::parse(&day.day_key, crate::surfaces::DAY_KEY).ok())
                .unwrap_or(today);
            (oldest.min(today), today)
        }
    }
}

/// A day's magnitude in the active dimension. Cost mode reads the day's
/// own priced sum — a day with nothing priceable is worth 0 there, exactly
/// as the app's cost index treats it.
pub fn day_value(day: &DayRollup, dimension: Dimension) -> f64 {
    match dimension {
        Dimension::Tokens => day.tokens as f64,
        Dimension::Cost => day.cost.unwrap_or(0.0),
    }
}

/// Per-model totals over the scoped days, heaviest first (the digest
/// builder's own ordering, re-applied after summing).
pub fn model_totals(activity: &ActivityRollup, start: &str, end: &str) -> Vec<ModelTotal> {
    let mut by_id: HashMap<&str, ModelTotal> = HashMap::new();
    for day in &activity.model_days {
        if day.day_key.as_str() < start || day.day_key.as_str() > end {
            continue;
        }
        for model in &day.models {
            // Identity from the first sighting, figures from every day —
            // seeding with the row's own tally would count day one twice.
            let entry = by_id.entry(model.id.as_str()).or_insert_with(|| ModelTotal {
                id: model.id.clone(),
                display_name: model.display_name.clone(),
                color: model.color,
                tally: Tally::default(),
                cost: None,
            });
            entry.tally.add(model.tally);
            if let Some(cost) = model.cost {
                *entry.cost.get_or_insert(0.0) += cost;
            }
        }
    }
    let mut rows: Vec<ModelTotal> = by_id.into_values().collect();
    rows.sort_by(|a, b| {
        b.tally
            .total()
            .cmp(&a.tally.total())
            .then_with(|| a.id.cmp(&b.id))
    });
    rows
}

/// True when the per-model horizon (~35 days) starts inside the scoped
/// span — the table then speaks for less than the period claims, and says
/// so rather than reading as complete.
pub fn model_horizon_truncates(activity: &ActivityRollup, start: &str) -> bool {
    activity
        .model_days
        .first()
        .is_some_and(|day| day.day_key.as_str() > start)
}

/// Days in scope with any recorded activity — the app's "N active days",
/// which counts a day the agent worked whether or not tokens survived to
/// prove it (swept transcripts leave prompt counts behind) and does not
/// change with the measure being charted.
pub fn active_days(days: &[DayRollup], start: &str, end: &str) -> usize {
    days.iter()
        .filter(|day| day.day_key.as_str() >= start && day.day_key.as_str() <= end)
        .filter(|day| day.tokens > 0 || day.prompts > 0)
        .count()
}

/// The scoped total in the active dimension.
pub fn total_value(days: &[DayRollup], start: &str, end: &str, dimension: Dimension) -> f64 {
    days.iter()
        .filter(|day| day.day_key.as_str() >= start && day.day_key.as_str() <= end)
        .map(|day| day_value(day, dimension))
        .sum()
}

/// One day's bar, split by model in the period's own stacking order so the
/// bands line up across days: (color, fraction), heaviest first — callers
/// paint from the bottom up. Days without model attribution get no
/// segments and fall back to a plain fill.
pub fn segments(
    activity: &ActivityRollup,
    day_key: &str,
    order: &[ModelTotal],
    dimension: Dimension,
) -> Vec<(String, Rgb, f64)> {
    let Some(day) = activity
        .model_days
        .iter()
        .find(|entry| entry.day_key == day_key)
    else {
        return Vec::new();
    };
    let valued: Vec<(String, Rgb, f64)> = order
        .iter()
        .filter_map(|row| {
            let model = day.models.iter().find(|m| m.id == row.id)?;
            let value = match dimension {
                Dimension::Tokens => model.tally.total() as f64,
                Dimension::Cost => model.cost.unwrap_or(0.0),
            };
            (value > 0.0).then(|| (row.id.clone(), row.color, value))
        })
        .collect();
    let sum: f64 = valued.iter().map(|(_, _, value)| value).sum();
    if sum <= 0.0 {
        return Vec::new();
    }
    valued
        .into_iter()
        .map(|(id, color, value)| (id, color, value / sum))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use time::macros::date;

    fn rollup(key: &str, tokens: i64, cost: Option<f64>) -> DayRollup {
        DayRollup {
            day_key: key.into(),
            tokens,
            prompts: 0,
            cost,
        }
    }

    #[test]
    fn spans_step_whole_windows_back() {
        let today = date!(2026 - 08 - 16);
        assert_eq!(
            span(Period::Week, 0, today, &[]),
            (date!(2026 - 08 - 10), today)
        );
        assert_eq!(
            span(Period::Week, 1, today, &[]),
            (date!(2026 - 08 - 03), date!(2026 - 08 - 09))
        );
        assert_eq!(
            span(Period::Month, 0, today, &[]),
            (date!(2026 - 07 - 18), today)
        );
        // All reaches the oldest published day, paging or not.
        let days = [rollup("2026-01-05", 1, None)];
        assert_eq!(
            span(Period::All, 3, today, &days),
            (date!(2026 - 01 - 05), today)
        );
    }

    #[test]
    fn model_totals_sum_every_day_exactly_once() {
        let model = |id: &str, input: i64, cost: Option<f64>| ModelRow {
            id: id.into(),
            display_name: id.into(),
            color: Rgb {
                red: 1.0,
                green: 0.0,
                blue: 0.0,
            },
            tally: Tally {
                input,
                output: 0,
                cache_creation: 0,
                cache_read: 0,
                cache_creation1h: 0,
            },
            cost,
        };
        let activity = ActivityRollup {
            time_zone: "UTC".into(),
            today_hours: vec![],
            today_tokens: 0,
            today_prompts: 0,
            today_cost: None,
            days: vec![],
            model_days: vec![
                crate::digest::ModelDayRollup {
                    day_key: "2026-08-10".into(),
                    models: vec![model("a", 10, Some(1.0)), model("b", 5, None)],
                },
                crate::digest::ModelDayRollup {
                    day_key: "2026-08-11".into(),
                    models: vec![model("a", 30, Some(2.0))],
                },
                crate::digest::ModelDayRollup {
                    day_key: "2026-08-20".into(),
                    models: vec![model("a", 999, Some(99.0))],
                },
            ],
            hour_days: vec![],
        };
        let rows = model_totals(&activity, "2026-08-10", "2026-08-16");
        assert_eq!(rows.len(), 2);
        // Heaviest first, each day counted once, out-of-span days excluded.
        assert_eq!(rows[0].id, "a");
        assert_eq!(rows[0].tally.total(), 40);
        assert_eq!(rows[0].cost, Some(3.0));
        // An unpriced model stays unpriced — never $0.
        assert_eq!(rows[1].id, "b");
        assert_eq!(rows[1].cost, None);
    }

    #[test]
    fn totals_and_active_days_respect_the_dimension() {
        let days = [
            rollup("2026-08-10", 100, Some(1.0)),
            rollup("2026-08-11", 200, None),
            rollup("2026-08-12", 0, None),
        ];
        assert_eq!(
            total_value(&days, "2026-08-10", "2026-08-16", Dimension::Tokens),
            300.0
        );
        assert_eq!(active_days(&days, "2026-08-10", "2026-08-16"), 2);
        // In cost mode an unpriced day carries no magnitude...
        assert_eq!(
            total_value(&days, "2026-08-10", "2026-08-16", Dimension::Cost),
            1.0
        );
        // ...but the day was still worked: "active days" counts activity,
        // not the measure currently charted, as the app's does.
        assert_eq!(active_days(&days, "2026-08-10", "2026-08-16"), 2);
        // A day known only from prompt history (transcripts already swept)
        // is active too — its magnitude is unknown, not zero.
        let swept = [rollup("2026-08-13", 0, None)];
        assert_eq!(active_days(&swept, "2026-08-10", "2026-08-16"), 0);
        let prompted = [DayRollup {
            day_key: "2026-08-13".into(),
            tokens: 0,
            prompts: 4,
            cost: None,
        }];
        assert_eq!(active_days(&prompted, "2026-08-10", "2026-08-16"), 1);
        // Out-of-span days never leak in.
        assert_eq!(
            total_value(&days, "2026-08-11", "2026-08-11", Dimension::Tokens),
            200.0
        );
    }
}
