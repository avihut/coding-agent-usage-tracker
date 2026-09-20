<!-- What shipped, in prose. This becomes the annotation of the next
     release tag, which publish.sh ships as the GitHub release notes. -->

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
