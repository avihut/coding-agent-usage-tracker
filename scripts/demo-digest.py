#!/usr/bin/env python3
"""Write a synthetic live-state.json for screenshots and recordings.

The README's media must never show anybody's real usage, so the faces are
recorded against this instead: `usage-tui --digest` and `usage-cli --digest`
both read a digest from a path and compute nothing of their own.

The multi-harness contract golden (Tests/.../digest/live-state-v1-harnesses.json)
is the template — it is what both decoders are pinned to, so a digest built
on it decodes on both sides of the language boundary. The golden is
deliberately sparse (it exercises absent fields), which makes a poor demo;
this fills two harnesses, Claude Code and Codex, with a plausible twelve
weeks each. Everything is seeded, so two runs differ only by the
clock: every stamp is laid out relative to now, because a digest whose
resets are in the past renders as stale.

`--several` adds a second Claude Code account (two Sonnet versions, so the
Activity outline's family fold has something to fold) and Gemini CLI, whose
traces carry prompts and no tokens — the merged consumption scope's edge
states. The default output is unchanged by it (the extras draw their
randomness after everything else). `--scanning` publishes Codex as an
account whose first scan hasn't landed: named in the all-agents total and
left out of it, its own section empty as a scanning engine's is.

`--with-antigravity` adds Antigravity CLI with the five meters its quota
probe reads (Gemini session and weekly, the Claude + GPT pool's two, Gemini
4 Argon's weekly) — opt-in and drawn last too, so the other outputs keep
their bytes.

The all-agents section (`allAgents`) is rebuilt here from the synthesized
sections — the golden's own would describe the golden's accounts. It is a
plain sum of those sections, as the engine's is of its scans; the colours
are core `ModelColorMath.agentShade` outputs for the demo's ledgers (each
agent's families seeded heaviest first) and must be recomputed if that
math changes.

`--old-codex` publishes Codex on an OLD limits reading (`ReadingAge`): the
reported shape — Pro Lite, weekly 75%, read three and a half days ago, the
5 h session rolled since — with `asOf` set (its cell too), no forecast.
`--focus-codex` focuses Codex instead of Claude Code. Both opt-in and drawn
last, so every other output keeps its bytes.

usage: demo-digest.py [--several] [--scanning] [--with-antigravity] [--old-codex] [--focus-codex] <out.json>
"""

import copy
import json
import math
import random
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GOLDEN = ROOT / "Tests/UsageCoreTests/Fixtures/digest/live-state-v1-harnesses.json"
IDENTITY = ROOT / "Sources/UsageCore/AppIdentity.swift"

def rgb(red, green, blue):
    return {"red": red, "green": green, "blue": blue}


# id, display name, colour, share of tokens, $ per million tokens (blended)
CLAUDE_MODELS = [
    ("claude-fable-5", "Fable 5", rgb(0.851, 0.467, 0.341), 0.62, 3.75),
    ("claude-sonnet-5", "Sonnet 5", rgb(0.353, 0.557, 0.918), 0.30, 0.75),
    ("claude-haiku-4-5", "Haiku 4.5", rgb(0.478, 0.757, 0.553), 0.08, 0.375),
]
# The review model's long name is the panel's widest real one ("Codex Auto
# Review", 92.7pt): it keeps every snapshot honest about name overflow.
CODEX_MODELS = [
    ("gpt-5.2-codex", "GPT 5.2 Codex", rgb(0.063, 0.639, 0.498), 0.96, 0.45),
    ("codex-auto-review", "Codex Auto Review", rgb(0.420, 0.620, 0.970), 0.04, 0.45),
]
WORK_MODELS = [
    ("claude-sonnet-5", "Sonnet 5", rgb(0.353, 0.557, 0.918), 0.55, 0.75),
    ("claude-sonnet-4-5", "Sonnet 4.5", rgb(0.420, 0.620, 0.970), 0.30, 0.75),
    ("claude-haiku-4-5", "Haiku 4.5", rgb(0.478, 0.757, 0.553), 0.15, 0.375),
]
WORK_SESSIONS = [
    ("Quarterly report pipeline", "reports", "feat/q3"),
    ("Tidy the CI matrix", "infra", "chore/ci-matrix"),
]
ANTIGRAVITY_MODELS = [
    ("gemini-4-neon", "Gemini 4 Neon", rgb(0.631, 0.259, 0.957), 0.85, 0.9),
    ("gemini-4-argon", "Gemini 4 Argon", rgb(0.259, 0.522, 0.957), 0.15, 1.2),
]
CLAUDE_SESSIONS = [
    ("Add retry with backoff to the sync client", "sync-client", "fix/retry-backoff"),
    ("Why is the importer quadratic?", "importer", "main"),
    ("Migrate settings to the new form API", "webapp", "feat/settings-form"),
    ("Write property tests for the interval tree", "geometry", "test/interval-tree"),
    ("Review: pagination cursor off-by-one", "api", "fix/cursor"),
    ("Draft the 2.0 migration guide", "docs", "docs/migration-2.0"),
]
CODEX_SESSIONS = [
    ("Port the build script to the new runner", "infra", "chore/runner"),
    ("Flaky test: clock skew in the scheduler", "scheduler", "fix/clock-skew"),
    ("Generate API client from the OpenAPI spec", "api", "feat/client-gen"),
]
# RiskRamp's ends (UsageCore/Formatting/RiskRamp.swift): a forecast severity
# above zero inks a meter from yellow to red, and zero leaves it calm —
# `risk` absent, which is how the engine publishes it.
RAMP = ((1.0, 0.839, 0.039), (1.0, 0.271, 0.227))


