<!-- What shipped, in prose. This becomes the annotation of the next
     release tag, which publish.sh ships as the GitHub release notes.
     The FIRST LINE is the tag's subject: make it a short title, then a
     blank line. This comment is stripped. -->
the model curves stay inside the window they belong to

New
- `usage-cli headroom --cap <percent>` answers what a script, or another
  coding agent deciding whether to hand a harness work, asks before
  spending: is there room under the cap you chose, and can the number be
  trusted? The exit code is the answer (0 room, 24 at or over the cap, 25
  on course to run out under `--forecast red|yellow`, 26 nothing to judge,
  21 too old), and `--json` prints the same object for every verdict, so a
  refusal can be logged. With no meter named it judges every limit and
  reports the one that decides; a limit nobody reports a number for is
  never read as room.
- `--max-data-age <duration>` on `status`, `limits`, `limit`, `spend`,
  `prompt`, `get` and `headroom` refuses (exit 21) numbers MEASURED longer
  ago than that. `--max-age` only ever judged when the digest was last
  written, and a Codex digest is rewritten every few minutes around a
  snapshot that can be hours old — so it passed on exactly the numbers it
  exists to refuse.
- The terminal dashboard (`usage-tui`) switches accounts the way the menu
  bar does: `a` pins focus on the next account, `A` hands it back to the
  one you're using, and a click on another harness's mark in the header
  pins that harness's account. It is the same pin as the panel's account
  strip, so the menu bar follows, and the header says `pinned` while it
  holds. The pane calls a switch done only once the engine shows it, says
  so when one didn't land, and waits rather than gives up on an engine
  that is merely slow. A chart open when the account changes — from here,
  the menu bar or activity — goes back to the dashboard instead of showing
  the new account's meter in the old one's place.

Fixes
- Meter popover: a model's token curve no longer towers over the percent
  line for the first hours after a session window resets. The poll that
  lands on the window boundary still reports the previous window's
  percentage, and counting it as the new window's opening height priced
  every token several times too high — on the reporting Mac a 5h window
  sitting at 13% drew its busiest model near 100%. A window's samples are
  now picked by the reset they were stamped with, so the window before it
  can't lend it a height it never spent, and the same stale drop no longer
  reads as a mid-window reset that lifts the curves' ceiling.
- The "extra usage" estimate on a forecast past its limit is measured on
  the same samples, so the tokens and dollars it quotes match the curves
  the popover draws.
- `usage-cli session <id>` no longer parses every transcript on the Mac
  when the session isn't among the eight the menu bar lists. It asks the
  running engine, which knows every session, and answers in milliseconds,
  `--no-scan` included. With many Claude Code sessions open, each status
  line past the eighth used to start a whole-corpus scan every ten
  seconds — 28 open sessions kept a 12-core Mac at full load. While the
  app or the daemon is running, a session it doesn't know is now simply
  not found; a full scan runs only for `--all` with no engine to ask, or
  with no digest at all, and a second scan of the same account exits 27
  instead of piling on.
- The engine no longer dies when something asking it a question gives up
  before the answer: replying to a caller that had already left raised a
  signal that killed the daemon, or the menu bar app when it was hosting.
- A transcript write that lands within a minute of the engine's last scan
  is picked up by a catch-up scan instead of waiting for the next write
  anywhere, so a session's numbers no longer lag its last turn.
- Panel: a two-finger swipe across the account strip reaches another
  harness's account. It named the account it landed on by its storage
  folder, and every harness's standard home is called `default`, so a swipe
  from Claude Code toward Codex landed back on Claude Code.
