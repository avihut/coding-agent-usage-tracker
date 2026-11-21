//! The MODELS breakdown as rows: one account's models, or — under "All
//! agents" — the app's agent ▸ model outline (docs/CHARTS.md, the
//! consumption scope). Pure arrangement of published rows: each agent row
//! is the sum of its own models' period totals, and absent stays absent
//! (an agent whose models are all unpriced has no cost, never $0).

use crate::activity::{ModelTotal, row_key};
use crate::digest::{AllAgentsState, HarnessState, Rgb, Tally};

/// Why an agent row carries no figures.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Note {
    /// Its first scan hasn't landed: left out of the total, not zero.
    Scanning,
    /// Its traces carry no tokens (the writer's `noTokens`).
    NotCounted,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    Agent {
        id: String,
        glyph: String,
        short_name: String,
        accent: Rgb,
        note: Option<Note>,
    },
    /// An index into `Outline::models`.
    Model(usize),
}

#[derive(Debug, Clone)]
pub struct Row {
    /// The row's identity across frames and reloads — what a hover or the
    /// keyboard cursor holds, so a scan that lands and inserts rows above
    /// can't move the cursor onto a row nobody chose.
    pub id: String,
    pub kind: Kind,
    /// The row's figures: the model's own, or the sum of an agent's models.
    pub total: ModelTotal,
    /// Every model key the row counts — what hovering it highlights.
    pub keys: Vec<String>,
}

impl Row {
    pub fn is_agent(&self) -> bool {
        matches!(self.kind, Kind::Agent { .. })
    }
}

#[derive(Debug, Clone, Default)]
pub struct Outline {
    pub rows: Vec<Row>,
    /// The models in row order — the bars' stacking order, so they stack
    /// agent by agent with each agent's heaviest model at the bottom.
    pub models: Vec<ModelTotal>,
}

fn model_row(index: usize, model: &ModelTotal) -> Row {
    Row {
        id: model.key(),
        kind: Kind::Model(index),
        total: model.clone(),
        keys: vec![model.key()],
    }
}

/// One account's models, heaviest first, exactly as before the scope.
pub fn flat(models: Vec<ModelTotal>) -> Outline {
    let rows = models
        .iter()
        .enumerate()
        .map(|(index, model)| model_row(index, model))
        .collect();
    Outline { rows, models }
}

