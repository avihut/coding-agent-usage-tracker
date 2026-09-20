Meter every harness at once

The app metered ONE agent: it scored which harness had run recently, read
that one, and offered a picker to override the guess. It now meters every
harness it finds on this Mac — Claude Code, Codex and Gemini CLI together —
the way it already metered several Claude accounts together. They sit
alongside each other in the menu bar under their own marks in their own
colours, one of them holds focus, and the panel, the charts and the CLI
answer for whichever that is. There is no active harness and no switch.

**Hiding is display only.** A harness you aren't interested in leaves the
bar and the panel (Settings → General → Harnesses) and keeps being polled,
forecast and priced; its models stay in the API Cost rates list, which lists
every detected harness whether shown or not. The last shown harness can't be
hidden.

**No new network destination** — and one request fewer per day. Each harness
reads exactly what it always read: Claude its usage endpoint and its own
homes, Codex and Gemini their local session files and no credentials at all.
The LiteLLM rate feed is a single mixed-vendor document every harness slices
differently, so its bytes are now fetched once and shared rather than once
per harness. The privacy card lists every metered harness's hosts and files,
one block each. Spec §10 amendment 2026-09-20.

**Forecasts stay per harness and per account folder**, and a login change
inside a folder keeps that folder's learned history.

**A one-harness Mac is unchanged, byte for byte**: all 48 pinned status-item
snapshots and the hit-rect sidecar are identical to v0.100.1, every digest
key added is additive, and every account id such a Mac had it still has.

Also in this release:

- The panel's strip is one unified list across harnesses — a heading
  carrying the vendor's mark once for a harness with several accounts, and
  the mark itself on a lone account's row.
- Settings → General has a Harnesses card in place of the Metering picker,
  and the Accounts pane lists one card per harness that has accounts.
- API Cost groups rates per harness, folding away the models you've never
  run, and its what-if model picker is now a fuzzy search across every
  harness's priced models.
- `usage-cli harnesses` lists every detected harness; `notices` and
  `health --check` answer about this Mac rather than the focused harness.
- A limit is named by its own window, not by the slot a vendor reports it
  in: Codex's single 7-day limit reads "Weekly" and `W`, never "Session
  (168h)" — and the menu bar, the CLI prompt line and the terminal status
  line draw only the limits an account actually has.
- A renamed limit keeps its history and forecast, a forecast waits for a
  rhythm it has actually watched rather than one spanning a gap, and each
  harness's mark is drawn at the same visual size.
- The terminal dashboard reads every harness: `--status` draws a block per
  harness and the header carries the others' digits.
- Settings → Accounts lists every metered harness's accounts, not only
  the agent that can hold several; a one-folder agent has its one account
  there like any other.
- The app is named "Agent Usage" in its windows, panel and menus — it has
  metered every coding agent for a while, not one vendor's.
- Fixed: a limit chart's red "runs out" time stamp could overprint a
  weekday label while a clear one was blanked, and the last weekday label
  could truncate at the plot's edge.
