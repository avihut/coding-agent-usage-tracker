# Activity padding and model colour contrast — plan (2026-11-21)

User-reported after #37 merged: "Following the latest unification change the
padding looks bad now and requires a fix", then (22:49) "The models color
scheme needs some constraints because the opus 5.5 color makes it look
disabled or unavailable or something." A layout fix plus a colour constraint;
no new elements, no type-scale changes.

## What is wrong (measured)

Demo snapshots at 2× from this worktree (`--demo-digest --snapshot`), the
user's screenshot at 1×. Content edges: 14 pt and 346 pt in a 360 pt panel.

1. **Overflow is the main "padding" symptom.** Outline names are
   `fixedSize`. A depth-1 name gets 75 pt today (324 pt text width − 230 pt
   of columns and gaps − 19 pt lead). "Codex Auto Review" is 92.7 pt at
   caption2. The panel content grows past 360 pt and is centred, so every
   section's 14 pt margin collapses: in the user's screenshot the panel
   spans x 28–383 and the meter row's ink 30–381, a margin of about 2 pt.
   Reproduced with a demo Codex model renamed `codex-auto-review`: the
   whole panel shifts 10 pt left and the right side clips.
2. **A 4 pt inset.** The header and rows carry `.padding(.horizontal, 4)`,
   so the table's text sits at 18 pt / 342 pt against the 14 / 346 shared
   by every other section. `ModelBreakdownGrid` has the same inset (from
   before #37). Sessions rows are inset 6 pt; "Show more…" 4 pt.
3. **Nesting reads backwards.** Model rows indent `depth × 8`, so a depth-1
   name starts at +19 pt while its agent's name is at +28 (chevron 8 + 4 +
   mark 12 + 4). `HarnessMark` at ink 9 is a 12 pt square for every glyph
   (`side = ceil(ink × 1.25)`), so ✳ ⬡ ∩ ✦ names share one x (measured).
   Account rows have the same fault. An agent row with no children (a
   prompt-only agent) has no chevron, so its glyph sits in the chevron
   column.
4. **The headline caption crowds the header.** There is 4 pt between "at
   API list prices" and the column header (padding 2 + spacing 2). The
   section's rhythm is 8 pt.
5. **The demo has no Sessions section, but the data is there.** The demo
   digest carries sessions. The strip is gated on `providesSessions` →
   `localActivity`, which is nil in a `scansLocally: false` client
   (`UsageStore.swift:274`, `DigestClient.swift:115`).
6. **Colours.** The full grid: 4 harness accents × hue slots (8 per account,
   6 merged tones) × shade slots 0–4.
   - **Dark ground #323232:** 15–16 of 40 per-account colours fall under
     3:1 (worst 1.05:1). Merged: 16–22 of 30 (worst 1.01:1).
   - **Light ground #ECECEC:** 23–24 of 40 per-account colours fall under
     3:1 (worst 1.01:1, `#acf8ff`). Merged: 6–13 of 30.
   - **Merged adjacent versions collide outright** at slots 3→4 (ΔE_ok
     0.000): the step grows 0.24 × slot and clamps. Ledger slots are kept
     for life, so the newest and most-used version holds the HIGHEST slot.
   - **The user's Opus 5.5** is `agentShade(0, 4)`: brightness 0.851 × 0.3
     gives `#411204`, 1.08:1 on their real ground.

## Layout fix

