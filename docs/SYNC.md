# Cross-device sync — CloudKit design

Status: **designed 2026-08-16, transport not built.** Blocked on the paid
Apple Developer membership (CloudKit containers require it even in the
development environment). Everything in this document that CAN exist without
the membership already does: the digest schema is frozen as code
(`Sources/UsageCore/SyncDigest.swift`), pinned by tests
(`SyncDigestTests`), and inspectable via `usage-cli sync-digest`. The spec
§10 amendment below is a **draft** — it is not in force, and no sync code
ships until it is signed off and moved into `docs/SPEC.md`.

Why the schema is designed before any CloudKit code can run: production
CloudKit schemas are **additive-only**. Record types and fields can be added
forever; nothing can ever be removed, renamed, or retyped once the schema
deploys to production. The digest is the one artifact in the whole sync
effort that is expensive to get wrong, and it needs no Apple account to get
right. This is also why sync was sequenced after the sessions browser: the
synced shape had to be derived from the finished session-cost model, not
guessed ahead of it.

## Goals

Per the roadmap decisions (2026-08-15):

- Multiple Macs, one picture: each machine publishes its own activity; any
  machine (later: iPhone, Watch) can view all of them.
- Attribution is detection, not forensics: activity belongs to the account
  detected on the machine that recorded it. Sync never re-attributes
  history.
- CloudKit only. No cross-OS transport abstraction; a Windows app, if ever
  built, is explicitly not expected to sync with Apple platforms.
- A quiet benefit: the private database becomes an **archive**. Claude
  Code's retention sweeps transcripts locally; the synced day rollups and
  session digests persist, so history outlives local cleanup.

## What syncs — and what never does

Syncs (the digest, exactly):

| Data | Notes |
|---|---|
| Day rollups | Local-calendar day key, tokens, API calls, prompts, per-model tallies |
| Session digests | Title, repo folder NAME, branch, kind, times, active seconds, counts, per-model tallies |
| Meter snapshot | Last-known percents/resets per meter, plan label, captured-at |
| Device profile | Per-install UUID, machine name, provider, app version, time zone |

Never syncs:

- **Full filesystem paths.** Only the project directory's last path
  component travels (`repoName`); `~/Projects/...` stays local.
- **Prompt text and previews.** No preview field exists in the digest. The
  one nuance: for sessions Claude Code never titled, the DISPLAY TITLE is
  the ≤120-char scrubbed first-prompt fallback, and it syncs as the title —
  an explicit sign-off item below.
- **Message text, transcripts, detail rows.** Never leave the machine, same
  as today.
- **Credentials, tokens, account identifiers.** The digest carries a
  display-only plan label; no stable account id is published until a
  provider can verifiably supply one (future additive field).
- **Dollar amounts.** Costing stays on the reading side — every viewer
  prices token tallies with its own pricing feed, exactly as the app does
  today. Synced dollars would go stale the day a price changed.
- **Pricing, settings, colors.** Device-local concerns.

## Draft spec §10 amendment (NOT in force)

> Sync (amendment TBD, vX.Y.Z): the app publishes a usage digest to the
> user's own iCloud **private database** via CloudKit — Apple infrastructure
> under the user's Apple ID; no third-party host is added. The digest
> materializes, per device and provider: day rollups (local-day token/call/
> prompt counts and per-model tallies), session digests (display title —
> which for untitled sessions is the scrubbed ≤120-char first-prompt
> fallback — repo folder name, git branch, kind, start/end, active seconds,
> prompt/call/tool/subagent/compaction counts, per-model tallies), the
> last-known meter snapshot (percents, resets, plan label), and a device
> profile (per-install UUID, machine name, time zone, app version). Full
> filesystem paths, prompt previews as such, message text, credentials, and
> dollar amounts are never published. All content fields ride
> `encryptedValues` (end-to-end encrypted fields). Each device writes only
> its own zone; remote records are an archive that outlives local retention
> and is deleted only by explicit user action ("forget this device").
> `usage-cli` never writes to CloudKit.

## Identity and merge model

- **Device identity**: a per-install UUID minted by the app on first sync
  (UserDefaults; never derived from hardware serials), plus the
  user-facing machine name for display.
- **One custom zone per device** — `device-<uuid>` — in the private
  database. **Each device writes only its own zone.** This is the roadmap's
  attribution rule expressed structurally: what a machine recorded is what
  that machine publishes, and nothing else.
- Readers fetch all zones and merge in memory. There are **no write
  conflicts by construction** — no record is ever written by two devices.
  `serverRecordChanged` is still handled (retry on the server base) as belt
  and braces against same-device races.
- Providers share the device's zone; record names carry the provider id
  (`day|claude|2026-08-16`). A machine that has hosted several harnesses
  publishes several device-profile records in one zone.
- **Archive semantics**: the scan updates and inserts records; it never
  deletes a record because its local source aged out. Deleting a device's
  zone (future "forget this device" UI) is the only bulk delete.

## Record types

