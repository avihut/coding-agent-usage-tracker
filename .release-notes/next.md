<!-- What shipped, in prose. This becomes the annotation of the next
     release tag, which publish.sh ships as the GitHub release notes. -->

The app is now **AgentUsage** — it has metered every coding agent on the Mac
for a while, not one vendor's. `ClaudeUsage.app` becomes `AgentUsage.app`, the
bundle id moves from a personal prefix to `io.github.avihut.AgentUsage`, the
launch agent to `io.github.avihut.usaged`, and the package and `User-Agent` take
the repository's name, `coding-agent-usage-tracker`.

Nothing is lost in the move. On first launch the app (or the daemon, whichever
starts first) retires the old launch agent, moves its Application Support and
Caches directories — history, ledgers, forecasts — to the new identity, and
carries every setting across, menu bar item positions included. It runs once;
the old preferences file is left in place as the way back.

Two things belong to a bundle id and cannot be carried:

- **Launch at login** has to be switched on again (Settings → General).
- A menu bar manager (Bartender, Ice, …) sees a new app: if the item seems to
  be missing, look in its hidden section and place it once.

After pulling, `mise run app` replaces the running `ClaudeUsage` and deletes the
stale `ClaudeUsage.app` beside the new bundle. Delete any other copy you made
(for instance in /Applications): it is still a working app under the old
identity, and launching it would start a second engine on the old directories.

Releases are source-only from here on: a tag and its notes, never a binary.
A macOS app that strangers can open needs a paid Developer ID and
notarization, which this project doesn't have, so the app you run is one your
own Mac built and signed (README → Install). The 31 zips published before
this were removed.

- An app sitting outside a git checkout no longer offers "Update to X…" for a
  release that has nothing to download; Settings → General says what to do
  instead — get the new version from the repository and rebuild.
- The one-click updater, dormant until a notarized build exists, now checks
  WHO signed a download, not only that its signature is intact: the bundle
  must satisfy the running app's own designated requirement. Before this an
  ad-hoc re-signed bundle passed verification.
