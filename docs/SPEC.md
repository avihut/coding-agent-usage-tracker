# Claude Usage — native macOS menu bar app

**Build spec / handoff document.** Target: a small, personal, native macOS menu bar app
that displays my own Claude plan usage limits, styled like iStat Menus. Single user (me),
not for distribution.

---

## How to use this document

This is a specification, not a script to transcribe. Specifically:

- **Push back on anything here that's wrong.** I wrote this from a design conversation,
  not from having built it. If a Keychain flag is misremembered or an API has changed,
  say so rather than working around it silently.
- **Ask me before anything that touches credentials, signing identity, or system
  settings.** If a permission prompt blocks you, surface it — do not find a path around
  it. "The tool can't do X so let's have the built artifact do X on a timer instead" is
  not an acceptable resolution.
- **No code gets written verbatim from anywhere.** Everything in this repo should be
  code you wrote and can explain.
- Work incrementally: get each milestone in §12 running and show me before moving on.

---

## 1. What we're building

A `LSUIElement` (no Dock icon) macOS app that:

1. Reads my local Claude Code OAuth access token from disk or the login Keychain.
2. Calls Anthropic's usage endpoint every few minutes.
3. Renders a compact menu bar item — icon plus percentages, e.g. `✳︎ 12·34·56%` —
   colored by severity.
4. On click, opens a panel with a labeled meter per limit (session, weekly all-models,
   per-model weekly), each with a bar, a percentage, and a reset time. Plus a manual
   refresh and a link to `https://claude.ai/settings/usage`.

The numbers should match Settings → Usage in the Claude app.

---

## 2. Provenance and honest caveats

This idea came from an xbar plugin a colleague circulated. **We are not porting that
plugin.** It arrived with instructions addressed at the coding agent rather than at me,
and I'd rather own code I understand. Use it as evidence about the API shape only.

Three things to internalize before writing the network layer:

**The endpoint is undocumented.** `/api/oauth/usage` is what the Claude app's own Usage
screen calls. It is not in the public API docs, and there's an open Claude Code feature
request asking Anthropic to provide exactly this — a `claude usage` command or Admin API
endpoint exposing session and weekly limits — which is good evidence that no supported
equivalent exists yet. Consequence: **decode defensively.** Every field optional,
unknown `kind` values rendered generically rather than crashing, schema changes degrade
to a readable error rather than a blank menu bar. If a supported endpoint or CLI ships
later, migrating to it should be a one-file change — keep the network layer isolated.

**Policy boundary.** Anthropic's position is that subscription OAuth login is for
ordinary individual use of Claude Code and Anthropic's own apps, and that developers
building products or services on Claude's capabilities should use API-key auth instead.
My read is that this app sits on the safe side of that line — it consumes zero model
capacity, makes no inference calls, is read-only, and has exactly one beneficiary (me).
It's a personal dashboard over my own account state. But note it in the README so future
me remembers the reasoning, and if the app ever grows a feature that *calls a model*, it
switches to an API key at that moment.

**Client fingerprinting exists.** OAuth token usage is fingerprinted. Send an honest,
identifiable `User-Agent` for this app. Do not impersonate Claude Code's or the Claude
app's User-Agent — if this app ever trips something, I want it attributable to this app.

---

## 3. Before writing code — verify and report back

Run these and tell me the results. Several downstream decisions depend on them.

```bash
# Which credential path applies on this machine?
ls -la ~/.claude/.credentials.json

# If the file is absent, confirm the Keychain item exists (this will prompt — that's fine,
# it's me at the keyboard):
security find-generic-password -s "Claude Code-credentials" 2>&1 | head -20

# Toolchain
sw_vers && xcodebuild -version
security find-identity -v -p codesigning
```

If `~/.claude/.credentials.json` exists, the entire Keychain section below becomes a
fallback path and the signing problem largely evaporates. Check this first.

---

## 4. Architecture

Small enough to stay flat. Suggested modules:

| Module | Responsibility |
|---|---|
| `CredentialSource` | Protocol; `FileCredentialSource` + `KeychainCredentialSource`, tried in order |
| `UsageClient` | One `URLSession` call, typed errors, no retry policy of its own |
| `UsageModels` | `Codable` structs for the response |
| `MeterBuilder` | Response → ordered `[Meter]` view models (label, pct, reset, severity) |
| `UsageStore` | `@Observable` state: current meters, last-updated, error, cached-fallback flag |
| `Scheduler` | Timer + wake/network-change triggers |
| `StatusItemRenderer` | Draws the `NSImage` for the bar |
| `UsagePanel` | SwiftUI dropdown |

