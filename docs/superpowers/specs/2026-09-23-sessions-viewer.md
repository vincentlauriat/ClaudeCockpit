# Sessions viewer — design spec (v1.1.0)

Date: 2026-09-23. Scope decided by Vincent: everything agentsview does for **Claude Code
sessions**, natively, offline, inside Claude Cockpit. No other agents, no daemon, no REST/MCP,
no remote sync, no LLM-backed features.

## Goal

A new **Sessions** section that lets you see *everything that happened in every session*:
the full transcript (user and assistant turns, tool calls with their input and output,
diffs, thinking, sub-agents, compaction boundaries), the cost and tokens per turn, plus a
browser to find sessions (grouping, filters, full-text search, stars), resume them, export
them, and local analytics derived from the archive (activity heatmap, tool mix, recently
edited files, session health).

## Data source (verified on Vincent's machine, 2026-09-23)

`~/.claude/projects/<encoded cwd>/<sessionId>.jsonl` plus `…/subagents/agent-<id>.jsonl`.
Line `type`s seen: `user`, `assistant`, `system` (subtypes incl. `stop_hook_summary`,
compaction with `compactMetadata`), `attachment`, `ai-title`, `pr-link`, `cost-state`,
`file-history-snapshot`/`-delta`, `queue-operation`, `last-prompt`, `mode`,
`permission-mode`, `atis-latch`. Content blocks: `text`, `thinking`, `tool_use`,
`tool_result`, `image`, `server_tool_use`, `advisor_tool_result` (redacted). Flags:
`isSidechain`, `isMeta`, `isCompactSummary`, `isApiErrorMessage`, `isAbortedMidStream`,
`interruptedMessageId`. Per-line metadata: `uuid`, `parentUuid`, `timestamp`, `cwd`,
`gitBranch`, `version`, `sessionId`, `message.model`, `message.usage.*`,
`attributionSkill`, `attributionAgent`, `toolUseResult` (structured result on the user
line that carries a `tool_result`).

Corpus today: see `du` in PLAN notes (≈1k transcripts). Sessions can exceed 50 MB, so the
viewer must page messages and must not hold every session in memory.

## Architecture

New SPM target **`SessionsKit`** (deps: `CockpitShared`, `SQLite.swift`), same pattern as the
other kits: actor service, immutable `Sendable` snapshots, tests on fixtures.

### Storage: `sessions.db` (SQLite, in `~/Library/Application Support/ClaudeCockpit/`)

Why SQLite: FTS5 search across all messages and tool output, lazy paging of huge sessions,
and derived feeds (recent edits, heatmap) as plain queries. macOS' system SQLite ships FTS5.

Tables (all keyed by stable ids, rebuildable from the transcripts at any time):

- `files(path PK, session_id, is_subagent, offset, mtime, size)` — incremental resume state.
- `sessions(id PK, project_dir, cwd, slug, ai_title, custom_name, git_branch, cc_version,
  first_ts, last_ts, user_turns, assistant_turns, tool_calls, tool_errors, input_tokens,
  output_tokens, cache_read, cache_create, cost_state_usd, lines_added, lines_removed,
  parent_session_id, starred, deleted_at)`.
- `messages(uuid PK, session_id, parent_uuid, seq, ts, role[user|assistant|system],
  is_sidechain, is_meta, is_compact_boundary, is_api_error, model, input_tokens,
  output_tokens, cache_read, cache_create, text_preview)`.
- `blocks(id PK, message_uuid, idx, kind[text|thinking|tool_use|tool_result|image],
  tool_name, tool_use_id, is_error, body TEXT, meta JSON)` — `body` holds text, thinking,
  tool input (pretty JSON) or tool output; images store only media type + byte size.
- `edits(id PK, session_id, message_uuid, ts, tool[Edit|Write|MultiEdit|NotebookEdit],
  path, lines_added, lines_removed)` — from `tool_use` inputs of file tools.
- `pr_links(session_id, number, url, repo, ts)`.
- `subagents(agent_id PK, session_id, parent_tool_use_id, file_path)` — link a
  `subagents/agent-*.jsonl` to the `Agent` tool call that spawned it (matched by agent id
  found in the tool result / `toolUseResult`).
- `messages_fts` (FTS5, content = messages text + tool bodies, tokenizer unicode61).

### Services

