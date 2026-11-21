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

Features
- Antigravity CLI is metered. It sits in the menu bar beside the other
  agents, under a violet ∩: its tokens, models, activity and cost come from
  its own local transcripts. Its plan limits — the Gemini session and
  weekly limits, the Claude + GPT pool, and Gemini 4 Argon's own weekly —
  appear with nothing to set up: while you use Antigravity, the app asks
  the CLI itself (`agy -p /quota`, its read-only limits report) at most
  every ten minutes; it spends no quota, and the CLI uses its own sign-in.
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