def risk(severity):
    if severity <= 0:
        return None
    return rgb(*(round(low + (high - low) * min(1, severity), 4) for low, high in zip(*RAMP)))


# ModelColorMath.agentShade(hueSlot, shadeSlot, accent, on: .dark) — the
# digest's variant — for the demo's models when several agents share a
# chart; computed in Swift, pasted (see above).
AGENT_SHADES = {
    ("claude", "claude-fable-5"): rgb(0.851, 0.467, 0.341),
    ("claude", "claude-sonnet-5"): rgb(1.000, 0.525, 0.368),
    ("claude", "claude-haiku-4-5"): rgb(0.740, 0.564, 0.506),
    ("claude", "claude-sonnet-4-5"): rgb(1.000, 0.772, 0.697),
    ("codex", "gpt-5.2-codex"): rgb(0.063, 0.639, 0.498),
    ("codex", "codex-auto-review"): rgb(0.472, 0.776, 0.669),
    ("antigravity", "gemini-4-neon"): rgb(0.654, 0.288, 0.984),
    ("antigravity", "gemini-4-argon"): rgb(0.742, 0.524, 0.993),
}
HOUR_SPAN_DAYS = 8  # AllAgentsDigest.hourSpanDays


def count_label(members):
    """ConsumptionMembership.countLabel, over (agent, counted) pairs."""
    agents = list(dict.fromkeys(agent for agent, _ in members))
    if len(agents) <= 1:
        return f"{len(members)} accounts"
    counted = sum(1 for agent in agents if any(a == agent and c for a, c in members))
    return f"{len(agents)} agents" if counted == len(agents) else f"{counted} of {len(agents)} agents"