/// The agent ▸ model outline over the period's per-model totals. With one
/// agent in "all" (several accounts of it) the agent level says nothing and
/// the rows are its models. Agents order heaviest first; one still
/// scanning, or one that reports no tokens, keeps a dim row after every
/// counted one. An agent idle in the period has no row, like an idle model.
pub fn build(
    models: Vec<ModelTotal>,
    all: &AllAgentsState,
    harnesses: Option<&[HarnessState]>,
) -> Outline {
    let mut agents: Vec<&str> = Vec::new();
    for member in &all.members {
        if !agents.contains(&member.provider_id.as_str()) {
            agents.push(&member.provider_id);
        }
    }
    if agents.len() < 2 {
        return flat(models);
    }

    struct Group<'a> {
        id: &'a str,
        models: Vec<&'a ModelTotal>,
        note: Option<Note>,
        order: usize,
    }
    let mut groups: Vec<Group> = agents
        .iter()
        .enumerate()
        .map(|(order, id)| {
            let states: Vec<&str> = all
                .members
                .iter()
                .filter(|m| m.provider_id == *id)
                .map(|m| m.state.as_str())
                .collect();
            let note = if states.contains(&"counted") {
                None
            } else if states.contains(&"scanning") {
                Some(Note::Scanning)
            } else {
                Some(Note::NotCounted)
            };
            let mut mine: Vec<&ModelTotal> = models
                .iter()
                .filter(|model| model.agent.as_deref() == Some(*id))
                .collect();
            // Heaviest first under each agent, whatever order they came in.
            mine.sort_by(|a, b| {
                b.tally
                    .total()
                    .cmp(&a.tally.total())
                    .then_with(|| a.id.cmp(&b.id))
            });
            Group {
                id,
                models: mine,
                note,
                order,
            }
        })
        .filter(|group| group.note.is_some() || !group.models.is_empty())
        .collect();
    let weight = |group: &Group| -> i64 { group.models.iter().map(|m| m.tally.total()).sum() };
    groups.sort_by(|a, b| {
        a.note
            .is_some()
            .cmp(&b.note.is_some())
            .then_with(|| weight(b).cmp(&weight(a)))
            .then_with(|| a.order.cmp(&b.order))
    });

    let mut outline = Outline::default();
    for group in groups {
        let harness = harnesses.and_then(|list| list.iter().find(|h| h.id == group.id));
        let accent = harness.map_or(
            Rgb {
                red: 0.6,
                green: 0.6,
                blue: 0.62,
            },
            |h| h.accent,
        );
        let mut tally = Tally::default();
        let mut cost: Option<f64> = None;
        for model in &group.models {
            tally.add(model.tally);
            if let Some(dollars) = model.cost {
                *cost.get_or_insert(0.0) += dollars;
            }
        }
        outline.rows.push(Row {
            // A trailing separator: no model key ends in one.
            id: format!("{}\u{1f}", group.id),
            kind: Kind::Agent {
                id: group.id.to_owned(),
                glyph: harness.map_or_else(String::new, |h| h.glyph.clone()),
                short_name: harness.map_or_else(|| group.id.to_owned(), |h| h.short_name.clone()),
                accent,
                note: group.note,
            },
            total: ModelTotal {
                id: group.id.to_owned(),
                display_name: harness.map_or_else(|| group.id.to_owned(), |h| h.agent_name.clone()),
                color: accent,
                tally,
                cost,
                agent: Some(group.id.to_owned()),
            },
            keys: group
                .models
                .iter()
                .map(|m| row_key(m.agent.as_deref(), &m.id))
                .collect(),
        });
        for model in group.models {
            let index = outline.models.len();
            outline.models.push(model.clone());
            outline.rows.push(model_row(index, model));
        }
    }
    outline
}

