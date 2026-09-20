# Meter every harness at once (v0.101.0)

Branch `feature/multi-harness-redo`, cut from main at d59bcb8 (v0.100.1). This
is the third attempt: the first ("TOTALLY not even the direction") restyled
the one selected harness, the second (`feature/multi-harness-accounts`,
"better, but still not good") is not carried over. This one went
requirements → mocks → plan, each approved before the next.

- Mocks (approved "Looks good"): https://claude.ai/artifact/VMiyhuUARarSuFhHMc69J3
- The requirements handoff this restates was written for this worktree but
  now sits at `chore/hooks/HANDOFF.md`; this file is the tracked copy.

## Requirements, in the user's words

Background: "Up until now I used nearly only Claude Code on this computer so I
had it only report my Claude usage. Now I'm starting to use codex". The
feature is NOT a restyle of the single-harness view: "What I wanted is a
better way to display multiple active harnesses."

- **R1 · several harnesses the way several accounts work.** "how I actually
  want multi harness support to look is like multi-account support looks at
  the moment. […] they are presented alongside each other with an option to
  focus on a different one each time, and they are polled and tracked
  simultaneously. I want something similar."
- **R2 · automatic.** "Automatically track every detected harness"
- **R3 · no active harness; hide instead.** "make sure there's no "active
  harness" being selected, but offer an option to turn off displaying of a
  harness that isn't interesting to me."
- **R4 · rates per harness.** "allows seeing a list of the model costs of the
  different providers according to the detected harnesses." Hidden ones stay:
  "No—keep all detected harnesses in the Rates list"
- **R5 · forecasts stay per harness and per account folder**, and a login
  change inside one folder KEEPS that folder's learned history: "the idea of
  changing logins for the same account is changing the usage pull." Pooling
  would be a bug to fix; partitioning by signed-in identity is rejected.
- **R6 · fuzzy model search.** "an option to fuzzy search a model by name in
  the model selector at bottom of the API cost tab in the settings"

## Decisions (the user's, 2026-09-19)

| Question the requirements left open | Answer |
|---|---|
| Panel look | A · one unified strip; the Rows / Chips / Stacked forms all carry over |
| Does a hidden harness keep being metered? | Yes — hiding is display only |
| What is "detected"? | Present on disk; the 30-day dormancy rule applies per account |
| TUI, CLI, digest in scope? | Yes (the user asked for TUI mocks) |
| TUI focus | `tab` browses locally (that terminal only); a separate key pins for everyone |

R5 was verified in code, not assumed: history, the window ledger and the
weekly profile live under `<bundle>/<provider>/<profile>/`, and
`AccountPresenceLedger` only relabels. Nothing to build; a regression test pins it.

## Design

1. **One flat key per (harness, account).** Every harness's lone account is
   `"default"` today, and the host, the pin, the socket verbs, the digest,
   the registry and the menu bar cells are all keyed by that bare id.
   `Profile.key` = the bare id for the bundled default provider (the first of
   `HarnessResolution.standardProviders()`), else the provider-qualified
   storage prefix: `codex`, `gemini`, `codex.ab12cd34`. A Claude-only Mac keeps
   every id it has today; `Profile.id` stays the STORAGE id.
   `UsageEngine.profileID` is both storage id and notice identity — the key
   feeds only the latter, or history would move to `codex/codex/`.