def all_agents(state, now, scanning=()):
    """The all-agents section: the strip's accounts of shown harnesses, the
    counted ones summed day by day, rows per agent + model."""
    shown = {h["id"] for h in state["harnesses"] if h["shown"]}
    members = [p for p in state["profiles"]
               if p["enabled"] and not p["dormant"] and p["providerID"] in shown]
    if len(members) < 2:
        return None
    states = []
    for profile in members:
        if profile["providerID"] == "gemini":
            states.append("noTokens")
        elif profile["providerID"] in scanning:
            states.append("scanning")
        else:
            states.append("counted")
    counted = [p for p, st in zip(members, states) if st == "counted"]
    spans = len({p["providerID"] for p in members}) > 1

    def add_cost(a, b):
        return b if a is None else (a if b is None else round(a + b, 6))

    days, model_days, hour_days = {}, {}, {}
    for profile in counted:
        agent, act = profile["providerID"], profile["activity"]
        for day in act["days"]:
            merged = days.setdefault(day["dayKey"], {"dayKey": day["dayKey"], "tokens": 0, "prompts": 0, "cost": None})
            merged["tokens"] += day["tokens"]
            merged["prompts"] += day["prompts"]
            merged["cost"] = add_cost(merged["cost"], day.get("cost"))
        for day in act["modelDays"]:
            rows = model_days.setdefault(day["dayKey"], {})
            for row in day["models"]:
                key = (agent, row["id"])
                if spans and key not in AGENT_SHADES:
                    sys.exit(f"no pasted agent shade for {key} — compute it with "
                             "ModelColorMath.agentShade and add it to AGENT_SHADES")
                merged = rows.setdefault(key, {
                    "id": row["id"], "displayName": row["displayName"], "agent": agent,
                    "color": AGENT_SHADES[key] if spans else row["color"],
                    "tally": {k: 0 for k in row["tally"]}, "cost": None})
                for k, v in row["tally"].items():
                    merged["tally"][k] += v
                merged["cost"] = add_cost(merged["cost"], row.get("cost"))
        floor = (now.date() - timedelta(days=HOUR_SPAN_DAYS - 1)).isoformat()
        for day in act["hourDays"]:
            if day["dayKey"] < floor:
                continue
            hours = hour_days.setdefault(day["dayKey"], {})
            for bucket in day["hours"]:
                merged = hours.setdefault(bucket["hour"], {"hour": bucket["hour"], "tokens": 0, "cost": None})
                merged["tokens"] += bucket["tokens"]
                merged["cost"] = add_cost(merged["cost"], bucket.get("cost"))

    def total(row):
        return sum(row["tally"][k] for k in ("input", "output", "cacheCreation", "cacheRead"))

    def ordered(rows):
        return sorted(rows, key=lambda r: (-total(r), r["agent"], r["id"]))

    def clean(entry):
        return {k: v for k, v in entry.items() if v is not None}

    members_out = [{"profile": p["id"], "providerID": p["providerID"], "state": st}
                   for p, st in zip(members, states)]
    label = count_label([(p["providerID"], st == "counted") for p, st in zip(members, states)])
    if not counted:
        # Nobody counted yet: no total, never a zero one.
        return {"members": members_out, "countLabel": label, "partial": "scanning" in states}
    # The section is a plain sum of the counted sections, day by day.
    for key in days:
        parts = sum(d["tokens"] for p in counted for d in p["activity"]["days"] if d["dayKey"] == key)
        assert days[key]["tokens"] == parts, f"{key}: {days[key]['tokens']} ≠ Σ {parts}"
    today = now.date().isoformat()
    day_list = [clean(d) for _, d in sorted(days.items())]
    hours = [{"dayKey": k, "hours": [clean(b) for _, b in sorted(v.items())]} for k, v in sorted(hour_days.items())]
    today_day = days.get(today)
    return {
        "members": members_out,
        "countLabel": label,
        "partial": "scanning" in states,
        "models": [clean(r) for r in ordered(model_days.get(today, {}).values())],
        "activity": clean({
            "timeZone": "GMT", "days": day_list,
            "modelDays": [{"dayKey": k, "models": [clean(r) for r in ordered(v.values())]}
                          for k, v in sorted(model_days.items())],
            "hourDays": hours,
            "todayHours": hours[-1]["hours"] if hours and hours[-1]["dayKey"] == today else [],
            "todayTokens": today_day["tokens"] if today_day else 0,
            "todayPrompts": today_day["prompts"] if today_day else 0,
            "todayCost": today_day.get("cost") if today_day else None,
        }),
    }


