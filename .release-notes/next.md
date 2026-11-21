<!-- What shipped, in prose. This becomes the annotation of the next
     release tag, which publish.sh ships as the GitHub release notes.
     The FIRST LINE is the tag's subject: make it a short title, then a
     blank line. This comment is stripped. -->
Claude's plans by their new names

Fixes
- The panel names Claude plans the way Anthropic now does: Ultra (the former
  Max 20x) and Max (the former Max 5x), in place of "Max plan · 20x". The
  name comes from what Claude Code records for your plan, so a future rename
  shows up without an update. Codex's ChatGPT plans read by name too ("Pro
  Lite", not "Prolite").
- Codex: the heatmap, totals, cost and sessions list no longer lose every
  session older than about a week. Codex compresses a session's file once
  it has gone a week unused, and this app couldn't read the compressed
  form, so each day another day of history disappeared — on the reporting
  Mac, more than half of all sessions. Compressed sessions now read exactly
  like the rest, through the app's own decoder (macOS ships none, and the
  app takes no third-party code); a session Codex is in the middle of
  compressing counts once, and nothing is ever written inside `~/.codex`.
  The first scan after updating reads the backlog once, and scanning Codex
  now takes a fraction of the memory it did (490 MB → 110 MB at peak on
  the reporting Mac).
- A harness you haven't used in a month leaves the menu bar again even if
  you changed its menu-bar style recently. The style change was being read
  as a fresh sign-up, which kept, for one, a deprecated Gemini CLI unused
  for half a year in the bar for another 30 days. It returns the moment
  it's used again.
- A demo run (`--demo-digest`) no longer writes model colours into the
  installed app's settings.
- A cost with nothing priced behind it reads "—" instead of "$0" in the
  Activity section's stats line, day ring and day tooltip.
- The terminal dashboard shows a harness that has no limits to show yet
  (Antigravity before its limits arrive) beside the focused account's, as
  its mark and a dash, the way the menu bar does. It used to leave it out.
- The panel keeps its margins with every agent's models in the Activity
  table. A long model name ("Codex Auto Review") pushed the content wider
  than the panel and squeezed every section's side margin to almost
  nothing; long names now shorten with "…" (the full name on hover). The
  table also lines up with the rest of the panel, each model sits under its
  agent's name, and the Sessions list's edges match the sections above it.
- Model colours stay readable on both the dark and the light panel: no
  colour sinks into the background as a near-black (Opus 5.5's brown read
  as disabled) or fades out as a near-white, and consecutive versions of a
  model stay distinct. Each colour now meets a 3:1 contrast against the
  panel in each appearance, keeping its agent's hue.
- Building the app (`mise run app` / `mise run bundle`) no longer fails now
  and then with "Write permissions error" while Claude Code status lines are
  running `usage-cli` from the bundle: the bundle is built and signed aside
  and swapped into place whole.
- The terminal dashboard pointed at a saved digest (`usage-tui --digest
  <file>`) no longer talks to the running engine: it sends no command and
  marks no notice seen unless `--socket` names one, and it never sets the
  engine up either way. A demo could otherwise refresh, re-pace or
  re-focus the real engine.
- In the panel's all-agents chart, each agent's models take their colours
  from that agent's own model families, as its engine names them. Codex's
  "Other" and any model no catalog claims were filed under Claude's
  families, so they could wear a tone of their own there.

Features
- Antigravity CLI is metered. It sits in the menu bar beside the other
  agents, under a violet ∩: its tokens, models, activity and cost come from
  its own local transcripts. Its plan limits — the Gemini session and
  weekly limits, the Claude + GPT pool, and Gemini 4 Argon's own weekly —
  appear with nothing to set up: while you use Antigravity, the app asks
  the CLI itself (`agy -p /quota`, its own limits report — no agent turn)
  at most every ten minutes; it spends no quota, and the CLI uses its own
  sign-in.
  Without the CLI installed it shows tokens without limits, and an agent
  with no limits to show no longer takes the bar's lead unless you pin it.
- Gemini CLI, which Antigravity succeeds for Google's plans, is labelled
  deprecated and stays metered for API-key use.
- The panel's Activity section counts every agent's consumption together:
  one token and list-price cost total for, say, Claude Code and Codex, broken
  down agent by agent, account by account, model by model. Limits stay one
  meter per account; they never add up. A menu beside "Activity" narrows it
  to one agent or one account, and narrowed to one account the section
  reads as it always did. With a single account there is no menu. The
  Sessions strip follows the same choice, and clicking a merged row opens
  that account's sessions.
- The terminal dashboard and `usage-cli` read every agent's consumption
  together too, as the panel does. In the dashboard, TODAY, the model table
  and the Activity chart total all agents by default: the table becomes
  agent ▸ model, the bars stack in each agent's colours, and `u` switches to
  the focused account and back. The header still shows the focused
  account's limits, which never add up. `usage-cli activity`, `cost`,
  `models` and `model` take `--all-agents` for the same total. An agent
  whose history is still being read is named and left out ("partial"),
  never counted as zero; while every agent is still being read there is
  no total yet, rather than a total of zero.