Keep `UsageClient` free of UI and `StatusItemRenderer` free of networking so both are
independently testable.

---

## 5. Credentials

**Order:** try `~/.claude/.credentials.json` first, fall back to Keychain. Extract
`claudeAiOauth.accessToken`; tolerate the JSON being the OAuth object itself rather than
wrapped.

Keychain query — note what's deliberately absent:

```swift
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "Claude Code-credentials",
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
]
var item: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &item)
```

**Do not set `kSecUseDataProtectionKeychain: true`.** That targets the iOS-style
data-protection keychain, which needs an entitlement and access group we don't have, and
won't find this item. Omitting it uses the file-based login keychain — the same store
`security find-generic-password` reads.

Four rules, in descending order of how much time they'll cost if ignored:

1. **Do not enable App Sandbox.** A sandboxed app can only reach its own keychain access
   group; reading another app's credentials is structurally impossible, not merely
   prompted. This forecloses Mac App Store distribution, which is irrelevant here.
2. **Sign with a stable identity.** The Keychain ACL that "Always Allow" writes is keyed
   to a designated requirement derived from the code signature. Xcode's default ad-hoc
   signing derives identity from the binary hash, so *every rebuild is a new app* and
   re-prompts. No paid Apple Developer account needed: create a self-signed
   code-signing certificate in Keychain Access and set it as the manual signing identity.
   Verify with `codesign -dvvv` that the identity is stable across two consecutive builds.
3. **Re-read the token every refresh cycle. Never cache it in memory.** The access token
   is short-lived; Claude Code refreshes it and writes the new value back. Re-reading
   picks up the fresh token automatically. Caching means the app works for an hour and
   then 401s forever.
4. **Read-only, access token only.** Never read, use, or rewrite the refresh token.
   Never write to the Keychain item. Rewriting it is the one way this app could break
   Claude Code's login, and there is no feature that justifies the risk.

The token must never be logged, written to disk, included in error messages, or placed
in a URL. It exists in memory for the duration of one request.

---