def stamp(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def tally(tokens):
    """Split a token total into the four classes; cache re-reads dominate."""
    return {
        "input": int(tokens * 0.04),
        "output": int(tokens * 0.03),
        "cacheCreation": int(tokens * 0.08),
        "cacheCreation1h": 0,
        "cacheRead": int(tokens * 0.85),
    }


def model_rows(tokens, models):
    return [
        {
            "id": model, "displayName": name, "color": color,
            "cost": round(tokens * share * rate / 1e6, 2),
            "tally": tally(tokens * share),
        }
        for model, name, color, share, rate in models
    ]


def climb(start, end, final, rng, step_minutes, idle=0.35):
    """A percent history: monotone from 0 to `final`, with idle plateaus."""
    count = max(2, int((end - start).total_seconds() // (step_minutes * 60)))
    gains = [0.0 if rng.random() < idle else rng.random() for _ in range(count)]
    total = sum(gains) or 1.0
    points, level = [{"t": stamp(start), "percent": 0}], 0.0
    for index, gain in enumerate(gains, start=1):
        level += gain / total * final
        points.append({"t": stamp(start + timedelta(minutes=step_minutes * index)),
                       "percent": round(level, 1)})
    points[-1] = {"t": stamp(end), "percent": final}
    return points


def stretches(series):
    """Active stretches: the runs where the history was actually rising."""
    out, begin = [], None
    for before, after in zip(series, series[1:]):
        rising = after["percent"] > before["percent"]
        if rising and begin is None:
            begin = before["t"]
        if not rising and begin is not None:
            out.append({"start": begin, "end": before["t"], "exhausted": False})
            begin = None
    if begin is not None:
        out.append({"start": begin, "end": series[-1]["t"], "exhausted": False})
    return out


def meter(now, rng, models, *, ident, label, tag, rank, window, elapsed, percent,
          projected, verdict, severity, step_minutes):
    start, reset = now - elapsed, now - elapsed + window
    series = climb(start, now, percent, rng, step_minutes)
    hours = (reset - now).total_seconds() / 3600
    caption = f"resets in {int(hours // 24)}d {int(hours % 24)}h" if hours >= 24 \
        else f"resets in {int(hours)}h {int(hours * 60 % 60)}m"
    rate = percent / (elapsed.total_seconds() / 3600)
    built = {
        "id": ident, "label": label, "tag": tag, "rank": rank, "level": "normal",
        "percent": percent, "limitWindow": int(window.total_seconds()),
        "rateWindowSeconds": 2700, "resetsAt": stamp(reset), "resetCaption": caption,
        "forcesWarning": False, "series": series, "stretches": stretches(series),
        "modelSeries": [
            {"model": model, "displayName": name, "color": color,
             "points": [{"t": p["t"], "percent": round(p["percent"] * share, 2)} for p in series]}
            for model, name, color, share, _ in models
        ],
        "forecast": {
            "basis": "windowAverage", "verdict": verdict, "rawVerdict": verdict,
            "severity": severity, "ratePerHour": round(rate, 2),
            "baselineRatePerHour": round(rate * 0.8, 2), "paceFactor": 1.25,
            "projectedAtReset": projected, "projectedUnclamped": projected,
            "curve": [{"t": stamp(now), "percent": percent},
                      {"t": stamp(reset), "percent": projected}],
        },
    }
    if risk(severity):
        built["risk"] = risk(severity)
    return built


def segment(built):
    out = {"tag": built["tag"], "percent": built["percent"], "level": built["level"],
           "resetsAt": built["resetsAt"], "severity": built["forecast"]["severity"]}
    if "risk" in built:
        out["risk"] = built["risk"]
    return out


def activity(now, rng, models, typical, days=84):
    """Twelve weeks of heatmap: busy weekdays, quiet weekends, a holiday."""
    today = now.date()
    rollups, by_model, by_hour = [], [], []
    for back in range(days - 1, -1, -1):
        day = today - timedelta(days=back)
        # Today is always busy: a recording made on a Sunday still needs one.
        weekend = day.weekday() >= 5 and back != 0
        holiday = 30 <= back <= 35
        if holiday or (weekend and rng.random() < 0.6):
            continue
        tokens = int(rng.lognormvariate(math.log(typical), 0.55) * (0.3 if weekend else 1.0))
        if back == 0:
            tokens = int(tokens * (now.hour + 1) / 24)
        rows = model_rows(tokens, models)
        cost = round(sum(row["cost"] for row in rows), 2)
        key = day.isoformat()
        rollups.append({"dayKey": key, "tokens": tokens, "cost": cost,
                        "prompts": max(3, tokens // 450_000)})
        by_model.append({"dayKey": key, "models": rows})
        last = now.hour if back == 0 else 22
        weights = {hour: rng.random() * (2.0 if 9 <= hour <= 18 else 0.4)
                   for hour in range(8, last + 1) if rng.random() < 0.75} or {now.hour: 1.0}
        scale = 1 / sum(weights.values())
        by_hour.append({"dayKey": key, "hours": [
            {"hour": hour, "tokens": int(tokens * weight * scale),
             "cost": round(cost * weight * scale, 2)}
            for hour, weight in sorted(weights.items())]})
    since = (today - timedelta(days=6)).isoformat()
    week = sum(day["tokens"] for day in rollups if day["dayKey"] >= since)
    return {
        "timeZone": "GMT", "days": rollups, "modelDays": by_model, "hourDays": by_hour,
        "todayHours": by_hour[-1]["hours"], "todayTokens": rollups[-1]["tokens"],
        "todayCost": rollups[-1]["cost"], "todayPrompts": rollups[-1]["prompts"],
    }, week


def sessions(now, rng, prefix, titles, models):
    rate = sum(share * price for _, _, _, share, price in models)
    out, cursor = [], now - timedelta(minutes=4)
    for index, (title, project, branch) in enumerate(titles):
        length = timedelta(minutes=rng.randint(25, 140))
        tokens = rng.randint(3, 40) * 1_000_000
        out.append({
            "id": f"demo-{prefix}-{index}", "title": title, "project": project, "branch": branch,
            "startedAt": stamp(cursor - length), "end": stamp(cursor),
            "activeSeconds": int(length.total_seconds() * 0.8),
            "apiCalls": tokens // 90_000, "prompts": rng.randint(4, 30), "tokens": tokens,
            "cost": round(tokens * rate / 1e6, 2), "accounts": [],
            "modelColors": [color for _, _, color, _, _ in models[: 1 + index % 3]],
        })
        cursor -= length + timedelta(minutes=rng.randint(20, 600))
    return out


def face(now, rng, section, *, models, meters, titles, typical, engine):
    """One account's section, from the golden's own as the template."""
    rollup, week = activity(now, rng, models, typical)
    built = copy.deepcopy(section)
    built["engine"].update({
        "fetchedAt": stamp(now - timedelta(minutes=2)), "generatedAt": stamp(now),
        "nextPollAt": stamp(now + timedelta(minutes=3)), "stale": False,
        "appVersion": re.search(r'version = "([^"]+)"', IDENTITY.read_text()).group(1),
        "forecastProfile": {"caption": "", "isReady": True,
                            "historySpanSeconds": 84 * 86400, "remainingSeconds": 0},
        **engine,
    })
    built.update({
        "meters": meters, "menuBar": [segment(m) for m in meters],
        "models": model_rows(week, models), "activity": rollup,
        "sessions": sessions(now, rng, section["id"], titles, models),
        "lastActivityAt": stamp(now - timedelta(minutes=4)), "dormant": False, "enabled": True,
    })
    built.pop("accountPresence", None)
    return built


def prompt_only(now, rng, days=84):
    """An agent whose traces count prompts and no tokens (Gemini CLI)."""
    today = now.date()
    rollups = []
    for back in range(days - 1, -1, -1):
        day = today - timedelta(days=back)
        if day.weekday() >= 5 or rng.random() < 0.3:
            continue
        rollups.append({"dayKey": day.isoformat(), "tokens": 0, "cost": 0,
                        "prompts": rng.randint(8, 60)})
    return {
        "timeZone": "GMT", "days": rollups, "modelDays": [], "hourDays": [],
        "todayHours": [], "todayTokens": 0, "todayCost": 0,
        "todayPrompts": rollups[-1]["prompts"] if rollups else 0,
    }


def add_several(now, rng, state, sections, cells):
    """A second Claude Code account and Gemini CLI (see the module doc)."""
    hours, days = lambda n: timedelta(hours=n), lambda n: timedelta(days=n)
    # The golden's extra sections are deliberately sparse; give them the
    # standard section's shape for whatever they leave out.
    for key in ("c982130e", "gemini"):
        for field, value in sections["default"].items():
            sections[key].setdefault(field, copy.deepcopy(value))
    work = face(
        now, rng, sections["c982130e"], models=WORK_MODELS, titles=WORK_SESSIONS,
        typical=12e6, engine={},
        meters=[
            meter(now, rng, WORK_MODELS, ident="session", label="Session (5h)", tag="S",
                  rank=0, window=hours(5), elapsed=hours(1), percent=12,
                  projected=30, verdict="green", severity=0, step_minutes=5),
            meter(now, rng, WORK_MODELS, ident="weekly_all", label="Weekly (all)", tag="W",
                  rank=1, window=days(7), elapsed=days(3), percent=27,
                  projected=55, verdict="green", severity=0, step_minutes=120),
        ])
    work.update({"label": "work@example.com", "monogram": "W", "isFocused": False})
    gemini = face(
        now, rng, sections["gemini"], models=[], titles=[], typical=1, engine={},
        meters=[
            meter(now, rng, [], ident="session", label="Daily · counted locally", tag="S",
                  rank=0, window=hours(24), elapsed=hours(9), percent=18,
                  projected=40, verdict="green", severity=0, step_minutes=60),
        ])
    gemini.update({"activity": prompt_only(now, rng), "models": [], "sessions": [],
                   "isFocused": False})
    state["profiles"] += [work, gemini]
    harnesses = {h["id"]: h for h in state["harnesses"]}
    for section, template in ((work, "default"), (gemini, "codex")):
        cell = copy.deepcopy(cells[template])
        harness = harnesses[section["providerID"]]
        cell.update({"profile": section["id"], "providerID": section["providerID"],
                     "glyph": harness["glyph"], "accent": harness["accent"],
                     "segments": section["menuBar"], "monogram": section["monogram"],
                     "stale": False, "indicator": False,
                     "worstSeverity": max(s["severity"] for s in section["menuBar"])})
        state["menuBarCells"].append(cell)


def add_antigravity(now, rng, state, sections, cells):
    """Antigravity's section and harness row, from the golden's Gemini ones
    (the same Google-family shape), with the real reading's meters."""
    hours, days = lambda n: timedelta(hours=n), lambda n: timedelta(days=n)
    template = copy.deepcopy(sections["gemini"])
    violet = rgb(0.631, 0.259, 0.957)
    template.update({"id": "antigravity", "providerID": "antigravity", "label": "default",
                     "monogram": "A", "isFocused": False})
    template["engine"].update({"providerID": "antigravity", "agentName": "Antigravity CLI",
                               "glyph": "∩", "accent": violet})
    gemini, argon = ANTIGRAVITY_MODELS[:1], ANTIGRAVITY_MODELS[1:]
    session = meter(now, rng, gemini, ident="0-session", label="Session (5h)", tag="S",
                    rank=0, window=hours(5), elapsed=timedelta(hours=2, minutes=6), percent=25,
                    projected=52, verdict="green", severity=0, step_minutes=5)
    weekly = meter(now, rng, gemini, ident="1-weekly", label="Weekly", tag="W",
                   rank=1, window=days(7), elapsed=timedelta(hours=7), percent=23,
                   projected=61, verdict="green", severity=0, step_minutes=60)
    for built in (session, weekly):
        built["modelScope"] = ["gemini", "!argon"]
    pool = []
    for ident, label, window in (("2-3p-5h", "Claude + GPT (5h)", hours(5)),
                                 ("2-3p-weekly", "Claude + GPT (7d)", days(7))):
        # An untouched pool: 0% and no window running, so no reset.
        built = meter(now, rng, [], ident=ident, label=label, tag="C", rank=2, window=window,
                      elapsed=hours(1), percent=0, projected=0, verdict="green",
                      severity=0, step_minutes=60)
        for key in ("resetsAt", "resetCaption", "forecast"):
            built.pop(key, None)
        built.update({"scopedModelName": "Claude + GPT", "modelScope": ["claude", "gpt"]})
        pool.append(built)
    argon_weekly = meter(now, rng, argon, ident="2-gemini-argon-wtu-weekly", label="Argon (7d)",
                         tag="A", rank=2, window=days(7), elapsed=timedelta(hours=7),
                         percent=2, projected=6, verdict="green", severity=0, step_minutes=60)
    argon_weekly.update({"scopedModelName": "Argon", "modelScope": ["argon"]})
    # The bar: S, W, and the most-used scoped meter; the panel: all five.
    section = face(now, rng, template, models=ANTIGRAVITY_MODELS, titles=[], typical=6e6,
                   engine={}, meters=[session, weekly, argon_weekly])
    section["meters"] = [session, weekly, *pool, argon_weekly]
    golden = json.loads(GOLDEN.read_text())["harnesses"]
    harness = copy.deepcopy(next(h for h in golden if h["id"] == "gemini"))
    harness.update({"id": "antigravity", "agentName": "Antigravity CLI", "shortName": "Antigravity",
                    "glyph": "∩", "accent": violet, "serviceName": "Google AI"})
    harness.pop("deprecationNote", None)
    state["profiles"].append(section)
    state["harnesses"].append(harness)
    cell = copy.deepcopy(cells["codex"])
    cell.update({"profile": "antigravity", "providerID": "antigravity", "glyph": "∩",
                 "monogram": "A", "accent": violet, "segments": section["menuBar"],
                 "stale": False, "indicator": False,
                 "worstSeverity": max(s["severity"] for s in section["menuBar"])})
    state["menuBarCells"].append(cell)


def as_of_caption(moment, now):
    """Core's `UsageFormatting.asOfText`: the day-aware stamp, local time."""
    local, today = moment.astimezone(), now.astimezone()
    if local.date() == today.date():
        text = local.strftime("%H:%M")
    elif (now - moment) < timedelta(days=7):
        text = local.strftime("%a %H:%M")
    else:
        text = f"{local.strftime('%b')} {local.day} {local.strftime('%H:%M')}"
    return f"as of {text}"


def make_old_codex(now, rng, state, codex):
    """Codex on the reporter's reading: old, so no forecast and a stale cell."""
    read_at = now - timedelta(days=3, hours=12, minutes=47)
    weekly = meter(read_at, rng, CODEX_MODELS, ident="1-weekly", label="Weekly", tag="W",
                   rank=1, window=timedelta(days=7), elapsed=timedelta(days=1, hours=20),
                   percent=75, projected=100, verdict="red", severity=1, step_minutes=120)
    hours = (datetime.fromisoformat(weekly["resetsAt"].replace("Z", "+00:00")) - now) \
        .total_seconds() / 3600
    weekly["resetCaption"] = f"resets in {int(hours // 24)}d {int(hours % 24)}h"
    session = {"id": "0-session", "label": "Session (5h)", "tag": "S", "rank": 0,
               "level": "normal", "percent": 0, "limitWindow": 5 * 3600,
               "rateWindowSeconds": 2700, "forcesWarning": False, "series": [],
               "stretches": [], "modelSeries": []}
    meters = [session, weekly]
    for built in meters:
        built.pop("forecast", None)
        built.pop("risk", None)
    menu_bar = [{key: m[key] for key in ("tag", "percent", "level", "resetsAt") if key in m}
                for m in meters]
    codex.update({"meters": meters, "menuBar": menu_bar})
    codex["engine"].update({
        "fetchedAt": stamp(read_at), "asOf": stamp(read_at),
        "asOfCaption": as_of_caption(read_at, now),
        "planLabel": "Pro Lite plan", "planDisplayName": "Pro Lite",
        "planSubscriptionType": "prolite"})
    for cell in state["menuBarCells"]:
        if cell["profile"] == codex["id"]:
            # `stale` keeps its meaning (cache-served or errored); the cell
            # says its age beside it, as the composer writes it.
            cell.update({"segments": menu_bar, "stale": False,
                         "asOf": codex["engine"]["asOf"],
                         "asOfCaption": codex["engine"]["asOfCaption"]})
            cell.pop("worstSeverity", None)


def focus(state, section):
    """The top level answers for the focused account."""
    for other in state["profiles"]:
        other["isFocused"] = other["id"] == section["id"]
    # A scanning section leaves activity, models and sessions absent, and
    # the top level follows it.
    for key in ("activity", "engine", "menuBar", "meters", "models", "sessions",
                "activityStatus"):
        if key in section:
            state[key] = copy.deepcopy(section[key])
        else:
            state.pop(key, None)
    state["focusedProfile"] = section["id"]


def build(now, several=False, with_antigravity=False, scanning=False,
          old_codex=False, focus_codex=False):
    rng = random.Random(5)
    state = json.loads(GOLDEN.read_text())
    sections = {section["id"]: section for section in state["profiles"]}
    hours, days = lambda n: timedelta(hours=n), lambda n: timedelta(days=n)
    week_in = timedelta(days=4, hours=6)
    claude = face(
        now, rng, sections["default"], models=CLAUDE_MODELS, titles=CLAUDE_SESSIONS,
        typical=28e6, engine={"apiBudgetUsed": 4, "apiBudgetFraction": 0.2,
                              "planLabel": "Max plan", "planDisplayName": "Max",
                              "planRateLimitTier": "default_claude_max_5x"},
        meters=[
            meter(now, rng, CLAUDE_MODELS, ident="session", label="Session (5h)", tag="S",
                  rank=0, window=hours(5), elapsed=timedelta(hours=2, minutes=10), percent=34,
                  projected=71, verdict="green", severity=0, step_minutes=5),
            meter(now, rng, CLAUDE_MODELS, ident="weekly_all", label="Weekly (all)", tag="W",
                  rank=1, window=days(7), elapsed=week_in, percent=59,
                  projected=93, verdict="yellow", severity=0.35, step_minutes=120),
            meter(now, rng, CLAUDE_MODELS[:1], ident="weekly_fable", label="Weekly (Fable)",
                  tag="F", rank=2, window=days(7), elapsed=week_in, percent=22,
                  projected=38, verdict="green", severity=0, step_minutes=120),
        ])
    claude.update({"label": "dev@example.com", "monogram": "D", "isFocused": True})
    codex = face(
        now, rng, sections["codex"], models=CODEX_MODELS, titles=CODEX_SESSIONS,
        typical=9e6, engine={},
        # Codex publishes ONE window today, and it is a week long — which the
        # provider names by its length, whatever slot carried it.
        meters=[
            meter(now, rng, CODEX_MODELS, ident="1-weekly", label="Weekly", tag="W",
                  rank=1, window=days(7), elapsed=timedelta(days=2, hours=9), percent=41,
                  projected=88, verdict="green", severity=0, step_minutes=120),
        ])
    codex["isFocused"] = False

    # The top level answers for the focused account.
    for key in ("activity", "engine", "menuBar", "meters", "models", "sessions"):
        state[key] = copy.deepcopy(claude[key])
    state["profiles"] = [claude, codex]
    state["focusedProfile"] = claude["id"]
    # A demo has no outage, no pending notice and no update to advertise.
    quiet = {"indicator": False, "items": [], "pendingCount": 0}
    state["notices"] = quiet
    for key in ("serviceStatus", "outages", "appUpdate", "accountPresence"):
        state.pop(key, None)
    cells = {cell["profile"]: cell for cell in state["menuBarCells"]}
    templates = copy.deepcopy(cells)
    state["menuBarCells"] = []
    for section in (claude, codex):
        cell = cells[section["id"]]
        cell.update({"segments": section["menuBar"], "monogram": section["monogram"],
                     "stale": False, "indicator": False,
                     "worstSeverity": max(s["severity"] for s in section["menuBar"])})
        state["menuBarCells"].append(cell)
    kept = ("claude", "codex", "gemini") if several else ("claude", "codex")
    state["harnesses"] = [h for h in state["harnesses"] if h["id"] in kept]
    if several:
        add_several(now, rng, state, sections, templates)
    if with_antigravity:
        add_antigravity(now, rng, state, sections, templates)
    for harness in state["harnesses"]:
        count = sum(1 for p in state["profiles"] if p["providerID"] == harness["id"])
        harness.update({"accountCount": count, "present": True, "shown": True,
                        "notices": copy.deepcopy(quiet), "outages": [],
                        "newestActivityAt": stamp(now - timedelta(minutes=4))})
        harness.pop("serviceStatus", None)
    # Every demo account's activity is a finished scan of its own: the golden
    # template exercises "scanning" and "cached" too, and a demo must show
    # neither unless a picture asks for it.
    scanned = {"state": "scanned", "asOf": stamp(now - timedelta(minutes=1))}
    state["activityStatus"] = copy.deepcopy(scanned)
    for section in state["profiles"]:
        section["activityStatus"] = copy.deepcopy(scanned)
    if scanning:
        # A scanning engine publishes nothing of its own yet: the writer
        # marks it and leaves its activity, models and sessions ABSENT —
        # never an empty rollup (docs/DAEMON.md "Under load").
        codex["activityStatus"] = {"state": "scanning"}
        for key in ("activity", "models", "sessions"):
            codex.pop(key, None)
    if old_codex:
        make_old_codex(now, rng, state, codex)
    if focus_codex:
        focus(state, codex)
    section = all_agents(state, now, scanning=("codex",) if scanning else ())
    if section is None:
        state.pop("allAgents", None)
    else:
        state["allAgents"] = section
    return state


def main():
    flags = ("--several", "--with-antigravity", "--scanning", "--old-codex", "--focus-codex")
    args = sys.argv[1:]
    paths = [a for a in args if a not in flags]
    if len(paths) != 1 or paths[0].startswith("-"):
        sys.exit(__doc__.strip().splitlines()[-1])
    now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    digest = build(now, several="--several" in args,
                   with_antigravity="--with-antigravity" in args, scanning="--scanning" in args,
                   old_codex="--old-codex" in args, focus_codex="--focus-codex" in args)
    Path(paths[0]).write_text(json.dumps(digest, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
