# Notices and service status

One generic notice system; a provider outage is a KIND of notice, not a
special case. Service status is the feed that produces the loudest of
them.

**Read this before** adding a notice kind, changing what the menu bar
indicator means, or touching the status poller's cadence.

## Service status (v0.86.0)

- The engine polls the active provider's public status page and publishes a
  normalized `LiveState.serviceStatus` card; every face renders that card and
  polls nothing. `UsageCore/Status/` holds the three pieces: `StatuspageFeed`
  (one endpoint, `/api/v2/summary.json`, conditional GET), `StatusCadence`
  (pure state machine), `StatusPoller` (timer, ETag, resolved-memory).
- Cadence, measured not guessed — CloudFront serves the feed with
  `max-age=10`, so nothing below that can return new bytes: **300s healthy /
  60s while an incident is open / 120s for ten minutes after it resolves /
  60→900s doubling when the feed itself fails**, ±10% jitter. Out-of-band
  pokes (wake, panel open on a card older than 90s, `refreshStatus` over the
  control socket) all pass through the same 10s floor.
- **Absent is not healthy.** A nil card means "nothing tracks status here",
  and every surface must render nothing rather than a green dot. Likewise a
  fetch failure never becomes an incident: three consecutive misses reach the
  grey `unknown` indicator, which is quiet, and `health ok` goes ABSENT
  rather than true.
- Loudness (decision D2): any unresolved incident — minor included — badges
  the menu bar glyph and shows the banners. Maintenance stays quiet: blue
  footer dot and a popover row, never a badge.
- Surfaces: footer dot + hover-pinned popover (`ServiceStatusViews.swift`),
  the provider glyph on an incident-colored capsule
  (`StatusItemRenderer.glyphBadge`), a panel banner above the meters, the
  same banner atop the menu-bar hover popover, and the TUI's four-rung
  ladder (`ui.rs status_rungs`: footer cell → footer text → banner row →
  banner + message; `layout.rs plan_with_status` yields the banner rather
  than the meters).