Record names are frozen in `SyncRecordName` and pinned by tests. All content
fields ride `encryptedValues` (CloudKit's field-level end-to-end
encryption): nothing in the digest is ever queried server-side — records are
fetched by zone — so nothing needs to be a queryable plaintext field.

| Record type | Record name | Fields (all encrypted) |
|---|---|---|
| `UsageDevice` | `device\|<providerID>` | name, providerID, accountLabel?, appVersion, timeZone, capturedAt, schemaVersion |
| `UsageDay` | `day\|<providerID>\|<dayKey>` | dayKey, tokens, apiCalls, prompts, models (JSON `[String: TokenTally]`), schemaVersion |
| `UsageSession` | `session\|<providerID>\|<sessionID>` | title, repoName?, gitBranch?, kind, start, end, activeSeconds, prompts, apiCalls, toolCalls, subagentCount, compactions, models (JSON), schemaVersion |
| `UsageMeters` | `meters\|<providerID>` | capturedAt, planLabel?, meters (JSON array of id/label/percent/resetsAt/limitWindow), schemaVersion |

Notes:

- `dayKey` is the **publishing device's local calendar day** ("yyyy-MM-dd"),
  matching the heatmap's semantics; the device profile carries the time
  zone so viewers can present it honestly. Cross-device day alignment is a
  VIEWER concern, deliberately not solved in the schema.
- Per-model tallies embed as JSON `Data` reusing `TokenTally`'s Codable
  shape — which is already load-bearing (activity cache v4) and therefore
  already governed by an additive-only discipline.
- `UsageMeters` is the one mutable record — overwritten in place by its own
  device only. Everything else is upsert-by-stable-name.
- `kind` is a plain string (`interactive`/`background`) so future kinds
  can't break old readers.

## Transport plan (membership-gated)

`CKSyncEngine` (macOS 14+; we target 15) against the private database,
container `iCloud.com.avihu.ClaudeUsage`:

- Engine state (`CKSyncEngine.State.Serialization`) persists in the
  provider-scoped Application Support directory beside the activity cache.
- Publishing rides the existing scan flow: after `scanActivity` lands a
  scan, diff the digest against the last-published shapes and enqueue
  changed records. The digest builder already emits stable record names, so
  diffing is trivial.
- No iCloud account / iCloud off → sync is simply idle; the app is
  unaffected (same posture as "no local data": degrade quietly, never
  block).
- Viewers (this Mac's Sessions window showing other Macs; iPhone/Watch
  later) fetch all zones read-only and merge in memory. Remote sessions
  render nutrition cards priced by the LOCAL pricing feed; remote detail
  rows don't exist by design (only the machine holding the transcript can
  parse them).

Work that unlocks the day the membership lands, in order:

1. App ID with the iCloud capability + CloudKit container in the developer
   portal.
2. Provisioning profile for the app; `scripts/sign.sh` gains the
   entitlements plist (`com.apple.developer.icloud-services: CloudKit`,
   container id). Until now the bundle is signed with a bare Apple
   Development cert and no entitlements — this is the one build-system
   change sync forces.
3. CKSyncEngine wiring behind a Settings toggle (default OFF until the
   user turns it on — sync is opt-in).
4. Development-environment testing (schema is resettable there), then the
   one-way door: deploy schema to production.

## Schema evolution rules

- Additive only, forever: new fields and new record types; never remove,
  rename, or retype. The JSON-embedded blobs follow the same rule.
- Every record carries `schemaVersion` (currently 1). Readers ignore
  unknown fields and tolerate versions newer than their own.
- Future additive candidates, deliberately NOT in v1: percent-sample series
  (remote meter charts), stable account identifiers, per-day prompt
  timelines, Codex/Gemini publication (the builder is already
  provider-generic; the transport just isn't pointed at them yet).

## Size and cost

~730 sessions ≈ 200 KB of session records; a year of day rollups ≈ 100 KB;
meters + device profiles are noise. Total well under 1 MB against the
user's own iCloud quota. Record-count limits (400 records/operation) are a
transport chunking detail, not a schema constraint.

## Open decisions (sign off before transport ships)

1. **Untitled sessions** — their display title IS the scrubbed first-prompt
   fallback. Option A (recommended): it syncs as the title, flagged above in
   the amendment; remote lists stay readable. Option B: fallback titles are
   replaced by `Session a1b2c3d4` in the digest; remote lists go opaque for
   old sessions. The builder currently implements A.
2. **Repo folder names + branch names** sync. Fine for a private E2E
   database? (Recommendation: yes.)
3. **Machine names** sync (they're the "My Macs" list). (Recommendation:
   yes.)

## Inspection

- `usage-cli sync-digest [--provider <id>]` prints this machine's digest as
  pretty JSON — local-only, read-only, zero network, no Keychain prompt
  (so `planLabel` is null in CLI output; the app will publish it).
- `SyncDigestTests` pins record names, the privacy invariants (no full
  paths, no preview fields, no dollars in the encoded bytes), Codable
  round-trip, and the mapping semantics.
