<!-- What shipped, in prose. This becomes the annotation of the next
     release tag, which publish.sh ships as the GitHub release notes.
     The FIRST LINE is the tag's subject: make it a short title, then a
     blank line. This comment is stripped. -->
the model curves stay inside the window they belong to

Fixes
- Meter popover: a model's token curve no longer towers over the percent
  line for the first hours after a session window resets. The poll that
  lands on the window boundary still reports the previous window's
  percentage, and counting it as the new window's opening height priced
  every token several times too high — on the reporting Mac a 5h window
  sitting at 13% drew its busiest model near 100%. A window's samples are
  now picked by the reset they were stamped with, so the window before it
  can't lend it a height it never spent, and the same stale drop no longer
  reads as a mid-window reset that lifts the curves' ceiling.
- The "extra usage" estimate on a forecast past its limit is measured on
  the same samples, so the tokens and dollars it quotes match the curves
  the popover draws.