- WIDTH (v0.99.2, user-reported: a 400-character incident update stretched
  the hover card across the screen): a popover sized by its content
  (`.preferredContentSize`, SwiftUI `.popover`) takes each Text's IDEAL
  width — its whole string on one line; `lineLimit` caps lines, not that.
  The banner sets no width of its own, each host bounds it (panel column;
  hover card: `MeterHistoryView.chartWidth`). Inside `MeterHistoryView`
  every variable one-line text (stats line, readout, account label) is
  pinned to `chartWidth` — only the breakdown grid may widen the card, its
  names never truncate (Sonnet 4.5's row is 307pt), so never pin the card
  itself. `--snapshot` writes `hover.png` at natural size while an incident
  is open (live, or `--fake-status major`): its width must be the card's.
- `usage-cli health` is the scriptable face — `--check` exits **22** while
  something is open. Named `health` because `status` already answers about
  the engine.
- Verify the UI with `--fake-status <none|minor|major|critical|maintenance|
  unknown|resolved>`: a real outage can't be scheduled, and the hatch carries
  the real 2026-08-18 incident's copy.


## Notifications (v0.93.0)

- ONE generic notice system; outages are a KIND of notice, not a special
  case (user-directed 2026-09-05). Core lives in UsageCore/Notices/:
  `Notice` (the ledger's value in FACTS — kind stored as a String for
  forward-compat, `ongoing`/`seenAt`/`dismissedAt`/`seenWhileOngoing`),
  `NoticeLedger` (`notices.json` beside history.json, single writer =
  the engine, dismissed rows aged out after 30d, cap 200),
  `NoticeDetector` (pure: `grants` reads vendor mid-window resets off
  EVERY meter's samples via the VendorGrants rule and voices ONE notice per
  instant by the meter that stood highest; `apply(card:)` runs the outage
  lifecycle off the status card — open incidents become ongoing notices,
  leaving the open list closes them, an `unknown` indicator closes NOTHING
  because losing the feed is not the incident ending; `backfill(history:)`
  records incidents resolved since a cutoff that the ledger never saw).
  IDs: `reset|<minute epoch>` (two hosts name the same event),
  `outage|<incident id>`.
- Two lifecycles. ONGOING = bound to a live condition, persistent, NOT
  dismissable (the engine refuses over the socket: ok=false "not
  dismissable"). Closing an ongoing notice makes it its own EPILOGUE in
  place: `ongoing=false`, `endedAt` set, `seenWhileOngoing` remembers
  whether any face rendered it, `seenAt` reset so the epilogue is fresh
  news. SEEN ≠ DISMISSED: seen = a face rendered it while pending (panel
  open, hover popover shown, TUI drawn); dismissed = the person's ×. The
  indicator keys off dismissal; epilogue COPY keys off seen ("Outage ended
  · lasted 2 hr" vs "Outage overnight"/"Outage while away" with the whole
  span — overnight = any part inside 22:00–08:00 local).
- ALL COPY IS DECIDED ONCE in `NoticePhrasing` (Digests/NoticeCard.swift)
  and rides the digest as `LiveState.notices: NoticesCard?` (additive;
  nil = pre-0.93 writer, empty items = nothing pending, nil ≠ empty).
  `NoticeCard` carries title/detail/when pre-phrased, `dismissable`,
  `seen`, `ownsMenuBarSurface`, `meterLabel`. Faces print verbatim; the
  ONE exception is the ongoing row's running clock ("Ongoing · N min"),
  which ticks locally like the incident banner's. Pinned by
  NoticePhrasingTests (Jerusalem-offset fixture) and the golden.
- MENU BAR RULE (`NoticesCard.indicator`, decided by the WRITER so app and
  TUI can't disagree): a pending notice with no surface of its own lights
  a white 6pt dot at the glyph's top-right (`StatusItemRenderer` `.indicator`
  run — zero width, knocked out of the glyph/capsule by a clear ring, no
  count: the panel counts). An ACTIVE OUTAGE already owns the glyph capsule
  (`ownsMenuBarSurface`), so alone it lights nothing; outage + anything else
  pending shows both. The TUI header carries the same dot after the glyph,
  the strip and `--status` line spend one cell on it (`●N`).
- PANEL: `NoticesSection`/`NoticeRow` (Panel/NoticeViews.swift) above the
  meters, absent when nothing is pending; rail color by kind (`NoticeStyle
  .tint`: reset = provider accent, ongoing outage = its severity, ended =
  grey); × on hover for dismissable rows, "Dismiss all" only once ≥2 can
  go; dismissal ANIMATES (row transition + `.animation(value: ids)` keyed
  on the row set so a client-mode dismissal landing with the next digest
  animates too). THE × IS HOVER-GATED THROUGH `HoverProbe`
  (Components/, an NSTrackingArea `.activeAlways` + `.mouseMoved` probe
  with hitTest nil), NOT `.onHover` (v0.93.4, user-reported): a click on
  the row presents the meter popover, after which SwiftUI's hover never
  re-enters that row until the panel reopens. Any hover-gated control on a
  row whose click presents a popover needs the same probe. The ongoing
  outage's row IS the incident banner with a
  lifecycle — the banner yields to it (`incidentShownAsNotice`) so the
  panel never says the same thing twice. Opening the panel marks every
  pending notice seen; the hover popover marks only what it shows (the
  banner's outage).
- CLICK-THROUGH IS THE PROVIDER'S CALL (user-directed 2026-09-05):
  `UsageProvider.noticeDestination(for:)` → `NoticeDestination.web(URL)`
  (an official record — the incident's Statuspage shortlink, else the
  status page) or `.meterHistory(meterLabel:at:)` (no official record
  exists: the meter card, opened LIT at the moment). Default policy in
  Notices/NoticeDestination.swift; `ClaudeProvider` implements it
  explicitly and documents that Anthropic publishes NO feed of limit
  resets (the 2026-09-04 reset never appeared on the status page) — should
  one appear, point `.reset` at it THERE and nowhere else. The panel
  resolves the meter by label, falling back to rank 1; `MeterHistoryView
  (highlightReset:)` pins the moment: if the remembered span/frame already
  contains it nothing moves, else a TRANSIENT `spanOverride`/`frameOverride`
  turns to History at the tightest frame reaching it (the person's saved
  choices untouched); `WindowPlot.midWindowResets(highlighted:)` draws a
  soft accent halo behind the rule (and the rule itself if the samples
  never measured a cliff there — the notice said it happened), the readout
  spells "Limit reset · ~Fri 23:06 · from 30%"; the pointer taking the
  chart ends the pin.
- STORE/CLIENT: `UsageStore.notices` (+ `markNoticesSeen`/`dismissNotice`
  /`dismissAllNotices`) forwards to the engine when hosting and over the
  socket when a client (`ControlCommand.markNoticesSeen(ids:)`,
  `.dismissNotice(id:)`, `.dismissAllNotices`; DigestClient mirrors the
  card and never edits it optimistically — the next heartbeat carries the
  result). Wake-time BACKFILL: `StatusPoller.pollHistoryNow()` reads the
  status host's `incidents.json` at start and wake only (600s floor), same
  host, spec §10 extended — not a new destination.
- TUI: `NoticesCard` mirrored in tui/src/digest.rs (must decode the
  golden); `layout::plan_with_status(area, status_rows, notice_rows, …)`
  seats the section between banner and meters and yields it BEFORE the
  banner when the meters would pay; rows list only notices that don't own
  a surface (the ongoing outage stays the banner's); hits `Hit::Notice(id)`
  (focus target) + `Hit::NoticeDismiss(id)` on the × cell; keys `n` (cursor
  to the section), `x` (dismiss focused), `X` (dismiss all); drawn notices
  are marked seen once per run over the socket.
- CLI: `usage-cli notices` (table kind/when/title/state/id; `--raw` swaps
  the phrase for the ISO instant; fields `count`/`indicator`/`items`;
  `--json` the card; `--check` exits 23 while anything is pending; absent
  card = silence + 0) and `usage-cli notices dismiss <id>|--all` — the one
  query verb that writes, through the engine's socket (20 when refused, 13
  with no engine). Registered in `nouns`, `fieldCatalog`, the fields-walk's
  `nounPrefix`.
- OUTAGE FLOOR (v0.94.0, user-directed): every provider incident within
  the sample retention draws as a nub on a SECOND floor under the session
  strip in BOTH limit-window charts (`WindowPlot.outageNubs`/`outageColor`/
  `outageCurtain`/`outageReadout` — the one vocabulary; MeterHistoryView
  band −14…−9 and the chart grows 7pt while the frame holds one, so the
  plot is never squeezed; AuditWindowChart rule at −14 with floor −18 —
  its height is the caller's, tied to the ring/bars, so there the plot
  compresses). Two floors because the severity colors (yellow/orange/red)
  would be read as session/exhausted nubs on the session floor, and because
  "was I working while it was down" is a vertical read. The floor is ABSENT
  when nothing overlaps the frame; an ongoing incident is held open to now;
  maintenance never appears. Severity color ongoing or ended (the chart's
  job is history — greying is the notice row's idiom, not the chart's).
  Hover: curtains + duration in the headroom band + "Outage · major · 01:10
  – 03:20 · 2 hr 10 min · Claude Code" readout (TRUE bounds, not the
  clipped nub's); the grid does not re-tally (not the person's spend);
  click → `UsageProvider.outageDestination(url:)`, the SAME rule the notice
  row's `.outage` arm uses (pointer .link). DATA: `LiveState.outages:
  [OutageSpan]?` (additive; nil = writer records none, [] = none in 56d),
  derived by the engine from the notice ledger's WHOLE record
  (`OutageTimeline.spans`, dismissed rows included) — so `NoticeLedger`
  keeps outage rows for `keepOutagesFor` (56d, = sample/timeline retention)
  instead of the dismissed-row month, and the wake-time backfill takes
  `factsSince` (56d): incidents resolved inside the 48h news window become
  pending epilogues, older ones land ALREADY DISMISSED so a fresh ledger
  never floods the panel while the floor still gets its history.
  `AuditWindowModel.outages` carries the overlapping spans unclipped.
  Client mode mirrors the digest field; `store.outages` is the one app
  seam; `--fake-notices` installs the same incidents as spans (plus a
  minor one three days back for a past page). TUI mirrors the field
  (`digest.rs OutageSpan`, golden-decoded) but does not draw the floor yet.
  Deferred, user-agreed: per-incident relevance dimming (components vs the
  models this Mac ran) as a ClaudeProvider-level rule.
- VERIFY: `--fake-notices <morning|live>` installs a synthetic card
  (dismissals edit it in place); `--snapshot <dir>` renders the
  Notifications section, the weekly meter card (lit at the first reset
  notice) and a trailing 5-day audit chart of the weekly meter headlessly
  to PNG and quits. KNOWN: `meter.png` comes out as a yellow ⊘ placeholder
  over the picker and the plot — ImageRenderer's stand-in for the
  AppKit-backed pieces the card hosts (confirmed pre-existing 2026-09-06 by
  rendering with the outage floor stripped); `audit.png` is the chart
  surface that actually verifies (it carries the outage floor too) — the harness's eyes when the live
  popover can't be caught (the outside-click monitor closes the panel on
  ANY real click, and a user at the machine is always clicking; ImageRenderer
  leaves a ScrollView's content blank, so the panel can't be snapshotted
  whole). The daemon's real ledger detected the 2026-09-04 reset and
  backfilled the Sep 3 outage on first run.
