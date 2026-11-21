# Meter Antigravity (Google) — plan

Branch `feat/antigravity`, cut from main at 66bd426. Phase 1 (below) was the
read-only investigation and a proposal.

> **Decided and built, 2026-11-21 (user-directed).** This supersedes the
> proposal's "tokens only, no meter" for v1:
>
> | Topic | Decision |
> | --- | --- |
> | Identity | id `antigravity`, "Antigravity CLI", service "Google AI", glyph `∩`, accent violet #A142F4; registered last |
> | Tokens | the per-conversation `transcript.jsonl`, conversations found by listing `conversations/` by name; no database is opened |
> | Plan limits | ~~the CLI's custom status line, installed by hand~~ — superseded the same day (user-directed: "There shouldn't even be a path that requires extra work from the user"): the engine host runs the CLI's own `agy -p /quota` print mode, nothing to set up (spec §10 amendment 2026-11-21, second; `docs/plans/antigravity-zero-setup.md`) |
> | Meters | `gemini-5h` → Session (5h), `gemini-weekly` → Weekly, `3p-*` → scoped "Claude + GPT (5h/7d)", and (zero-setup branch) `gemini-argon-wtu-weekly` → scoped "Argon (7d)"; every pool the reading reports is shown; other buckets skipped |
> | A window that rolled with no newer reading | a dash and no reset time, unless no conversation was written since the reset (then 0%) |
> | Focus | a harness that read its usage and holds no limit isn't ranked for focus unless pinned (vendor-neutral) |
> | Gemini CLI | deprecated, still metered; its provider declares the note Settings and `usage-cli harnesses` show |
>
> Where it landed: `docs/HARNESSES.md` (Antigravity), spec §10. Step V0 —
> a real payload — was settled by the zero-setup branch with a real `/quota`
> reading checked against the CLI's own `/usage` screen: the bucket ids are
> `gemini-5h`, `gemini-weekly`, `3p-5h`, `3p-weekly` and
> `gemini-argon-wtu-weekly`; `/quota` carries no tier; an untouched pool
> reads fraction 1 with the Unix epoch as its reset. The "reset but no
> fraction = spent" reading is still unobserved.

The issue (2026-11-21): the person now works in Google's Antigravity CLI, and
the tracker shows none of it. The one Google harness, `GeminiProvider`, reads
Gemini CLI's `~/.gemini/tmp`, untouched since 2026-05-16 — so Gemini reads as
"quiet, last active 189 days ago" while Antigravity runs every day beside it.

## How this was looked at

Everything below was learned without writing anything inside an agent home.

- Folders were listed by name, size and mtime first. Nothing that holds or may
  hold a credential was opened (the list is under "Never read" below).
- Each SQLite file's journal mode was read from its 100-byte header (bytes
  18–19), not by opening it. Every database is WAL-mode. Databases were then
  opened only as `file:<path>?immutable=1`, and the directory was re-listed
  afterwards: no `-wal`, `-shm` or `-journal` file appeared beside a database
  that had been read. Sidecars do come and go here, written by the CLI itself:
  a final sweep at 17:50 local found a `-wal`/`-shm` pair beside the
  conversation started at 17:44 and beside `conversation_summaries.db`
  (stamped 17:44:59 and 17:49:58, moments when this investigation opened
  nothing). The pair that appeared at 17:30 was the same thing — a live
  conversation, which turned out useful.
- Protobuf blobs were dumped as **shape**: field numbers, wire types, varint
  ranges, and for strings only a class (uuid / ISO date / identifier / path /
  text) and a length. Values were printed afterwards only at fields the shape
  showed to hold an identifier, an enum, a timestamp or a token count. The
  JSONL transcripts were read the same way: key paths first, then values only
  for `created_at`, `type`, `source`, `step_index`, `model` and the token keys.
