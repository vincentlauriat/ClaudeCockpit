## Claude Cockpit 1.1.1

### Added
- **The menu bar percentage is now a choice.** It was hard-wired to the 7-day
  window; Settings now offers the 5-hour session, the 7-day window, or both
  (`17 % · 15 %`, session first). The two answer different questions: the
  session says whether you can keep working right now, the week says whether
  the week holds.

A dash still stands for "not fetched yet" in every mode, and is never rendered
as `0 %`.

### Unchanged
Everything else is identical to 1.1.0, including the Sessions viewer and its
local index. `~/.claude` is still only ever opened for reading.