- **Edges.** Rows and header keep their 4 pt inner padding, so the
  highlight looks as it does now. The grid takes it back at the panel call
  sites (HeatmapView's period table and day drill, both grids) with a
  negative 4 pt. Text then sits on the content edges and the highlight
  bleeds 4 pt into the 14 pt margin. The bleed sits outside `HoverProbe`,
  so the probe still covers the whole row.
- **Width budget.**
  - Content is 332 pt; the number columns take 210 (3 × 44 + 54 + 3 × 8).
  - The minimum gap from a name to the first column drops from 20 pt to
    8 pt. Numbers are right-aligned in 44 pt columns, so the visible gap
    stays at 20 pt or more.
  - The lead may take up to 114 pt.
- **Nesting rule.** A row's mark sits under its parent's NAME: child
  leading = parent leading + parent mark width + 4. That is +16 pt under
  an agent or account (12 pt marks) and +11 pt under a family (7 pt
  swatch). Every row reserves the chevron slot, so marks align in columns,
  including a childless agent's.
  - Name room: depth 0 gets 86 pt; a depth-1 model gets 75 pt (as today);
    a depth-2 model gets 59–64 pt.
- **Names never widen the panel.**
  - Model, family and agent names become `lineLimit(1)` with tail
    truncation and `.help(full name)`, at every depth. Accounts keep middle
    truncation.
  - Ideal width is unchanged, so hosts that size to fit (popovers) still
    show full names.
  - The same applies in `ModelBreakdownGrid`, which gets 102 pt after the
    bleed, so "Codex Auto Review" fits there.
- **Caption.** The headline block gets 4 pt more below it, 8 pt to the
  header, in both grids. The last-row-to-divider gap is measured and
  adjusted only if it is off the rhythm.
- **Sessions strip.** Rows bleed −6 pt (highlight kept), so glyph, title
  and cost sit on the content edges. "Show more…" and "No sessions" move to
  the edge.
- **Demo.**
  - A non-scanning `DigestClient` reports `providesSessions` when the
    digest carried any sessions. Local clients are unchanged.
  - Demo-only side effect: the "Sessions…" menu item appears, and a clicked
    session opens without detail. Noted in UI.md's demo hatch.
  - `demo-digest.py` gains a small long-named Codex model
    (`codex-auto-review`), so every snapshot keeps catching overflow.

## Colour fix

**Grounds.** Pinned in core: the binding ground per theme is the one closest
to the marks.
- Dark is #323232: the snapshot's, and `windowBackgroundColor`. The real
  popover over a dark desktop measured #1B1B1C, which is easier.
- Light is #ECECEC: the snapshot's. The real light popover is unmeasured
  (Assumed).

**Target.** WCAG 2.2 SC 1.4.11, 3:1 for graphical objects, for a bar
segment and a 7 pt swatch, per theme.
- Why per appearance: one colour passing 3:1 against BOTH grounds needs a
  relative luminance in [0.196, 0.246]. That sliver leaves no room for a
  family of shades.
- Identity bounds: OKLab L ≤ 0.90 on dark (near-white loses the hue) and
  L ≥ 0.40 on light (near-black does).

**Derivation.** Core, pure OKLCH:
1. The design colour → OKLCH. That is the slot-0 accent or fixed hue; in a
   merged chart, the agent's accent at the family's tone.
2. The band per theme and colour: [lo, hi] from the 3:1 target, found by
   bisection on L at that hue and chroma (so 3:1 holds exactly, not by a
   grey approximation), intersected with the identity bounds.
3. Base lightness is fitted into the band.
   - Slot 0 stays the brand accent wherever the accent already passes. On
     dark that is all accents except Antigravity's (2.84:1, nudged
     lighter).
   - On light, Claude's (2.6:1) and Codex's deepen slightly (Assumed).
4. Versions: five lightness levels per family, at band offsets
   {0, 2/5, 4/5, 1/5, 3/5} wrapping inside the band, each with a chroma
   scale.
   - Adjacent versions are ≥ 2/5 of the band apart; any two are ≥ 1/5
     apart.
   - Slot k ≥ 5 reuses slot (k−1)%4+1, today's four-step cycle.
   - Hue is fixed; chroma changes only for gamut mapping.
5. Merged: family tones take band positions and chroma scales, and
   versions step as above from there. Tuned in build against the tests.