- Two public sources filled gaps: the CLI's own changelog (the CLI caches it as
  `~/.gemini/antigravity-cli/cache/CHANGELOG.md`, a copy of the public file in
  the `google-antigravity/antigravity-cli` repository; newest entry 1.5.14),
  and `strings` over the CLI binary (for env-var and field names only).
- One slip, reported plainly: `~/.antigravity/antigravity/bin/agy --version`
  was run once. That is the desktop app's editor launcher (see "Two `agy`s"
  below), not the agent CLI. A `find -newermt` over `~/.antigravity`,
  `~/.gemini/antigravity` and the app's Application Support folder right after
  showed it wrote nothing. No vendor binary was run after that.

## What is on disk, field by field

### Two `agy`s

- `~/.local/bin/agy` — the agent CLI. A 229 MB native arm64 binary, installed
  2026-11-21; first on `PATH`; it is what the person runs. It writes
  `~/.gemini/antigravity-cli/`.
- `~/.antigravity/antigravity/bin/agy` (and `antigravity` beside it) — a symlink
  into `/Applications/Antigravity.app`: the desktop app's VS Code-style editor
  launcher (`--version` reports the editor base 1.107.0; the app bundle is
  1.16.5, installed 2026-02-02). It is not the agent.

### `~/.gemini/antigravity-cli/` — the CLI's home

| Path | What it is | Read? | Useful? |
| --- | --- | --- | --- |
| `conversations/<id>.db` | one SQLite database per conversation, WAL mode, 32 KiB pages | immutable opens, shape + numbers only | yes — the store of record (below) |
| `brain/<id>/.system_generated/logs/transcript.jsonl` | one JSONL line per conversation step, written live | key paths + safe fields only | **yes — the proposed source** |
| `brain/<id>/.system_generated/logs/transcript_full.jsonl`, `…/logs/chunks/**` | the same rows untruncated, and 100 KB chunk copies | key paths only | no (duplicates) |
| `brain/<id>/.system_generated/{steps,messages,tasks}/**`, `brain/<id>/{scratch,.user_uploaded}/` | tool outputs, swarm board, agent scratch; per the changelog also git worktrees under `.system_generated/worktrees` | names only | no — and never walk it (size, worktrees) |
| `conversation_summaries.db` | conversation titles + an FTS index + `conversation_parents` | table names only | not for v1 (titles are a sessions-browser question) |
| `cache/conversation_metadata.json` | `conversations{<id>: {summary, is_internal, last_modified_time}}` | keys + the two non-text fields | no — it listed one conversation of the six on disk |
| `cache/last_conversations.json` | working directory → last conversation id | keys only | no |
| `history.jsonl` | `{display, timestamp (epoch ms), type, workspace}`; one line, `type: slash_command` | timestamp + type only | no — not a prompt log |
| `cache/CHANGELOG.md` | the public changelog | yes (public text) | yes, as documentation |
| `settings.json` | `trustedWorkspaces[]` | key names only | no — no plan, tier or quota |
| `cache/onboarding.json`, `cache/nux_state.json` | `onboardingComplete`, `consumerOnboardingComplete`; dismissed hints | key names only | no |
| `updater/update_status.json` | `message`, `success` | key names only | no |
| `log/cli-<stamp>.log`, `cli.log` | one log per CLI start | keyword counts and redacted message shapes only | no — no quota numbers (below) |
| `jetski_state.pbtxt` (565 B, 0600) | unknown | **name and size only** | ask (open question 2) |
| `jetbox_summaries_proto.pb` (3.5 KB, 0600) | conversation summaries — derived text | name and size only | no |
| `implicit/<id>.pb`, `presence/<id>.lock`, `installation_id`, `cache/default_project_id.txt` | implicit context, presence locks, install id, a project id | name and size only | no — identifiers, never wanted |

### The conversation transcript (`transcript.jsonl`)

One JSON object per step. Message bodies sit in `content`, `thinking` and
`tool_calls[].args` and are never decoded into a type. The rest:

| Key | Holds | Notes |
| --- | --- | --- |
| `created_at` | `2026-11-21T14:03:43Z` | ISO 8601, **UTC**, whole seconds; every row checked had this shape. The step's creation time — a model call is stamped when it starts |
| `type` | `USER_INPUT`, `PLANNER_RESPONSE`, `GENERIC`, `SYSTEM_MESSAGE` | a model call is `PLANNER_RESPONSE`; a tool step is `GENERIC` |
| `source` | `USER_EXPLICIT`, `MODEL`, `SYSTEM` | a prompt is `USER_INPUT` + `USER_EXPLICIT` |
| `status` | `DONE`, `ERROR` | the changelog notes ERROR steps were once omitted from this file (fixed) |
| `step_index` | 0…n | unique within a conversation; equals the database's `steps.idx` |
| `model` | `gemini-4-neon-xhigh`, `gemini-4-argon-low` | present only on model-call rows; the model id + the thinking-effort setting |
| `input_tokens` | uncached prompt tokens | see "Tokens" |
| `cache_read_tokens` | cached prompt tokens | `0` when none |
| `output_tokens` | output **including thinking** | see "Tokens" |
| `truncated_fields` | which body fields were cut | this file truncates bodies; token fields are integers and never truncated |

### The conversation database (`conversations/<id>.db`)

Tables: `trajectory_meta` (ids; `trajectory_type` 4, `source` 17 for every CLI
conversation here — plausibly the CLI's surface id, which is how app-written
conversations would be told apart if the stores are shared), `steps`
(`idx`, `step_type`, `status`, `metadata`, `step_payload`, …), `gen_metadata`
(one row per model call), `executor_metadata`, `trajectory_metadata_blob`,
`parent_references` (empty here), `battle_mode_infos` (empty).

`steps.step_type`: 14 = user input, 15 = model response, 101 = system message,
132 = tool call. `steps.metadata` is a protobuf whose shape, decoded:

| Field | Holds |
| --- | --- |
| 1 | `google.protobuf.Timestamp` — the step's creation time (UTC epoch seconds + nanos); equals `created_at` above |
| 6, 7, 8, 32 | further Timestamps (later lifecycle points) |
| 9 (model steps only) | a usage record: 1 model enum (int), 2 uncached input, 3 output, 5 cache read (absent when zero), 6 API-provider enum, 7 / 11 / 12 response ids, 8 a `{sessionID: …}` header map, 9 thinking tokens, 10 response tokens |
| 11 | the model enum (int) again |
| 26 | repeated `{status enum, Timestamp}` transitions |

