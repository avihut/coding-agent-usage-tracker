# The faces: menu bar, panel, windows

Everything the app draws, and the AppKit/SwiftUI lessons paid for once
already.

**Read this before** changing the status item, the panel, the settings
or sessions windows, or any hover/popover/drag behaviour.

Charts and the activity surfaces are in [CHARTS.md](CHARTS.md); the
per-harness geometry of the bar is in [HARNESSES.md](HARNESSES.md).

## Menu bar rendering

- Menu bar rendering: height from `NSStatusBar.system.thickness` (never
  hardcoded), `monospacedDigitSystemFont` so width doesn't jitter,
  `isTemplate = false`. Since v0.21.0 the title is a DRAWN NSImage
  (`StatusItemRenderer.image`), not attributedTitle: digits stay white —
  thin glyph strokes can't carry color legibly over Liquid Glass (HIG:
  color rides fills, not fine features) — and exhaustion risk arrives as
  solid geometry instead: a ramp-colored dot ahead of a watched number
  (severity 0→0.75), escalating to a filled red capsule carrying the
  segment's tag + digits in bold white at severity ≥ 0.75 (or discrete
  critical). Stale stays grey and ornament-free. THE INK FOLLOWS THE
  GROUND (v0.100.1, user-reported: white digits over a bright wallpaper
  were unreadable): the bar is transparent and the system inks its own
  items from the WALLPAPER — not the app's appearance, not Dark Mode
  (measured: a Dark Mode Mac over a cream wallpaper hands status buttons
  `vibrantLight` and draws the clock black). `StatusItemRenderer.Ground`
  (.dark/.light) is read off the button's `effectiveAppearance`; the
  controller KVOs it, and the ground joins the identical-model skip. Every
  palette static is an `ink(dark:light:)` NSColor resolved at DRAW time —
  composition never learns the ground — and `image(…ground:)` draws under
  `ground.appearance`, so an image resolves the same in any context;
  default `.dark` keeps every preview swatch and snapshot as it was. The
  `.dark` ground IS the 0.2.1 palette (white + faint dark halo, all 24
  status item PNGs `cmp` equal across the change); `.light` is the
  system's near-black, no halo, and every hue a step deeper (the glyph's
  accent 30% toward black; the ramp amber→deep red) — white-on-fill
  capsules are the same on both. Never blend two ink colors
  (`blended` resolves at blend time): `rampColor(_:)` blends WITHIN a
  ground. The 0.2.1 note that the appearance "lies" is retired: whatever
  the button reports is the ink the system gives the clock beside us, and
  matching it is the contract. Hatches: `--fake-bar <light|dark>`;
  `--snapshot` writes every case twice (`statusitem-light-*` on cream).
  UNVERIFIED (one display here): an item holds ONE image, so a second
  display whose wallpaper sits on the other side presumably shows the
  first bar's ink — only a template image could be inked per display, and
  a template can't carry the risk colors.

- The status item is a raw `NSStatusItem` owned by `StatusItemController` —
  NOT `MenuBarExtra`. The menu bar's appearance follows wallpaper tinting,
  not the app's appearance; MenuBarExtra rasterizes its label in the app's
  appearance and produced dark-on-dark text. The item's image is drawn
  for the button's own ground (the rendering bullet above); KVO on
  `button.effectiveAppearance` redraws it when a wallpaper change flips
  the bar's ink. The panel is SwiftUI in an `NSPopover`.
- `.transient` alone cannot dismiss the panel popover: in an LSUIElement app
  under cooperative activation (macOS 14+) the app usually never becomes
  active, so clicking elsewhere produces no deactivation to close on. While
  the panel is shown, a global mouse-down/scroll monitor plus a
  `didResignActiveNotification` observer close it (torn down in
  `popoverDidClose`); global monitors never see in-panel events, so any hit
  means the user went elsewhere. The same inactivity means the panel window
  is never key on its own — and a non-key window consumes the first click
  to focus itself, so SwiftUI tap targets needed two clicks (NSControl
  pickers mask this via `acceptsFirstMouse`). `makeKey()` right after
  `popover.show` fixes it; keep it if the show path ever moves.

