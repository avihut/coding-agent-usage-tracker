<!-- What shipped, in prose. This becomes the annotation of the next
     release tag, which publish.sh ships as the GitHub release notes.
     The FIRST LINE is the tag's subject: make it a short title, then a
     blank line. This comment is stripped. -->
a main window of its own

New
- A window of its own: the menu bar panel, given room. Open it from the
  panel's window button, ⌘0, the Dock or Spotlight, or by launching the
  app yourself (a launch at login still stays in the menu bar). The
  sidebar lists your accounts by agent; an account's page shows its
  limits beside the selected limit's chart, then its activity and
  sessions. Choosing an account there doesn't change what the menu bar
  shows — the toolbar's menu does that.
- The window's Home shows every account at once, each one's limits lined
  up by kind — every weekly limit in one column, whichever agent it
  belongs to — with the menu bar account's activity and sessions below.
  Click a limit to open that account on it.

Fixes
- An open Sessions or Settings window stays open when the menu bar's focus
  moves to another harness's account. Clicking a Codex cell while reading
  Claude Code's sessions used to close the window under you.
- The app looks like a macOS 26 app on macOS 26 and later — Liquid Glass
  toolbars, controls and popovers. Every build was linked as if against the
  macOS 15 SDK, whatever built it, so macOS drew it in the old look.
