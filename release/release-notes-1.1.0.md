## Claude Cockpit 1.1.0

**Sessions** — a fifth instrument. Claude Cockpit now reads back everything that happened in
every Claude Code session on your Mac, not just how many tokens it cost.

### Sessions
- **Browser** over every transcript under `~/.claude/projects`, grouped by day or by project,
  with filters (projet, période, étoilées, avec erreurs, sous-agents) and keyboard navigation.
- **Full-text search** across message text, tool inputs and tool outputs, with snippets.
  Very long tool outputs are indexed up to their first 8 KB: beyond that the text is still
  readable in the transcript, but it will not match a search.
- **Transcript detail**: user and assistant turns, collapsible tool calls showing their input
  and their result, coloured diffs for file edits, thinking blocks, sub-agent transcripts
  expanded inline, compaction dividers, and per-turn model, tokens and cost.
- **Health grade** per session, computed from error *rates* rather than raw counts, so it
  reflects how a session went instead of how long it ran. The evidence behind every grade is
  shown.
- **Actions**: star, rename, hide, reveal the transcript in the Finder, export to Markdown or
  HTML, and resume in the Terminal.
- **In-session find** with match count and navigation.

### Activité
Hour-by-weekday heatmap, cost per day, tool mix with error rates, and model mix, over the
range and project you choose.

### Fichiers modifiés
The files your agents edited most recently across every session, grouped by project and path,
with the lines added and removed.

### Under the hood
- A local SQLite index with FTS5, built incrementally by byte offset and followed live through
  recursive file-system events. About 206 MB for a 912 MB archive, a full index in about 20 s,
  an incremental pass in 0.16 s, and a page of 400 messages out of a 33 MB transcript in 7 ms.
- Block bodies are capped in the index and re-read from the transcript on demand, so the index
  stays small without ever truncating what you see.
- Sub-agent transcripts are indexed as sessions of their own and hidden from the list by
  default; 96.5% are linked back to the call that spawned them.
- Cost is estimated from per-model tokens using the pricing you set, so it is available for
  the 980 sessions Claude Code never wrote a cost line for, not just the 106 it did.

### Privacy
Unchanged: everything is read locally, `~/.claude` is never written to, and the only network
calls remain Anthropic's usage endpoint and the update feed. Attachment payloads are counted,
never stored.

Requires macOS 14 or later. Signed with a Developer ID, notarized and stapled.