/// Which rows a section with `seats` rows paints, in outline order, and
/// how many it had to leave out. Every agent row is seated before any
/// model row — an agent must never vanish from a total it is part of — then
/// the heaviest models fill what is left, each under its own agent. Short
/// of even that, the heaviest agents win.
pub fn seat(rows: &[Row], seats: usize) -> (Vec<usize>, usize) {
    if rows.len() <= seats {
        return ((0..rows.len()).collect(), 0);
    }
    let agents: Vec<usize> = (0..rows.len()).filter(|&i| rows[i].is_agent()).collect();
    if agents.is_empty() {
        return ((0..seats).collect(), rows.len() - seats);
    }
    if agents.len() >= seats {
        let shown: Vec<usize> = agents.into_iter().take(seats).collect();
        return (shown, rows.len() - seats);
    }
    let mut models: Vec<usize> = (0..rows.len()).filter(|&i| !rows[i].is_agent()).collect();
    models.sort_by(|&a, &b| {
        rows[b]
            .total
            .tally
            .total()
            .cmp(&rows[a].total.tally.total())
            .then(a.cmp(&b))
    });
    let mut shown: Vec<usize> = agents;
    shown.extend(models.into_iter().take(seats - shown.len()));
    shown.sort_unstable();
    (shown, rows.len() - seats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::digest::AllAgentsMember;

    fn total(agent: &str, id: &str, tokens: i64, cost: Option<f64>) -> ModelTotal {
        ModelTotal {
            id: id.into(),
            display_name: id.into(),
            color: Rgb {
                red: 1.0,
                green: 0.0,
                blue: 0.0,
            },
            tally: Tally {
                input: tokens,
                output: 0,
                cache_creation: 0,
                cache_read: 0,
                cache_creation1h: 0,
            },
            cost,
            agent: Some(agent.into()),
        }
    }

    fn all(members: &[(&str, &str)]) -> AllAgentsState {
        AllAgentsState {
            members: members
                .iter()
                .map(|(provider, state)| AllAgentsMember {
                    profile: (*provider).into(),
                    provider_id: (*provider).into(),
                    state: (*state).into(),
                })
                .collect(),
            count_label: String::new(),
            partial: false,
            models: None,
            activity: None,
        }
    }

    fn labels(outline: &Outline) -> Vec<String> {
        outline
            .rows
            .iter()
            .map(|row| match &row.kind {
                Kind::Agent { id, note, .. } => format!("{id}{}", note.map_or("", |_| "*")),
                Kind::Model(_) => format!("  {}", row.total.id),
            })
            .collect()
    }

    #[test]
    fn agents_lead_heaviest_first_with_their_models_under_them() {
        let models = vec![
            total("claude", "opus", 100, Some(2.0)),
            total("codex", "gpt", 300, None),
            total("claude", "sonnet", 250, Some(1.0)),
            total("codex", "unknown", 1, None),
            total("claude", "unknown", 1, None),
        ];
        let outline = build(
            models,
            &all(&[
                ("claude", "counted"),
                ("codex", "counted"),
                ("gemini", "noTokens"),
            ]),
            None,
        );
        assert_eq!(
            labels(&outline),
            [
                "claude",
                "  sonnet",
                "  opus",
                "  unknown",
                "codex",
                "  gpt",
                "  unknown",
                "gemini*"
            ]
        );
        // An agent's figures are its models' sum; unpriced stays absent.
        assert_eq!(outline.rows[0].total.tally.total(), 351);
        assert_eq!(outline.rows[0].total.cost, Some(3.0));
        assert_eq!(outline.rows[4].total.cost, None);
        // Hovering an agent lights exactly its own models — the two
        // `unknown`s are different models.
        assert_eq!(outline.rows[0].keys.len(), 3);
        assert!(!outline.rows[0].keys.contains(&outline.rows[6].keys[0]));
        // The bars stack in row order.
        let order: Vec<&str> = outline.models.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(order, ["sonnet", "opus", "unknown", "gpt", "unknown"]);
    }

    #[test]
    fn a_scanning_agent_keeps_a_row_and_an_idle_one_does_not() {
        let outline = build(
            vec![total("claude", "opus", 5, None)],
            &all(&[
                ("claude", "counted"),
                ("codex", "scanning"),
                ("agy", "counted"),
            ]),
            None,
        );
        assert_eq!(labels(&outline), ["claude", "  opus", "codex*"]);
        assert!(matches!(
            outline.rows[2].kind,
            Kind::Agent {
                note: Some(Note::Scanning),
                ..
            }
        ));
        assert!(outline.rows[2].keys.is_empty());
    }

    #[test]
    fn one_agent_in_all_is_its_models() {
        let outline = build(
            vec![total("claude", "opus", 5, None)],
            &all(&[("claude", "counted"), ("claude", "counted")]),
            None,
        );
        assert_eq!(labels(&outline), ["  opus"]);
    }

    #[test]
    fn seating_never_drops_an_agent_before_a_model() {
        let models = vec![
            total("claude", "a", 100, None),
            total("claude", "b", 90, None),
            total("codex", "c", 95, None),
            total("codex", "d", 1, None),
        ];
        let outline = build(
            models,
            &all(&[("claude", "counted"), ("codex", "counted")]),
            None,
        );
        // claude, a, b, codex, c, d
        assert_eq!(seat(&outline.rows, 6), (vec![0, 1, 2, 3, 4, 5], 0));
        // Four seats: both agents, then the two heaviest models, in place.
        assert_eq!(seat(&outline.rows, 4), (vec![0, 1, 3, 4], 2));
        // Two seats: agents only.
        assert_eq!(seat(&outline.rows, 2), (vec![0, 3], 4));
        assert_eq!(seat(&outline.rows, 1), (vec![0], 5));
        // A flat list seats its heaviest first, as it always did.
        let flat = flat(vec![total("x", "a", 2, None), total("x", "b", 1, None)]);
        assert_eq!(seat(&flat.rows, 1), (vec![0], 1));
    }
}