## Menu bar form, per account

- MENU BAR PER ACCOUNT (2026-09-07 v0.97.0, user-directed, replacing
  0.96.0's six whole-bar `MenuBarStyle`s): three orthogonal choices. PER
  ACCOUNT, on the `Profile` record (`menuBarForm: MenuBarForm` digits/bars/
  rings/compactDigits/dot, `ownMenuBarItem`; additive CodingKeys, the
  daemon carries and ignores them, the digest's `MenuBarCell` has no
  form): the renderer's `Cell.form`/`Cell.ownItem`. BAR-WIDE, app defaults
  (`MenuBarPreferences.expandsFocusKey`, default true): the FOCUSED cell
  draws as today's unlabeled digits whatever its form — that default is
  what keeps a fresh install's bar and a one-account bar exactly as they
  were; `MenuBarPreferences.migrateLegacyStyle` spells a stored
  `menuBarStyle` into forms once and deletes the key. A cell whose OWN
  form is digits carries its monogram (it is not "the" account); the
  monogram is "" whenever the bar holds one account. `StatusItemRenderer
  .itemModels` splits one model into the shared item (nil id) + one per
  own-item account, provider dressing on the FIRST; the controller draws
  those. `MenuBarModelBuilder` is the ONE answer to "what does the bar
  show" — the status item AND Settings → Accounts' live `MenuBarPreview`
  (an NSView drawing the real renderer's images on a bar-like ground;
  dragging a cell past a neighbor's midpoint re-orders live through a
  draft order and `registry.reorder` lands it on release) both draw it,
  so the preview can't lie. `MenuBarFormPicker` tiles = `StatusItemRenderer
  .cellImage` of the account's LIVE numbers per form (pick by picture);
  tiles are `fixedSize` under their own label row — squeezed beside a
  label the digits swatch clipped, v0.97.1). WHICH FORM WINS IS A SWITCH
  (v0.97.1, user-directed): `MenuBarPreferences.uniformKey` ("Same form
  for every account", default ON) + `uniformFormKey`; `Values.form(for:)`
  is the one resolver, per-account rows show a caption instead of a
  picker while it is on. `MenuBarPreferences.Values` is read once per
  render (status item observer diff, preview, hatch). FOCUS: a strip/cell click PINS
  (`registry.focus` = overlay `manualFocusID` shown at once + `pin`,
  overlay lifted when the host agrees; `MeteringHost.setPin` overrides the
  panel hold — the hold defers ACTIVITY, never a click); the strip header's
  "Auto" (visible only while pinned) hands focus back. SETTINGS: an
  `Accounts` sidebar section (`SettingsSection.accounts`, only for a
  provider with `supportsMultipleHomes`; `--settings --pane-accounts`)
  holding Menu bar (preview, All accounts, Expand the focused account,
  Focus) / Accounts (identity → nickname → form tiles → switches →
  activity; credential + identity paths moved to General → About's
  privacy inventory, per account) / Panel; General is back to what it
  was. `--snapshot` writes `menubar-preview.png` (the NSView's own
  `snapshot()`) and `form-picker.png`. SETTINGS STALL (v0.97.1,
  user-reported "minutes"): `SMAppService.mainApp.status` is an XPC
  round-trip that can hang; `LoginItemState.refresh()` reads it OFF the
  main thread and the Launch-at-login toggle waits disabled until `known`
  — never call it synchronously from a view again.
  STATUS ITEM IDENTITY (v0.97.2, user-reported "nothing in the menu
  bar"): an `NSStatusItem`'s identity is its autosave name, and the
  shared item's is AppKit's auto-generated first name — every launch
  since 0.1 has used it. `StatusItemController.reconcileItems` therefore
  NEVER removes the shared item: it adds/removes own-item entries around
  it. Tearing it down and creating it afresh (0.97.0's rebuild) handed the
  bar a NEW item, which Bartender 6 filed under its new-item policy —
  hidden — and remembered; System Events (`menu bar item of menu bar 2 of
  process "ClaudeUsage"`) still listed the item, at Bartender's hidden x.
  Every created item gets `isVisible = true` (a persisted ⌘-drag removal
  must not keep a re-shown account off the bar). ⌘, (v0.97.2): the SwiftUI
  `Settings { EmptyView() }` scene bound ⌘, to an EMPTY window — it is
  gone (`MenuBarExtra(isInserted: false)` is the inert scene); a LOCAL
  keyDown monitor in AppDelegate opens the real window; an app-menu
  "Settings…" item could not be made to survive SwiftUI's menu rebuilds
  and was dropped. `log show` never surfaced this app's OSLog info lines
  here — diagnose with `sample`, System Events, and `--snapshot`.

## Menu bar elements and "runs out"

- MENU BAR ELEMENTS + "RUNS OUT" (2026-09-07 v0.98.0, user-directed
  "add things to the menu bar by dragging and dropping"): a cell is an
  ORDERED ELEMENT LIST (`MenuBarElement`, Profiles/MenuBarElement.swift —
  `.meters` drawn in the cell's form, exactly once, plus `.runsOut(scope)`
  at most once; `MenuBarLayout.normalized` is the invariant at every
  edge; tokens "meters"/"runsOut:earliest" on the `Profile` record
  (`menuBarElements`, additive, unknown token dropped alone) and bar-wide
  under `MenuBarPreferences.uniformElementsKey`, following the SAME
  "Same form for every account" switch as the form — `Values.elements
  (for:)` resolves). THE ELEMENT IS CONDITIONAL: it composes NOTHING
  unless a limit is forecast to run out before its reset (a red capsule
  `S 31m`, the digits' alarm idiom) or is spent (`S↺ 2h 10m`, quiet,
  counting to the reset); a quiet bar is byte-identical to the pre-0.98
  one (`statusitem-runsout-quiet.png` == `statusitem-clean.png`, and all
  seventeen 0.97.2 status item PNGs `cmp` equal). ONE element with a SCOPE
  (`RunsOutScope` earliest/each/session/weekly/scoped — "when do I get
  cut off" is the earliest crossing; the rest is a setting), never several
  copies. Phrasing is core: `UsageFormatting.menuBarCountdowns` (Formatting/
  MenuBarCountdown.swift — `resetText`'s tiers minus the verb, minutes
  zero-padded after an hour so the monospaced width holds), gated on the
  SMOOTHED verdict: `MenuBarSegment`/digest `SegmentStatus` carry
  `exhaustsAt` (red verdict only — the two-refresh hysteresis is what
  keeps a bar element from flickering) and `resetsAt`, additive, Rust
  mirror updated, golden regenerated (+3 `resetsAt`). The countdown ticks:
  `Model.now` is FLOORED TO THE MINUTE so the model changes once a minute
  and the controller's identical-model skip still holds; `armClock` fires
  one shot at the next boundary while `hasCountdown`. SETTINGS: the
  preview is a DROP TARGET (`MenuBarElementDrag` pasteboard type + plain-
  text token; drop lands before/after the nearest meters by the pointer's
  side of their midpoint) and a placed element drags across its meters or
  OFF the strip to remove (`elementRects` — `Tagged`/`Placed` carry
  `element`; a dot form still carries no letter); `MenuBarElementPalette`
  = the tile (`StatusItemRenderer.elementImage`, the element ALONE at the
  account's numbers with the session half an hour out) + the condition in
  words + scope picker + Remove; "Preview as if a limit were running out"
  (`MenuBarModelBuilder.simulatingCrossing`, never persisted) and GHOSTS
  (`Model.ghosts`, a dashed "runs out" capsule for an element with nothing
  to say — the preview ONLY, the bar never) are the two answers to "the
  drop looked like it failed". `--snapshot` writes `statusitem-runsout-
  {,before,each,spent,quiet,ghost,cells}.png` (clock pinned so they cmp),
  `menubar-preview-{ghost,forecast}.png`, `element-palette.png` (its
  Picker is the ImageRenderer ⊘). Verified live: this Mac's real bar read
  `S 23m` / `F 23h 22m` off the daemon's forecast. TUI mirrors the fields,
  draws nothing new. v0.98.1 (user-reported "nothing happened"): the tile
  is an APPKIT DRAG SOURCE (`ElementDragSourceView`, a real
  `NSDraggingSession` with the token + the source account on the
  pasteboard) — SwiftUI's `.onDrag` on a Button never started a session
  the AppKit drop target could see; and (user-directed) the bar's styling
  has its OWN SIDEBAR PANE, `SettingsSection.menuBar` (Settings/
  MenuBarSettingsPane.swift, every provider, `--pane-menubar`): preview,
  uniform switch, form, palette, focus, plus "Accounts in the bar" rows
  (Show in menu bar / Own item / per-account form + elements while
  uniform is off); Accounts keeps identity, nickname, "Meter this
  account", activity, remove, discovery, and the Panel card. v0.98.2
  (user-reported: Work's drop did nothing, Personal's worked):
  `ProfileStore.resolved` REBUILDS the stored default record field by
  field — a field added to `Profile` MUST be carried there too, or every
  edit to the implicit `default` account is written and then dropped on
  the next read (pinned by MenuBarElementTests.defaultRecordResolves).
  v0.99.0 (user-directed "for the currently selected account rather than
  for each account"): `MenuBarPreferences.focusedElementsOnlyKey` (default
  ON) — `MenuBarModelBuilder.elements(for:…focused:)` strips the runs-out
  element from every non-focused cell, drafts mid-drag included, so the bar carries ONE countdown, the
  focused account's; the arrangement records are untouched (a drop still
  lands where it lands, and draws when that account is focused).



## Dock presence

- `LSUIElement` in `Support/Info.plist` sets the LAUNCH state: no Dock icon,
  no Cmd+Tab. DockPresence (v0.44.0) overrides it at runtime: while any
  hosted window (Sessions, Settings) is open the app is a `.regular` app
  (Dock tile, Cmd+Tab, SwiftUI's default main menu), dropping back to
  `.accessory` when the last closes. One process-wide holder keyed by
  visible-window identity — per-window flips would yank the Dock tile when
  one of two open windows closes. It takes each hosted window's DELEGATE
  seat (free today; if a window ever needs its own delegate, DockPresence
  must move to willClose notifications). Window controllers call
  `DockPresence.shared.adopt(window)` on every show, BEFORE `NSApp
  .activate()` so the menu bar rides along.

## The settings window

- The settings window (⋯ menu → Settings…, `SettingsWindowController` —
  created on first show, kept alive across closes, explicitly fronted
  because cooperative activation won't front a background app's window)
  navigates with a left sidebar (`NavigationSplitView`, toggle removed):
  General, Usage, and API Cost panes. The Usage pane
  (UsageSettingsView.swift) surfaces the forecast engine's working —
  per-meter recent rate, baseline + basis, pace factor, projection,
  hysteresis state — plus the learned weekly-rhythm grid (7×6 heat cells,
  claude-orange intensity) with busiest/quietest-day insights, sample-
  history stats (count, span, thinning, on-disk size), and a plain-words
  explainer; card scaffolding (`SettingsCard`/`SettingsPaneScroll`/
  `infoRow`/`note`) is shared internal from Settings/SettingsScaffolding.swift. The API
  Cost pane — pricing-feed status with a manual
  Refresh Now (`PricingService.refreshNow` — bypasses the daily staleness
  gate, same single allowed destination), the list rates behind the
  estimates, a Claude Code-specific cost explainer, and a what-if
  playground over `CostSimulator` (UsageCore, closed-form: writes =
  C+(n−1)g, reads = (n−1)C+g(n−1)(n−2)/2 — cache reads grow quadratically
  with session length, which is the explainer's core lesson). Panes are
  hand-rolled cards in a ScrollView, NOT `Form(.grouped)`: grouped forms
  column-align bare controls (the refresh slider got squeezed into the
  trailing half-column while its mark labels spanned the row) and
  mis-measure wrapped text in custom rows (the token-class grid overlapped
  its neighbors). The panel's ⋯ menu and the General pane share
  `SettingsBindings` so both surfaces stay in lockstep. `ClaudeUsage
  --settings` opens the window at launch and `--panel` opens the main
  panel — the verification hatches, since menus and the status item can't
  be scripted (`mise run axdump` / `mise run axpress` — the harness's eyes
  and hands — dump frames and press controls for layout checks; both
  default to the newest running ClaudeUsage). Popover windows never
  appear in AXWindows (both tools sweep the app element's roleless
  children to catch them), and any real user click dismisses the panel —
  don't AX-verify it while the user is mousing.
- Plan identity: `CredentialsParser` also surfaces `subscriptionType` /
  `rateLimitTier` (`PlanInfo` — metadata beside the token, never the
  refresh token); it rides `Snapshot.plan` and renders under the panel
  title.

## The sessions browser

- SESSIONS BROWSER (2026-08-15 v0.30.0, user-directed "axis 3"): a
  dedicated Sessions NSWindow (SessionsWindowController — the exact
  SettingsWindowController contract: lazy first-show,
  isReleasedWhenClosed=false, center() THEN setFrameAutosaveName,
  activation trio every show, close() registered in
  StatusItemController.adopt() BEFORE outgoing.shutdown()). Data layer:
  `TranscriptScan.sessions: [SessionSummary]` — per-file summaries ride
  the scanner's cache (v4; ONE `cacheVersion` constant now, never three
  literals) as `SessionFileSummary` (title/firstPrompt≤120-scrubbed/cwd/
  branch/entrypoint/version/start/end/stretches/prompts/toolCalls/
  compactions; apiCalls + models stay DERIVED from `days` — never stored
  twice), merged by path (`/subagents/` substring → part of the `<uuid>`
  before it; covers workflows depth). TRAPS the design review caught,
  now load-bearing: (1) `message.content` is a STRING on user lines —
  `BlockList`'s lenient unkeyed decoder absorbs it; a synthesized
  `[Block]?` silently drops every command/compaction/prompt line via the
  loop's `try?`. (2) Metadata rules run BEFORE the usage keep-rule —
  `ai-title` has no timestamp and would die at the old front guard.
  (3) Tool counting sees every assistant line BEFORE dedup (streamed
  lines share usage but carry DISTINCT tool_use blocks; count a per-file
  id Set). (4) Session active time = sweep-UNION of per-file
  grace-stitched stretches (subagents run concurrently — summing or
  re-stitching double-counts). (5) `queue-operation` records duplicate
  their dequeued user record — ignore entirely. Capability gate:
  `LocalActivitySource.providesSessions` (default false) +
  `sessionDetail(id:)` (default nil) — hides the ⋯ "Sessions…" item and
  window for sessionless providers. Store: `sessions` published in
  scanActivity's MainActor hop (single-flighted via isScanningActivity),
  `sessionDetail(id:)` detached at .userInitiated with cancellation
  propagated (SwiftUI's .task(id:) cancels on selection change — keyed
  by a composite DetailKey{id, end} so live sessions refresh per scan).
  `usage-cli sessions [--provider id]` prints the index via
  `scan(persistCache: false)` — the APP is the cache's sole writer.
  Background runs: `entrypoint != "cli"` → badge + dim + toggle
  (default SHOW, user decision; no parent attribution — verified no
  linkage exists in hook transcripts). `--sessions` launch hatch.
  Spec §10 amendment lists exactly what the cache may materialize.
  RECONCILIATION (v0.32.0, user-reported $630-vs-$610 discrepancy):
  sessionDetail parses the main file AND every `<id>/subagents/**` file
  fresh from disk — NO cache read at all (the ≤60s-stale rollup died
  with it); subagent API calls join the rows time-interleaved, carrying
  `SessionEvent.subagent` (dimmed "· subagent" rows), so the detail
  ledger reaches the card's total EXACTLY. The chart endpoint trailing
  the sidebar by the subagents' spend is a bug class, and
  subagentRollup's rowTokens == summary.totalTokens assertion is its
  regression test. Freshness rides FSEvents → scanActivity (1/min
  throttle) → DetailKey{id, end} re-fires the parse. SKELETON
  (v0.34.0): a selection SWITCH clears stale detail synchronously in
  the .task (the previous session's content must never linger as a
  frozen pane) and shows a skeleton whose header + ModelBreakdownGrid
  are REAL — the sidebar summary already knows them — with pulsing
  bars only for chart + rows (Pulsing honors Reduce Motion); a
  same-id re-fire keeps content and swaps silently, and hover state
  resets only on id change. The skeleton must be width-neutral
  (v0.35.0): SkeletonBar widths are CAPS (maxWidth), never fixed
  frames, and the placeholder rows live inside the same ScrollView
  shell as the loaded list — a skeleton whose minimum width exceeds
  the loaded content's makes the split view widen on every selection
  and snap back when the parse lands. DASHBOARD HEADER (v0.37.0,
  user-approved mock): three bands, all derived from the sidebar
  summary so the skeleton renders the whole header real — (1) title +
  cost KPI top-right (ModelBreakdownGrid's centered headline is
  suppressed via showsHeadline: false; the number appears ONCE), (2)
  icon context strip (FlowLayout of SF-Symbol chips: folder / branch /
  calendar / timer / terminal / number; empty facts omit their chip,
  never "—"), (3) six StatTiles in an HStack of equal maxWidth:
  .infinity shares — the grid must always FILL the header width and
  stretch with resizes (user-directed; that's why it's an HStack, not
  an adaptive LazyVGrid, which wraps 5+1 under squeeze). Tile styling
  (v0.38.0–v0.40.0, user-directed): the WHOLE tile wears a light wash
  of its StatTint (fill 0.1, hover-deepened to 0.16 over 0.12s) under
  a slightly stronger frame (0.3) of the same tint; glyph, value (20pt bold, a touch lighter than
  standard label ink in dark), and label stack CENTERED with the
  glyph on its own row (a corner glyph collided with the centered
  value on narrow tiles); the prompts tile wears the provider
  accent — ❯ is the app's prompt color story. CTX COLUMN (v0.41.0):
  call rows show tally.inputSide over ModelRates.contextTokens (the
  feed's max_input_tokens; bundled mirrors the real feed — 1M for the
  5-family + opus-4-6..8 + sonnet-4-6, 200K legacy, nil where the
  feed has none) between OUTPUT and COST — "<1%" below one percent,
  "—" only when nobody knows the window. THREE traps solved here,
  don't regress them: max_input_tokens decodes as Double (an exotic
  feed value must not knock out the entry's whole pricing row); a
  disk pricing cache from BEFORE the field counts as stale
  (isStale's allSatisfy-nil clause) so the column populates one
  refresh tick after update, not 24h later; and the view falls back
  to the bundled floor's window while that stale cache still serves.
  The skeleton carries the matching bar. ROW COST POPOVERS (v0.43.0):
  call and prompt rows click open (pointerStyle .link; the hover tint
  holds while open, the grid's held-lit idiom). A call row opens
  CostMathView with its own model+tally — IDENTICAL to clicking a
  model row. A prompt row opens the totals-card ModelBreakdownGrid
  scoped to its span (SessionSpanTally in UsageCore: promptRange =
  prompt through the row before the next prompt or session end;
  models/calls clamp stale ranges so a live re-parse can't trap),
  headed by the ❯ preview + "N API calls through the next prompt/the
  session's end"; the grid's model rows keep their own CostMathView
  click-through (nested popover) and its hoveredModel binding is the
  pane's real one, so hovering models in the popover focuses the
  chart behind — popover onDisappear clears it so a dismissal
  mid-hover can't leave the chart stuck focused. Command/compaction
  rows have no cost story and don't open. Fixed popover width (344)
  because a Text's ideal width is its unwrapped width — natural
  sizing would let a long preview blow the popover out.
  PANEL SHORTLIST (v0.45.0): the panel shows a "Sessions" strip
  below the activity heatmap — SessionShortlist.build (UsageCore):
  newest ≤3 INTERACTIVE sessions (background never listed), hasMore
  true when the cap or the background filter hid anything, which
  shows the "Show more…" button (plain onOpenSessions). Rows are the
  sidebar's FULL SessionRow card (v0.47.0 user-directed; SessionRow
  is internal, not private, exactly so both surfaces render one
  component and can't drift; palette = the same all-sessions union
  the window computes, so dots match across surfaces) wrapped in the
  grid's hover/link idiom; clicking calls onOpenSession(id) →
  StatusItemController.showSessions(selecting:) →
  SessionsWindowController.show(selecting:) → SessionsNavigator
  (@Observable, consume-once `requested`) → SessionsView applies it
  in BOTH .onAppear (request set before a fresh window's first
  render) and .onChange (retarget while open), selecting + scrolling
  the sidebar then clearing the request. The section gates on
  store.providesSessions.
  CODEX SESSIONS (v0.31.0): CodexActivitySource populates the same
  seam — one rollout file = one session (cache v2; SessionMeta stores
  title/cwd/cli_version/start/end/stretches, counts derived from
  DayTally), title = scrubbed first user_message, kind always
  .interactive (rollouts carry no headless marker), detail rows from
  user_message + token_count deltas. Gemini stays sessionless.

## Session rename, search and sort

- SESSIONS RENAME + SEARCH/SORT (2026-08-17): titles are click-to-rename
  in the sidebar cards AND the detail header (SessionRow's affordance is
  OPT-IN via handlers — the panel shortlist passes none, its rows are
  click-to-open; Escape cancels BEFORE the focus-loss commit, which the
  owners drop as stale). Custom names are an app-side OVERLAY:
  `SessionRenames` (core, tested) persists `session-renames.json` in the
  app's provider support dir (§10-clean; orphans kept — pruning against a
  partial scan could drop live renames), applied in `UsageStore.sessions`
  so every app surface agrees; the DIGEST keeps derived titles (TUI/CLI
  parity for custom names is a deliberate follow-up). Empty or
  derived-equal commit clears the override; detail header reads
  `customSessionName ?? parse title` so live re-parses can't wash a
  rename away. Sidebar search+sort: `SessionOrdering` (core, tested) —
  match over title/path/branch/id; axes recency/name/tokens/cost
  (@AppStorage keys `sessionsSortKey`/`sessionsSortAscending`, FROZEN),
  ties break newest-first, absent cost (unpriced-only, the "—" cards)
  sinks to the END in BOTH directions, day sections exist ONLY on the
  recency axis (`SessionDayGroup.build` needs newest-first input;
  ascending reverses groups + members), navigator requests clear the
  query so a landing can't be hidden by a stale filter. v0.83.0
  refinements (user-directed): a rename click parks the caret on the
  CLICKED character, never AppKit's select-all — `FieldEditorCursor`
  maps the tap (window coords off NSApp.currentEvent) through the field
  editor's characterIndexForInsertion, bounded retries, end-of-text
  fallback; renameable titles wear the id-chip grammar (hover tint +
  `.pointerStyle(.link)`); the card's top-right KPI presents the ACTIVE
  SORT's value — the tokens sort promotes the token total there and
  demotes cost to the caption line (`SessionRow.sortKey`; the shortlist
  passes none → cost default), name/recency keep cost since their values
  already own fixed prominent homes.

## The message table: do not re-attempt the restructure

- MESSAGE-TABLE PERFORMANCE (2026-08-16, v0.61.0–v0.61.2, user: "VERY
  sluggish" scrolling): the table is LAZY, NOT VIRTUALIZED — LazyVStack
  creates rows on demand and RETAINS every one it ever created. The
  v0.61.0/.1 restructure (Equatable MessageRow + one interaction-layer
  overlay with fixed-row-height hit math + one popover proxy) DID NOT
  improve the felt scroll performance (user verdict) and caused three
  regressions (dead cost popover — anchor inserted in the presenting
  transaction; popover anchored at the list top — .offset is a render
  transform AppKit ignores when resolving popover anchors; dark
  slivers between lit rows), so v0.61.2 REVERTED the table wholesale
  to the per-row-modifier form (v0.60.3 state). Do NOT re-attempt that
  restructure. If sluggishness is tackled again, the lever is real
  row recycling: an NSTableView-backed List or NSTableView wrapper,
  not SwiftUI-side diffing. Transferable macOS facts learned: popover
  anchors resolve against LAYOUT frames (position anchors with
  padding, never .offset), and a popover whose anchor view is
  inserted in the same transaction that flips isPresented is silently
  dropped.
