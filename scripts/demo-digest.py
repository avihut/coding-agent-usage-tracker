#!/usr/bin/env python3
"""Write a synthetic live-state.json for screenshots and recordings.

The README's media must never show anybody's real usage, so the faces are
recorded against this instead: `usage-tui --digest` and `usage-cli --digest`
both read a digest from a path and compute nothing of their own.

The contract golden (Tests/.../digest/live-state-v1.json) is the template —
it is what both decoders are pinned to, so a digest built on it decodes on
both sides of the language boundary. The golden is deliberately sparse (it
exercises absent fields), which makes a poor demo; this fills it with a
plausible fortnight. Everything is seeded, so two runs differ only by the
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
GOLDEN = ROOT / "Tests/UsageCoreTests/Fixtures/digest/live-state-v1.json"
IDENTITY = ROOT / "Sources/UsageCore/AppIdentity.swift"

MODELS = [
    # id, display name, colour, share of tokens, $ per million tokens (blended)
    ("claude-fable-5", "Fable 5", {"red": 0.851, "green": 0.467, "blue": 0.341}, 0.62, 1.6),
    ("claude-sonnet-5", "Sonnet 5", {"red": 0.353, "green": 0.557, "blue": 0.918}, 0.30, 0.5),
    ("claude-haiku-4-5", "Haiku 4.5", {"red": 0.478, "green": 0.757, "blue": 0.553}, 0.08, 0.15),
]
CALM = {"red": 0.204, "green": 0.780, "blue": 0.349}
WATCH = {"red": 1.0, "green": 0.800, "blue": 0.0}
SESSIONS = [
    ("Add retry with backoff to the sync client", "sync-client", "fix/retry-backoff"),
    ("Why is the importer quadratic?", "importer", "main"),
    ("Migrate settings to the new form API", "webapp", "feat/settings-form"),
    ("Write property tests for the interval tree", "geometry", "test/interval-tree"),
    ("Review: pagination cursor off-by-one", "api", "fix/cursor"),
    ("Draft the 2.0 migration guide", "docs", "docs/migration-2.0"),
]


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


def model_rows(tokens):
    return [
        {
            "id": model, "displayName": name, "color": color,
            "cost": round(tokens * share * rate / 1e6, 2),
            "tally": tally(tokens * share),
        }
        for model, name, color, share, rate in MODELS
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


def meter(template, now, rng, *, ident, label, tag, rank, window, elapsed, percent,
          projected, verdict, severity, risk, level, step_minutes, models):
    start, reset = now - elapsed, now - elapsed + window
    series = climb(start, now, percent, rng, step_minutes)
    left = reset - now
    hours = left.total_seconds() / 3600
    caption = f"resets in {int(hours // 24)}d {int(hours % 24)}h" if hours >= 24 \
        else f"resets in {int(hours)}h {int(hours * 60 % 60)}m"
    rate = percent / (elapsed.total_seconds() / 3600)
    built = copy.deepcopy(template)
    built.update({
        "id": ident, "label": label, "tag": tag, "rank": rank, "level": level,
        "percent": percent, "limitWindow": int(window.total_seconds()),
        "resetsAt": stamp(reset), "resetCaption": caption, "risk": risk,
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
    })
    return built


def segment(built, severity):
    return {"tag": built["tag"], "percent": built["percent"], "level": built["level"],
            "resetsAt": built["resetsAt"], "risk": built["risk"], "severity": severity}


def activity(now, rng, days=84):
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
        tokens = int(rng.lognormvariate(math.log(28e6), 0.55) * (0.3 if weekend else 1.0))
        if back == 0:
            tokens = int(tokens * (now.hour + 1) / 24)
        rows = model_rows(tokens)
        key = day.isoformat()
        rollups.append({"dayKey": key, "tokens": tokens, "prompts": max(3, tokens // 450_000),
                        "cost": round(sum(row["cost"] for row in rows), 2)})
        by_model.append({"dayKey": key, "models": rows})
        last = now.hour if back == 0 else 22
        weights = {hour: rng.random() * (2.0 if 9 <= hour <= 18 else 0.4)
                   for hour in range(8, last + 1) if rng.random() < 0.75} or {now.hour: 1.0}
        scale = tokens / sum(weights.values())
        by_hour.append({"dayKey": key, "hours": [
            {"hour": hour, "tokens": int(weight * scale),
             "cost": round(weight * scale * 1.15 / 1e6, 2)}
            for hour, weight in sorted(weights.items())]})
    return rollups, by_model, by_hour


def sessions(now, rng):
    out, cursor = [], now - timedelta(minutes=4)
    for index, (title, project, branch) in enumerate(SESSIONS):
        length = timedelta(minutes=rng.randint(25, 140))
        tokens = rng.randint(3, 40) * 1_000_000
        out.append({
            "id": f"demo-session-{index}", "title": title, "project": project, "branch": branch,
            "startedAt": stamp(cursor - length), "end": stamp(cursor),
            "activeSeconds": int(length.total_seconds() * 0.8),
            "apiCalls": tokens // 90_000, "prompts": rng.randint(4, 30), "tokens": tokens,
            "cost": round(tokens * 1.15 / 1e6, 2), "accounts": [],
            "modelColors": [color for _, _, color, _, _ in MODELS[: 1 + index % 3]],
        })
        cursor -= length + timedelta(minutes=rng.randint(20, 600))
    return out


def build(now):
    rng = random.Random(5)
    state = json.loads(GOLDEN.read_text())
    template = state["meters"][0]
    hours, days = lambda n: timedelta(hours=n), lambda n: timedelta(days=n)
    meters = [
        meter(template, now, rng, ident="session", label="Session (5h)", tag="S", rank=0,
              window=hours(5), elapsed=timedelta(hours=2, minutes=10), percent=34,
              projected=71, verdict="green", severity=0.15, risk=CALM, level="normal",
              step_minutes=5, models=MODELS),
        meter(template, now, rng, ident="weekly_all", label="Weekly (all)", tag="W", rank=1,
              window=days(7), elapsed=timedelta(days=4, hours=6), percent=59,
              projected=93, verdict="yellow", severity=0.55, risk=WATCH, level="normal",
              step_minutes=120, models=MODELS),
        meter(template, now, rng, ident="weekly_fable", label="Weekly (Fable)", tag="F", rank=2,
              window=days(7), elapsed=timedelta(days=4, hours=6), percent=22,
              projected=38, verdict="green", severity=0.1, risk=CALM, level="normal",
              step_minutes=120, models=MODELS[:1]),
    ]
    rollups, by_model, by_hour = activity(now, rng)
    since = (now.date() - timedelta(days=6)).isoformat()
    week = sum(day["tokens"] for day in rollups if day["dayKey"] >= since)
    today = rollups[-1] if rollups[-1]["dayKey"] == now.date().isoformat() else None
    state["meters"] = meters
    state["menuBar"] = [segment(m, m["forecast"]["severity"]) for m in meters]
    state["models"] = model_rows(week)
    state["sessions"] = sessions(now, rng)
    state["activity"].update({
        "days": rollups, "modelDays": by_model, "hourDays": by_hour,
        "todayHours": by_hour[-1]["hours"] if today else [],
        "todayTokens": today["tokens"] if today else 0,
        "todayCost": today["cost"] if today else 0,
        "todayPrompts": today["prompts"] if today else 0,
    })
    state["engine"].update({
        "appVersion": re.search(r'version = "([^"]+)"', IDENTITY.read_text()).group(1),
        "fetchedAt": stamp(now - timedelta(minutes=2)), "generatedAt": stamp(now),
        "nextPollAt": stamp(now + timedelta(minutes=3)), "stale": False,
        "apiBudgetUsed": 4, "apiBudgetFraction": 0.2,
        "planLabel": "Max plan · 5x", "planRateLimitTier": "default_claude_max_5x",
        "forecastProfile": {"caption": "", "isReady": True,
                            "historySpanSeconds": 84 * 86400, "remainingSeconds": 0},
    })
    # A demo has no outage, no pending notice and no update to advertise.
    status = state["serviceStatus"]
    status.update({"indicator": "none", "descriptionText": "All Systems Operational",
                   "incidents": [], "maintenances": [], "recentlyResolved": [],
                   "checkedAt": stamp(now), "okAt": stamp(now)})
    for component in status["components"]:
        component["status"] = "operational"
    state["notices"] = {"indicator": False, "items": [], "pendingCount": 0}
    state["outages"] = []
    state.pop("appUpdate", None)

    # One account, mirroring the top level — the golden's two-account
    # presence ledger is contract coverage, not something a demo needs.
    profile = state["profiles"][0]
    profile.update({key: copy.deepcopy(state[key])
                    for key in ("activity", "engine", "menuBar", "meters", "models", "sessions")})
    profile.update({"label": "dev@example.com", "monogram": "D", "isFocused": True,
                    "lastActivityAt": stamp(now - timedelta(minutes=4))})
    profile.pop("accountPresence", None)
    state.pop("accountPresence", None)
    state["profiles"] = [profile]
    state["focusedProfile"] = profile["id"]
    for cell in state["menuBarCells"][:1]:
        cell.update({"segments": state["menuBar"], "monogram": "D", "stale": False,
                     "indicator": False, "worstSeverity": 0.55})
    state["menuBarCells"] = state["menuBarCells"][:1]
    for harness in state["harnesses"]:
        harness.update({"accountCount": 1, "serviceStatus": copy.deepcopy(status),
                        "notices": copy.deepcopy(state["notices"]), "outages": [],
                        "newestActivityAt": stamp(now - timedelta(minutes=4))})
    return state


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[-1])
    now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    Path(sys.argv[1]).write_text(json.dumps(build(now), indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
