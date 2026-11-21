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

Features
- Antigravity CLI is metered. It sits in the menu bar beside the other
  agents, under a violet ∩: its tokens, models, activity and cost come from
  its own local transcripts, with nothing to set up and no network or
  sign-in involved. Its plan limits (Gemini session and weekly, and the
  Claude + GPT pool) appear once you make `usage-cli export-statusline
  antigravity` its status line — `usage-cli export-statusline antigravity
  --print-config` prints the entry to paste into Antigravity's settings.
  Until then it shows tokens without limits, and an agent with no limits to
  show no longer takes the bar's lead unless you pin it.
- Gemini CLI, which Antigravity succeeds for Google's plans, is labelled
  deprecated and stays metered for API-key use.