`gen_metadata.data` repeats the usage record and adds a model-config string
(`gemini-4-neon`, `gemini-4-argon-trial` — no effort suffix, and for argon a
different name than the transcript's), Durations (generation time), and a
label map whose keys are `model_enum` (`MODEL_PLACEHOLDER_M535`),
`used_claude`, `used_claude_conservative`, `used_non_gemini_model`,
`request_id`, `cascade_id`, `trajectory_id`, `root_cascade_id`,
`last_step_index`. Every `used_*` was `false` here — but the flags, and the
changelog's mentions of Claude models, mean an Antigravity conversation **can
run on non-Google models**.

### The two sources agree exactly

For all eight conversations (60 model calls; re-checked at 17:46 local), every call's timestamp, uncached
input, cache read and output in `transcript.jsonl` equals the database's usage
record, call for call, with nothing missing on either side. The JSONL is
therefore enough, and it is the fresher of the two (next section).

### Freshness: why not the database

While a conversation is open, its newest rows live in the `-wal` file. An
`immutable=1` open reads the main file only. Measured on the live conversation
at 17:33 local: the transcript held 44 steps (its newest written 17 seconds
before the read); the immutable database read showed 37, behind a 32 MB WAL.
The main file catches up only at a checkpoint (32 MB of WAL at these page
sizes, or the CLI's exit — the changelog says it checkpoints on exit). An
immutable read can also land mid-checkpoint and see a torn page, which must
read as "skip this pass", never as zero.

The alternatives each cost something real:

- **Copy into the app's cache and open the copy** (db + `-wal`): fresh, but it
  persists full message text in the app's own folder — what §10 says never
  persists — and a non-atomic copy of two live files can still mismatch.
- **Read both files into memory, apply the committed WAL frames by hand, then
  `sqlite3_deserialize`**: fresh and writes nothing anywhere, at the price of a
  hand-written WAL reader (frame checksums and salts) on top of the protobuf
  reader.
- **A normal read-only open** is not an option: on a WAL database with no
  `-shm` it creates one, inside the agent home.

The transcript has none of these problems: it is a plain JSONL file the CLI
appends per step.

### Tokens

- `input_tokens` is the **uncached** part of the prompt. Proof from the data:
  across a 23-call conversation the prompt total `input + cache_read` grows
  monotonically call after call, and a non-zero `cache_read` always equals an
  EARLIER call's prompt total plus one — a cached prefix. If `input` already
  included the cached part, adding the two would double-count it and these
  identities could not hold.
- `cache_read_tokens` is the cached part; Gemini bills no cache-write class, so
  cache creation is 0 (as for Codex).
- `output_tokens` includes thinking: in every database row, output = thinking
  (field 9) + response (field 10).
- Mapping to `TokenTally`: input = `input_tokens`, cacheRead =
  `cache_read_tokens`, output = `output_tokens`, cacheCreation = 0. A missing
  key stays absent, never 0.

### Models

- The transcript's `model` is `<model id>-<effort>`. The effort words seen were
  `xhigh` and `low`; the changelog's `/effort` command implies more. Stripping
  must be an ALLOWLIST of known effort words, never "drop the last hyphen
  word": the database's own `gemini-4-argon-trial`, and the feed's `-lite`,
  `-preview` and `-image` ids, show how often the last word is part of the
  model's name. An unknown suffix stays on the id (and the call goes
  unpriced) rather than being guessed away.
- With the effort suffix stripped, the ids are in the LiteLLM feed this app
  already downloads: `gemini/gemini-4-neon` and `gemini/gemini-4-argon` (and
  `carbon`, `hydrogen`), `litellm_provider: gemini`, flat input / output /
  cache-read rates and no tiered keys. The existing `PricingFeedSelector.gemini`
  (strip the `gemini/` route) already matches them, so these calls can be
  priced from day one.
- Non-Google models (Claude, per the flags above) were not observed; their id
  format inside Antigravity is unknown (open question 10).

### Prompts are not model calls

Seven prompts (`USER_INPUT` + `USER_EXPLICIT`) against 60 model calls; one
prompt drove 23 calls and 107 tool steps on its own. Antigravity is agentic: a
prompt count says little about consumption. Nor is every prompt typed by a
person: every CLI start today ran in print mode (`agy -p`), and a print-mode
start at 17:30 created a conversation whose first row is an ordinary
`USER_EXPLICIT` input — so a prompt handed over by a script or another agent
counts the same as one typed.

### Quota: not stored locally

No plan quota, limit, reset time, tier or credit balance is stored in any file
this investigation could read. The evidence:

- The CLI's logs record the quota machinery running
  (`quota_manager.go: doRefreshQuota: starting reload (force=true)`) and the
  sign-in (`authMethod=consumer`), but never a number.
- The binary and the changelog name the shape: per-model **quota buckets**
  carrying `remaining_fraction` and `reset_time` (`QuotaInfo`), a user tier
  (`tier_id`) and plan info, and separate **AI credits** that cover requests
  once the plan quota is spent. It is a server-weighted fraction per model,
  not a count of requests or tokens.
- The CLI exposes it on demand: `/usage`, `/quota`, `/credits`, and in print
  mode `agy -p "/quota" --output-format json` "without starting an agent turn,
  spending quota, or leaving a conversation behind" (changelog; UTC
  timestamps in JSON output). Each such run is still a CLI start, and a start
  writes inside the home: the 17:14 print-mode `/quota` run left a new
  `log/cli-<stamp>.log`, a re-pointed `cli.log`, a new `implicit/*.pb`, and
  fresh stamps on `cache/onboarding.json`, `conversation_summaries.db`,
  `crashes/`, `last_check.timestamp` and `updater/` (the update check). It did
  not touch `conversations/`, which still read 16:23 afterwards.