- `TranscriptParser` (pure, tested): `Data` line → `ParsedLine` enum.
- `SessionIndexer` actor: walks the tree incrementally (offset/mtime/size like UsageKit),
  parses appended lines, upserts rows in one transaction per file, updates session
  aggregates and FTS. First index of ≈1 GB must stay under a few minutes and never block the
  UI (runs on a detached task, progress published).
- `SessionStore` (read side): `listSessions(filter:)`, `session(id:)`,
  `messages(sessionId:, page:)`, `search(query:, filter:)` (FTS5 with snippets),
  `recentEdits(limit:)`, `activity(range:)` (hour × weekday counts, per-day cost),
  `toolMix(range:)`, `health(sessionId:)`.
- `SessionHealth` (pure heuristics, no LLM): grade A–F from tool error ratio, API errors,
  aborted/interrupted turns, repeated identical tool failures, session ended on an error.
  Evidence list returned with the grade.
- `SessionExporter`: Markdown and self-contained HTML of one session (tool calls collapsed
  with `<details>`).
- `SessionActions` (app side): resume in Terminal (`claude --resume <id>` run in the
  session's cwd, via `open -a Terminal` + a temp `.command` script), reveal transcript in
  Finder, copy id, star, rename, hide (soft delete, transcripts are never touched).
- Live follow: `DirectoryWatcher` on `~/.claude/projects` → indexer tick (debounced 1 s) →
  store publishes "session X changed"; an open session auto-appends and shows a "live"
  badge when its file changed within the last 2 minutes.

## UI

Sidebar: **Sessions** added to "Tableau de bord" between Usage local and Quotas.

Section layout: left column (list) + detail, with a segmented header
**Sessions · Activité · Fichiers modifiés**.

**List**: search field (FTS5, `Cmd+K` focuses it), filter chips (project, période, étoilées,
avec erreurs, sous-agents masqués), grouping by day (default) or project, each row: title
(ai-title → custom name → first prompt), project short path, time, duration, turns, cost,
health badge, live dot. Keyboard `j`/`k`.

**Detail**: header (title editable, project, branch, Claude Code version, started/duration,
tokens in/out/cache, cost, health grade with evidence popover, PR links), toolbar (star,
resume in Terminal, reveal, export ▾, copy id). Body: LazyVStack of turns:
- user turn: text (markdown-lite), attachments count;
- assistant turn: text; `thinking` collapsed block; each `tool_use` as a collapsible card
  (tool icon + name + key argument tag, e.g. the command or the file path; expanded shows
  input and the paired `tool_result` output, each independently collapsible, output capped
  with "afficher tout"); `Edit`/`Write` show a coloured diff (old/new for Edit, full new
  content for Write); `Agent` cards expand the sub-agent transcript inline; errors in red;
- per-turn footer: model, tokens, cost, elapsed;
- compaction divider ("Contexte compacté") on `isCompactSummary`/compact system lines;
- in-session find bar (`Cmd+F`) with match count and `[`/`]` navigation;
- `isMeta`/hook/attachment lines hidden by default, toggle "Afficher les lignes système".

**Activité**: range picker (jour/semaine/mois/personnalisé), heatmap hour × weekday of
assistant turns, per-day cost bars, tool mix (top tools by calls, error rate), models mix,
totals (sessions, turns, tool calls, cost).

**Fichiers modifiés**: feed of edited files across sessions grouped by project → path,
newest first, each expands to the edits (tool, session, time) and jumps to the message.

Overview card: "Sessions aujourd'hui" (count, last active title, cost).

Settings: toggle "Indexer les transcripts pour la section Sessions" (default on),
"Reconstruire l'index", index size + last run.

## Non-goals (explicitly out)

Other agents' transcripts, daemon/REST/MCP, Postgres/ClickHouse/DuckDB, semantic search,
chat imports, Recall/LLM insights, Gist publishing, multi-machine sync, secret scanning.

## Testing

Fixtures: hand-written JSONL sessions covering text/thinking/tool pairs, an Edit diff, an
Agent call with its subagent file, a compaction boundary, an API error, and a truncated
tail. Tests: parser (every line kind), indexer (incremental, resume, dedupe), store queries
(list filters, FTS snippets, recent edits, heatmap buckets), health grades, exporters.

## Release

Ships as **1.1.0** with the standard pipeline (bump `project.yml`, notes, release.sh,
gh release, appcast PR, lauriat.fr).