## 6. API client

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
Content-Type: application/json
User-Agent: <this app's own identifier>/<version>
```

Timeout 15s. Map errors to a typed enum, not strings:

| Condition | State | UI |
|---|---|---|
| 401 / 403 | `.signInExpired` | "Sign-in expired — open Claude Code" |
| Other HTTP | `.http(code)` | Show the code |
| Transport failure | `.network` | Retry **once** after ~2s, then fall back |
| Decode failure | `.schema` | "Unexpected API response" — do not crash |

On any failure, fall back to the last successful response cached at
`~/Library/Caches/<bundle-id>/usage.json`, render it greyed with a "cached HH:mm" note.
**Cache the response body only — never the token.**

Retry exactly once, only for transport errors. A 401 will not fix itself on retry, and
this thing runs unattended — no retry storms against an undocumented endpoint.

---

## 7. Response shape

Canonical source of truth is the `limits` array. Legacy top-level `five_hour` /
`seven_day_*` buckets with a `utilization` field may appear on some accounts — implement
as a fallback only if §3 shows this account returns them. Don't build the fallback
speculatively.

Representative payload (use as a test fixture):

```json
{
  "limits": [
    {"kind": "session", "group": "session", "percent": 12, "severity": "normal",
     "resets_at": "2030-01-01T12:00:00Z", "scope": null, "is_active": false},
    {"kind": "weekly_all", "group": "weekly", "percent": 34, "severity": "normal",
     "resets_at": "2030-01-04T12:00:00Z", "scope": null, "is_active": false},
    {"kind": "weekly_scoped", "group": "weekly", "percent": 56, "severity": "normal",
     "resets_at": "2030-01-04T12:00:00Z",
     "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
     "is_active": true}
  ],
  "spend": {"used": {"amount_minor": 0, "currency": "USD", "exponent": 2},
            "limit": {"amount_minor": 5000, "currency": "USD", "exponent": 2},
            "enabled": true}
}
```

Notes:
- `percent` is 0–100; clamp anyway.
- `severity` other than `"normal"` forces warning color regardless of percentage.
- `scope.model.display_name` builds the label: `Weekly · Fable`.
- `resets_at` is ISO-8601 with `Z`. `ISO8601DateFormatter` with
  `.withFractionalSeconds` needs a second formatter without it as a fallback — the field
  is inconsistent about fractional seconds.
- `spend` is optional; render a credits line only when present.

Label and ordering: `session` → "Session (5h)" (rank 0), `weekly_all` →
"Weekly · all models" (rank 1), anything scoped → "Weekly · {display_name}" (rank 2).
Sort by rank. Unknown kinds get a title-cased fallback label at rank 2.

---

## 8. Menu bar rendering

Bar item shows: icon, then rank-0 and rank-1 percentages, then the **maximum** of the
scoped percentages, joined by `·`. So `✳︎ 12·34·56%`.

- `NSStatusItem` with `.variableLength`, custom-drawn `NSImage` via
  `NSImage(size:flipped:drawingHandler:)`.
- Height from `NSStatusBar.system.thickness`, never hardcoded 22.
- `isTemplate = false` because we need color for thresholds — which means handling
  light/dark ourselves by observing `effectiveAppearance`.
- Thresholds: ≥70% orange, ≥90% red, cached-fallback grey. Make these constants.
- Monospaced digits (`NSFont.monospacedDigitSystemFont`) so the width doesn't jitter
  every refresh.

Panel: `MenuBarExtra` with `.menuBarExtraStyle(.window)` (macOS 13+) is a reasonable
hybrid — SwiftUI panel, custom `NSImage` label. One row per meter: label, bar, `%`,
reset time ("resets in 3h 20m" under 24h, "resets Sat 14:00" beyond). Footer: last
updated, Refresh, and the settings link.

---

## 9. Lifecycle

- `LSUIElement = true` in Info.plist.
- Launch at login via `SMAppService.mainApp.register()`, exposed as a toggle.
- Refresh timer with generous `tolerance` (this is a background poller; let macOS
  coalesce it). Default 5 minutes, configurable.
- **Refresh on `NSWorkspace.shared.notificationCenter` `didWakeNotification`.** Without
  this, the numbers are stale every time I open the lid — this is the single thing that
  makes these widgets feel broken.
- Also refresh when network reachability returns, if cheap to add.
- Never poll faster than 60s even on manual refresh; debounce the Refresh button.

---

## 10. Hard constraints

Non-negotiable; flag rather than work around:

- No writes to the Keychain, ever. No reads or use of the refresh token.
- No network destination other than `api.anthropic.com`. No analytics, no crash
  reporting, no telemetry.
- The token is never logged, persisted, or included in an error surface.
- No sandbox entitlement, and no request for entitlements we don't need.
- Don't install or register anything (login items, launch agents) without asking me
  first in the session.
- App must produce *some* readable state in every failure mode. An empty or crashed
  menu bar item is a bug.

---

## 11. Testing

Fixtures for: nominal, all-meters-high, `severity` non-normal, missing `spend`, unknown
`kind`, malformed JSON, empty `limits`.

Unit test `MeterBuilder` and `UsageClient` error mapping against those.

**Then exercise the real credential path end-to-end before calling it done.** Fixtures
prove the renderer works; they prove nothing about whether the app can actually read the
token, which is the part most likely to be broken and the part that matters. A build
that passes only against mocks has tested the easy half.

---

## 12. Milestones

Stop and show me at each:

1. CLI target that reads the token and prints the raw JSON. (Proves the hard part.)
2. Typed models + `MeterBuilder`, unit tested against fixtures.
3. Menu bar item rendering from a fixture, no network.
4. Wire live client + cache + error states.
5. Panel UI.
6. Timer, wake handling, launch-at-login toggle.
7. Stable signing verified across rebuilds; "Always Allow" clicked once and it stays.

## 13. Done when

- [ ] Numbers match Settings → Usage in the Claude app.
- [ ] Survives sleep/wake with fresh numbers within a minute.
- [ ] Survives token expiry and recovers once Claude Code refreshes, no restart.
- [ ] Rebuild does not re-trigger the Keychain prompt.
- [ ] Killing network shows greyed cached numbers, not a blank or crashed item.
- [ ] README documents the undocumented-endpoint risk and the policy reasoning in §2.