- **Something on this Mac already runs print-mode `/quota` on a cadence**: the
  logs show it at 17:14, 17:27 and 17:41 local today, and print-mode prompt
  runs followed at 17:30, 17:42 and 17:44. It wasn't this investigation (open
  question 1).

### The desktop app

- `~/.gemini/antigravity/` holds only `skills/` and an `installation_id`
  (June): no conversations under it.
- `~/Library/Application Support/Antigravity` is a VS Code-style profile
  (201 MB): `User/globalStorage/state.vscdb` (+ `.backup`), `storage.json`,
  `User/workspaceStorage/*/state.vscdb`, `Cookies`, `Local Storage/`,
  `Session Storage/`, `Trust Tokens`, `credential-user-scope`, `DIPS`, logs.
  These hold or may hold sign-in state; they were listed and **never opened**.
  The CLI's own changelog agrees: it blocks its sandbox from that folder
  "since desktop apps keep credentials and session tokens there".
- The changelog says starting the CLI once "unpinned conversations or marked
  them unread in the desktop app", so the two share conversation state
  somewhere. Where the app writes its conversations is **unobserved here, not
  known to be absent** (open question 3).

### Accounts

- One home: `~/.gemini/antigravity-cli` (the binary's strings name the path).
  Sign-ins switch inside it (personal vs business; `AGY_ADC_AUTH` for
  Application Default Credentials).
- Credentials go to the macOS Keychain — and, per the changelog, fall back to
  "file-based storage" / "the CLI's private secrets file" when the Keychain
  fails. Where that file lives — possibly in this tree — was not established. **So the provider reads
  nothing in this tree but the named transcript files** — never a wildcard
  read, never `jetski_state.pbtxt`, never `implicit/`.
- `AGY_ACCOUNT` and `ANTIGRAVITY_CONFIG_REL_DIR` exist in the binary, with
  unknown semantics (a second home? an account selector?). Open question 9.
- No identity source: the signed-in email appears only in log lines, and a log
  is not an identity record. No `accountIdentity`, as with Codex and Gemini.

### What is stable enough to depend on

| Surface | Stability | Why |
| --- | --- | --- |
| `transcript.jsonl` field names | medium | named in the public changelog as the "conversation log", plain snake_case JSON, fixed when it dropped rows — but it lives under `.system_generated/` |
| `conversations/<id>.db` | low | internal protobuf with placeholder enums (`MODEL_PLACEHOLDER_M535`), WAL trap |
| model ids | low | new ids and effort words arrive constantly; the effort suffix must parse defensively |
| `cache/*.json`, `history.jsonl` | low | partial, and not meant for this |
| logs | none | internal |
| the quota | n/a | network only |

## Proposed harness

A **new harness beside Gemini CLI**. Gemini CLI stays for everyone else who
uses this project; their trees don't overlap (`~/.gemini/tmp` vs
`~/.gemini/antigravity-cli`), so nothing is counted twice.

