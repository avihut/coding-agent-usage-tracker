<!-- What shipped, in prose. This becomes the annotation of the next
     release tag, which publish.sh ships as the GitHub release notes.
     The FIRST LINE is the tag's subject: make it a short title, then a
     blank line. This comment is stripped. -->

Antigravity CLI is metered; Gemini CLI is deprecated

Antigravity CLI now sits in the menu bar beside the other agents, under a
violet ∩: its tokens, models, activity and cost come from its own local
transcripts, with nothing to set up and no network or sign-in involved. Its
plan limits (Gemini session and weekly, and the Claude + GPT pool) appear
once you make `usage-cli export-statusline antigravity` its status line —
`usage-cli export-statusline antigravity --print-config` prints the entry
to paste into Antigravity's settings. Until then it shows tokens without
limits, and an agent with no limits to show no longer takes the bar's lead
unless you pin it. Gemini CLI, which Antigravity succeeds for Google's plans,
is labelled deprecated and stays metered for API-key use.
