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

usage: demo-digest.py <out.json>
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
CODEX_MODELS = [
    ("gpt-5.2-codex", "GPT 5.2 Codex", rgb(0.063, 0.639, 0.498), 1.0, 0.45),
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


def build(now):
    rng = random.Random(5)
    state = json.loads(GOLDEN.read_text())
    sections = {section["id"]: section for section in state["profiles"]}
    hours, days = lambda n: timedelta(hours=n), lambda n: timedelta(days=n)
    week_in = timedelta(days=4, hours=6)
    claude = face(
        now, rng, sections["default"], models=CLAUDE_MODELS, titles=CLAUDE_SESSIONS,
        typical=28e6, engine={"apiBudgetUsed": 4, "apiBudgetFraction": 0.2,
                              "planLabel": "Max plan · 5x",
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
    state["menuBarCells"] = []
    for section in (claude, codex):
        cell = cells[section["id"]]
        cell.update({"segments": section["menuBar"], "monogram": section["monogram"],
                     "stale": False, "indicator": False,
                     "worstSeverity": max(s["severity"] for s in section["menuBar"])})
        state["menuBarCells"].append(cell)
    state["harnesses"] = [h for h in state["harnesses"] if h["id"] in ("claude", "codex")]
    for harness in state["harnesses"]:
        harness.update({"accountCount": 1, "present": True, "shown": True,
                        "notices": copy.deepcopy(quiet), "outages": [],
                        "newestActivityAt": stamp(now - timedelta(minutes=4))})
        harness.pop("serviceStatus", None)
    return state


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[-1])
    now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    Path(sys.argv[1]).write_text(json.dumps(build(now), indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