- **Identity** (decision 1): id `antigravity`; agent name `Antigravity CLI`
  (honest about what is read; `HarnessState.shortName` comes out as
  "Antigravity"; it can drop the "CLI" if the app's store joins later);
  service name `Google AI` (the plan family it spends). Glyph and accent are
  the person's pick — candidates below.
- **Source**: `brain/<id>/.system_generated/logs/transcript.jsonl` for every
  `<id>` listed in `conversations/` — a listing, never a walk of `brain/`.
  Decode only `created_at`, `type`, `source`, `step_index`, `model`,
  `input_tokens`, `cache_read_tokens`, `output_tokens`. A per-file mtime/size
  parse cache in the provider's scoped folder, like Codex. A partial last line
  (the CLI mid-write) fails to decode and is skipped; the next pass reads it. A
  listed conversation with no transcript contributes nothing.
- **Meter** (decision 3): recommended **none in v1** — activity only (below). The
  panel then reads "No limits reported", and `usage-cli limits` prints nothing.
  The bar is the open part: a cell with no segments draws its mark and a dash,
  which today means "no number yet", not "no limit to read". Phase 2 checks
  this with `--snapshot` and, if it misreads, proposes a generic meterless cell
  state (no vendor names outside the provider). **Focus is the bigger cost**:
  `HarnessFocusRule` picks the shown harness with the most active days over 14
  and never asks whether it has a meter. Used daily, a meterless Antigravity
  can take focus — and the focused harness is what the bar leads with, what
  the digest's top level projects, and what `usage-cli limits` (and so a
  status line, `headroom`, anything reading the default) answers for, with
  nothing in it. See decision 3.
- **Heatmap and breakdowns**: token days from every model-call row, bucketed by
  the local calendar day of `created_at` (stored UTC, converted on read, like
  every other scanner), per-minute slots for the timeline; prompt-only faint
  days from `USER_INPUT` + `USER_EXPLICIT` rows. Models by base id (effort
  stripped), priced through `PricingFeedSelector.gemini`; an unpriced id shows
  a null cost, never $0.
- **Detection**: watch `~/.gemini/antigravity-cli/conversations` — flat, one
  file per conversation, and its `-wal` moves during a live session (the
  FSEvents push signal). Not the whole home: a bare CLI start or a print-mode
  `/quota` run stamps half the home with no conversation (see "Quota"), while
  `conversations/` stayed at 16:23 through the 17:14 start. Not `brain/`:
  it fans out into step outputs, scratch and git worktrees, which the capped
  mtime walk and the disk measure would wade through.
- **Dedup**: none needed within a file (`step_index` is unique). Across files,
  the changelog implies a fork carries the steps before its fork point, and the
  transcript carries no request id. Proposed: a call fingerprint (FNV-1a over
  `created_at`, model, and the three token counts), owned by one file
  corpus-wide — the same ownership rule the Claude scanner uses.
- **Accounts**: one home, `supportsMultipleHomes = false`, no identity source.
- **Model catalog**: `ModelCatalog.gemini`'s grammar already reads
  `gemini-4-neon` as "Gemini 4 Neon"; the union catalog dispatches gemini ids
  there. The effort strip is model-id parsing, so it lives in the provider.
- **Sessions browser**: not in v1 (`providesSessions = false`). Titles exist
  (`conversation_summaries.db`), but materialising them is its own §10 question.
- **Retention card**: none — no retention setting is known, and nothing is
  ever written there.
- **Privacy card**: `~/.gemini/antigravity-cli/conversations` (listing and stat
  only) and `~/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl`
  (timestamps, step types, model ids and token counts only), each on its own
  line, plus "no network, no credentials" — as for Codex and Gemini.
- **§10 amendment** (drafted here, signed only on approval): "Antigravity
  provider (amendment 2026-11-xx, user-directed): reads
  `~/.gemini/antigravity-cli/conversations` (directory listing and stat only)
  and each listed conversation's
  `brain/<id>/.system_generated/logs/transcript.jsonl`, strictly read-only,
  decoding only timestamps, step types and sources, step indexes, model ids
  and token counts; message text, thinking and tool arguments are never
  materialised. Nothing else under `~/.gemini/antigravity-cli` is read — its
  settings, state, logs and any credential fallback file among them — the
  Keychain is never touched, and the desktop app's Application Support
  folder is never read. Zero network destinations."

### Glyph and accent candidates