2. **One host, N providers.** `MeteringHost(providers:)` (the one-provider
   init stays), one `ProviderServices` per present provider, a pure
   `HarnessRoster` (present × stored profiles × hidden → ordered rows),
   presence probed by `stat` and latched for the process. Hidden = no cells,
   not focus-eligible, engines keep running (`hiddenHarnesses` default, read
   on `settingsChanged`). Focus picks the harness by ACTIVE DAYS in the
   14-day window (file counts don't compare across vendors), then the account
   by today's `FocusRule`; a pin wins. `usaged` meters every harness;
   `setProvider` becomes a decodable no-op.
3. **Digest, additive only.** `profiles[]` spans every harness (flat keys +
   `accountID`); cells carry their own glyph and accent; new `harnesses[]`
   (identity, shown/present, activity, account count, and that harness's own
   status / notices / outages); `pinnedProfile`. The top level stays the
   focused harness's projection. `live-state-v1.json` is regenerated
   additively and a second golden, `live-state-v1-harnesses.json`, is decoded
   by Swift and Rust.
4. **App plumbing.** The registry holds a store per present harness keyed by
   the flat key; the Metering picker, `activeProviderID` and the switch
   teardown are gone. `ProviderStyle` statics become a `HarnessStyle` value
   passed explicitly (the hoisted popover and the hover card can't read a
   per-section environment); `ModelNames.catalog` becomes a constant union
   catalog.
5. **Menu bar.** The renderer's model gains glyph groups; a one-harness model
   is one group and takes today's code path, so every pinned PNG stays
   byte-identical.
6. **UI per the mocks.** Harness headings and tiles in the strip, a
   "Harnesses" card in General, per-harness preference and retention cards,
   one privacy inventory with a block per harness, rates grouped by harness.
7. **R6.** Core `FuzzyMatch` (subsequence with prefix / word-boundary /
   consecutive bonuses, over display name and raw id) behind an app
   `ModelSearchPicker` for the what-if playground.
8. **CLI.** Selectors on flat keys, `--provider` narrows, an ambiguous name
   across harnesses is exit 19, deep verbs gate on the selected account's
   provider, a `harnesses` noun.
9. **TUI.** A projection seam, a harness/account strip, local browse on
   `tab`, `P` pins, the 46×8 strip and `--status` per cell.

## Milestones

Each ends with a stop-and-show.

- **M0 · Ground** ✅ — this file; snapshot baselines.
- **M1 · Core capability, zero behaviour change** ✅ — both hosts still pass
  one provider. Green: 1023 Swift tests + 57 Rust, `mise run gate`,
  `mise run digest-freeze`; no shipped test file touched (only the golden,
  which is regenerated by design, +154 lines, 0 removals); all 49 status-item
  files `cmp`-equal to the M0 baseline with the sidecar identical; the live
  daemon and app run this code against the real account.
- **M2 · The flip + app plumbing** ✅ — `HarnessStyle` and the union catalog
  replaced the two globals; the renderer gained harness groups; both hosts
  now pass every provider; `--fake-harnesses` and seven pinned cases landed.
  All 48 pre-existing status-item files stayed `cmp`-equal at every step,
  and the real bar read `✳︎ S20·W28·F35%  ⬡ Ⓒ▬`.
- **M3 · UI per the mocks + R6** ✅ — strip with harness headings and glyph
  tiles, the Harnesses card, rates by harness (unseen tail folded),
  `ModelSearchPicker` over core `FuzzyMatch`. Both open items closed (see
  below).
- **M4 · TUI + the `harnesses` noun** ✅ — the noun with its four scalars,
  `notices`/`health` spanning shown harnesses, Rust mirrors + a
  second-golden contract test, `--status` per harness and the dashboard
  header's other-harness digits.
- **M5 · Docs + release** — SPEC §10 amendment, CLAUDE.md, README, then the
  release ritual.

## As built, where it deviates from the plan

M1 (2026-09-20). Each of these was a decision made while writing the code; the
design above still holds.

1. **Notice identity by ROUTING, not by a key in the engine.** The plan had
   `UsageEngine` write notices under a profile KEY. Instead every harness keeps
   its own ledger in storage-id terms exactly as before, and the DIGEST names
   another harness's notice `<provider>:<id>` (`NoticeRouting`), mapping a
   reset's account to its key when it phrases the card. A dismissal splits the
   name and lands in one ledger. No ledger migration, no chance of a
   re-detected grant being filed twice under a new id.
2. **One walk for two focus signals.** `MTimeProbe.Signal` gained `recentDays`
   and `LocalActivitySource` a `recentActivitySignal(since:)`, so a reprobe
   counts files AND the days they fall on in the same pass.
3. **The harness tie-break is sticky.** Equal active days keep the harness that
   already holds focus, then the newest write, then standard order — a
   two-harness day must not flap the bar.
4. **`--account` with `--provider`** agree or refuse: agreement is fine, a
   contradiction is exit 19, and `--provider` DISAMBIGUATES an otherwise
   ambiguous name (the refusal's own advice). A `--provider` naming a harness
   with no metered account falls through to the ordinary precedence, so the
   verb's own gate still answers exit 11 for it.
5. **The deep verbs gate before projecting.** `DigestQuery.resolveAccount` and
   `.projectAccount` are separate steps: which harness a verb may read is not a
   question about whether that account's section has landed.
6. **`ProfileView.accountID`** carries the storage id beside the key, so no
   directory is ever named after a key (`<bundle>/codex/codex/`).
7. **Closed in M3 — the LIST grew, not the verb.** "Dismiss all" spanning
   every harness was the honest verb; what was wrong was a panel that listed
   one harness's notices. Every face now lists every SHOWN harness's
   (`LiveState.pendingNotices()`, `registry.pendingNotices`), each row's rail
   in its own vendor's accent, and a click-through asks that notice's own
   provider where to go. A hidden harness's notices are not listed — hiding
   is what "not interested" means — and ids stay qualified, so a dismissal
   still lands in exactly one ledger.
8. **Closed in M3 — one download, shared.** `PricingFeedCache` keeps the raw
   LiteLLM bytes once at the bundle root; a service consults it before the
   network (a day's freshness automatically, a minute behind a click, so a
   click still reaches the network but its fan-out across harnesses is one
   request). Bytes are cached only after they decode.
9. **Settled in M4.** `notices`/`health` now aggregate across shown
   harnesses. The `accounts` table needed NO `harness` column after all: ids
   are flat keys, so the harness is already in the id, and adding one would
   have broken a pinned output format for nothing.
10. **Deferred, said plainly:** the TUI reads every harness (mirrors,
    `--status` blocks, the header's other-harness digits) but does not yet
    let you WALK them — `tab` to browse accounts locally, `P` to pin, and the
    46×8 strip's per-cell lines are not built. TUI parity has been deferred
    this way before (v0.96.0, v0.98.0, v0.91.0).
11. **The status row stayed two-line.** The mocks draw the pre-0.89 one-line
    row; the shipped D9 two-line block at ≥2 accounts is a user-directed rule
    with its own reasons, and the mock simply wasn't redrawn. Kept as shipped.

## Dev loop on this machine

- The live install already runs from THIS worktree's `ClaudeUsage.app`, and
  the launch agent points here. Every `mise run app` / `hatch` / `bundle`
  replaces the live app.
- `ensure` only restarts the daemon when the VERSION changes, and the version
  is frozen until M5 — so after every rebundle that should reach the daemon,
  `launchctl kickstart -k gui/$(id -u)/com.avihu.usaged`, or the daemon keeps
  publishing from the old code while the app is debugged against it.
- A `--snapshot` run kills the live app and quits; relaunch it afterwards.
- Baselines live in `.build/snapshots/` (git-ignored, survives sessions):
  `base/` plain, `base-fake/` with `--fake-profiles`. The gate: every
  `statusitem-*.png` `cmp`-equal, the old `statusitem-cells.txt` a prefix of
  the new one.
- Real harnesses here: `~/.claude` (one account), `~/.codex`, `~/.gemini`.
  A second Claude account exists only through `--fake-profiles`.