**Prototype** (Python replica; the Swift is the source of truth):
- Contrast ≥ 3.00:1 everywhere, in both themes.
- Adjacent versions: ΔE_ok ≥ 0.12 on dark and 0.087 on light (merged
  before: 0.000).
- Any two of a family's five versions: ≥ 0.06 / 0.042.
- Merged family tones, pairwise: ≥ 0.053 / 0.037; build tunes these up.
- Hue drift: 0°.

**Honest capacity.** One hue in a lightness band 0.32 wide (dark) or 0.23
(light) cannot keep every (family, version) pair of one agent apart.
- Merged cross-family pairs at arbitrary slots under ΔE 0.04: about 12%,
  against 3% before, when the band ran to near-black.
- Build tunes the tones to push this down. A ±20° hue spread per family
  only reached 9% and risks Gemini's and Antigravity's hues meeting, so it
  is out.
- The outline legend and hover stay the disambiguator. Trade-off flagged
  for the person.

**Plumbing.**
- **Core.** `ModelColorMath.rgb(…, on:)` and `agentShade(…, on:)` take an
  appearance (dark/light). The pinned grounds, a WCAG `contrast`, and OKLab
  helpers live in a new core file.
- **App.** `ModelPalette` returns a dynamic `Color`: an appearance-provider
  `NSColor` holding both variants.
  - FIRST BUILD STEP is a spike. It proves `panel-light.png` really draws
    the light variants through Charts bars, the Canvas heatmap, swatches,
    SessionRow dots and the snapshot hatch.
- **Digest.** It carries one colour per model, pinned to the dark variant;
  the TUI draws that. Goldens are regenerated only with `UPDATE_GOLDENS=1
  swift test --filter LiveState`, and the diff is read.
  - The app never draws digest colours (checked: curves, rows and dots all
    use `ModelPalette`).
- **Ledger.** Untouched, no migration: slots stay, only derived colours
  change.

**Tests (core).**
- **The grid:** the 4 harness accents plus 3 stress accents (pure blue,
  yellow, grey) × hue slots 0..<8 or tones 0..<6 × shade slots 0..<10 ×
  both themes.
- **Every colour:** ≥ 3:1 against its ground; inside the identity bounds;
  hue within 1° of its base where chroma > 0.02.
- **Adjacent versions:** ΔE ≥ 0.08 on dark and 0.06 on light. Final
  thresholds are the Swift minima less a margin.
- **Any two of a family's first five versions:** ≥ 0.04.
- **Merged family tones (first four), pairwise:** ≥ 0.05.
- **Per-account family bases, pairwise:** a stated floor.
- **Also:** determinism, and WCAG/OKLab sanity checks. The existing
  `agentShades*` tests are rewritten for OKLCH hue and "slot 0 = the
  accent where it passes".

## Verify

- **Snapshots before and after, dark and light:** the default demo,
  `--several`, narrowed to Claude, and the long-name digest; also
  `meter.png` and `meter-codex.png`. Ink edges are measured in px (table
  header, agent and model names, cost column) against the meters' and
  Sessions' edges; the numbers go in the PR.
- **Swatch strips** before and after, rendered from a dumped grid.
- **Hover** cannot be seen in a snapshot, and a live launch is off limits.
  `HoverProbe` and its placement are untouched (checked by reading), so it
  is listed as verified by reading, not by hand.
- `mise run gate` green. A Fixes line goes in `.release-notes/next.md`.
  Docs: CHARTS.md (colours), UI.md (table edges, truncation, demo
  sessions), TUI-PARITY.md (the digest carries the dark variant),
  ARCHITECTURE.md (`ModelColorMath` is no longer "pure HSB").

## Found (belongs elsewhere)

- `ModelBreakdownGrid` rows use `.onHover` on a row that presents a popover
  (the CLAUDE.md never-again: `HoverProbe`).
- In the meter popover and session detail, the grid's text sits 4 pt inside
  their own content edges (same class, outside the panel).