The bar already carries ✳︎ (Claude, terracotta #D97757), ⬡ (Codex, green
#10A37F) and ✦ (Gemini, blue #4285F4). Antigravity's own brand colour could not
be verified offline, so these are proposals, not facts:

| Glyph | Reads as |
| --- | --- |
| `∩` | an arch — meant to echo the product's mark, which could not be checked offline |
| `▲` | up, against gravity; heavy ink |
| `⇡` | up, light |

| Accent | Against the others |
| --- | --- |
| violet #A142F4 (a Google palette purple) | distinct from all three accents and from the warning/critical colours — **recommended** |
| Google yellow #FBBC04 | distinct hue, but reads like the warning amber |
| Google red #EA4335 / green #34A853 | too close to critical red / terracotta, and to Codex |

The TUI header draws the glyph too, so phase 2 checks its terminal width.

## What it will NOT claim

- **Not a quota.** Without the network, nothing on this Mac knows how much of
  the plan is left or when it resets. No percentage, no reset, no forecast —
  unless decision 4 says otherwise.
- **Not every model call.** Calls outside conversation transcripts are
  invisible: the CLI's background "LLM Monitor" (flash-lite, 26 log lines
  today) and, likely, title generation and Auto mode's command reviewer
  (`/btw` side questions are unverified either way). Tokens are a lower bound
  of what the CLI spent.
- **Not the desktop app's usage** until its store is observed.
- **Not `--remote-agent` conversations**, which run on remote machines.
- **Not spend.** Dollars are list-price counterfactuals, as everywhere in this
  app; the plan doesn't bill per token.
- **Not a rewound history.** If a rewind removes rows from a transcript, the
  day totals drop with them; quota already spent doesn't come back, and the
  heatmap says only what the files still hold.

## Decisions for the person

1. **The harness.** A new `antigravity` harness beside Gemini CLI, agent name
   `Antigravity CLI`, service `Google AI`. Pick a glyph and an accent (above),
   or name your own.
2. **Dependencies.** Recommended: **none.** The JSONL transcript carries every
   number the database does, fresher, so the provider needs only Foundation's
   `JSONDecoder`. If the person would rather build on the database (the store
   of record, which outlives a change to the JSONL), that adds the system
   `SQLite3` module (part of the macOS SDK — no package dependency; `guard.sh`'s
   Package.swift rule is untouched) and a ~100-line hand-written protobuf
   varint / length-delimited reader. It must also choose a staleness answer: an
   immutable read (lags a live conversation until checkpoint — 37 vs 44 steps
   measured), or an in-memory WAL apply (fresh, more code). Copying the
   database into the app's cache is not proposed, since it persists message
   text.
3. **The meter.** Options:
   - **(a) No meter, activity only — recommended.** Tokens, prompts, models
     and costs in the heatmap and breakdowns; the bar shows the mark. It forces
     a second choice, because focus ignores meters (see "Meter" above):
     **(a1) a harness with no meter is never focus-eligible unless pinned** — a
     small vendor-neutral rule in core, so the bar, the digest's top level and
     `usage-cli limits` keep answering for a harness that has limits; the
     recommended pairing — or **(a2) accept it**: on days Antigravity leads,
     the default nouns come back empty and a status line shows nothing.
   - (b) A Gemini-style local count against an assumed cap. Not recommended:
     the vendor's quota is a weighted fraction per model bucket, so any count
     against any cap is a made-up number that would disagree with the CLI's own
     `/quota`.
   - (c) The real quota, through decision 4.
4. **Network, credentials, the language server: STOP AND ASK.** Each route to
   the real number is a spec §10 amendment, and none is taken without the
   person directing it:
   - **Spawn the vendor's own scripting surface**, `agy -p "/quota"
     --output-format json`, on a slow cadence. Closest to honest: Google's
     client, its own sign-in, a documented machine-readable output. Costs:
     network on the app's initiative (by proxy), a 229 MB launch per poll,
     possibly a self-update, and **every run writes inside the agent home** —
     a new log, `cli.log`, `implicit/`, `cache/onboarding.json`,
     `conversation_summaries.db`, `crashes/`, and the update check's
     `last_check.timestamp` and `updater/` — the never-write rule broken by
     proxy, which the amendment would have to say outright.
   - **Call Google's endpoint directly** with the sign-in token: a new
     destination, a credential read from the Keychain (with a consent-prompt
     risk that §10 forbids for regular operation), and an undocumented
     internal API.
   - **Ask the CLI's local language server**: a localhost call needing a CSRF
     token taken from the running process.
   - **A status-line export the person installs** themselves, if the custom
     status line's JSON carries quota — unverified; the changelog only says
     the default status line shows quota usage.

## Open questions

1. **What runs `agy -p "/quota"` here** about every 13 minutes (17:14, 17:27,
   17:41 today), with print-mode prompt runs after it (17:30, 17:42, 17:44)?
   Another quota reader already on this Mac would change what decision 4 is
   worth.
2. **`jetski_state.pbtxt`** (565 B, mode 0600) was not opened: its purpose is
   unclear, and the CLI's credential fallback file may live in this tree.
   May it be read for field names only, or does it stay unread? The plan works
   without it.
3. **The desktop app's conversations**: one agent conversation run in the app,
   then a second read-only look, would settle whether it shares
   `~/.gemini/antigravity-cli` or writes `~/.gemini/antigravity/`.
4. **Swarms and subagents**: each worker gets its own conversation. Does a
   worker's first message arrive as `USER_INPUT` + `USER_EXPLICIT` (it would
   then count as a prompt)? One `/swarm` run would tell.
5. **Forks and rewinds**: confirm the fork copy-forward that the dedup rule
   assumes, and how a rewind changes the file.
6. **Headless `agy -p` runs**: observed once to leave a conversation and a
   transcript like any other (17:30). Is the person, or a tool, driving them?
   If a tool, its prompts count as prompts (see "Prompts are not model
   calls").
7. **Retention**: does the CLI ever prune old conversations? The heatmap's
   reach is whatever stays on disk.
8. **Effort in the breakdown**: tally by base model (priced, one row per
   model) or keep `neon · xhigh` and `neon · low` apart (more rows; same
   prices)? The proposal is base model.
9. **`AGY_ACCOUNT` / `ANTIGRAVITY_CONFIG_REL_DIR`**: a second home would make
   this a multi-account harness. Worth asking whether the person uses either.
10. **Non-Google models**: if the person runs Claude inside Antigravity, what id
    does the transcript carry, and should those calls be priced on Anthropic
    rates?

## Evidence base, and its limits

One afternoon (2026-11-21, about 14:00–15:45 UTC), one CLI build (changelog
newest 1.5.14), eight conversations, 60 model calls, seven prompts, two
models. No fork, rewind, swarm, subagent, multi-day history, Claude-model call,
quota exhaustion or desktop-app conversation was observed. Every rule above
that depends on one of those is an open question, not a finding.

## Phase 2, once approved (outline)

- `Sources/UsageCore/Providers/Antigravity/` — the provider and its activity
  source; appended LAST to `HarnessResolution.standardProviders()`, so the
  bundled default and every existing order stay put.
- The §10 amendment in `docs/SPEC.md` and `docs/PRIVACY.md` first; then the
  `docs/HARNESSES.md` section, the privacy card lines, the README's privacy
  sentence, and a `.release-notes/next.md` entry (appended).
- Tests in `Tests/UsageCoreTests/` on **synthetic** transcripts built in the
  test (never a real file): the token mapping, the effort strip, prompt days
  from explicit input only, local-day bucketing across UTC midnight, a partial
  last line, a listed conversation with no transcript, a fork's copied calls
  counted once, an empty home → `noLocalData`, unknown keys ignored, missing
  token keys absent rather than zero.
- The digest is additive: the new harness arrives in `harnesses[]` with no
  schema change. The TUI reads harnesses generically, so phase 2 expects no
  Rust change beyond checking the glyph.
- Verification without the live install: `mise run gate`, the `--snapshot`
  PNGs (one shows the meterless cell), and `usage-cli` against the real home
  read-only.
