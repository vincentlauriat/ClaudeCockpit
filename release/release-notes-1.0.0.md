## Claude Cockpit 1.0.0

The cockpit for Claude Code on macOS — one native app that merges **ClaudeCodeUsage**, **ClaudeMenu**, **RTKInfos** and **SkillManager**.

### Menu-bar panel
- Weekly Anthropic quota in the menu bar, with the pace that gets you to the reset and a daily budget
- 5-hour session and per-model limits, tokens spent today, RTK tokens saved today

### Main window
- **Vue d'ensemble** — quota, cost of the day, RTK savings over 7 days, active skills, insights
- **Usage local** — sessions, turns, input/output/cache tokens and estimated cost from your `~/.claude/projects` transcripts, filtered by model, project and period; daily chart; breakdown by project, agent and skill; sessions list with detail
- **Quotas** — every Anthropic meter with reset time, current and sustainable rates, projection
- **RTK** — token savings read from rtk's `history.db` (read-only): today, 7 days, all-time, by command, live trace
- **Skills / Agents / Commandes** — three levels (Library, Global, Project), copy or move between levels, import from the plugin cache, reveal in Finder, delete — every change is backed up first in `~/.claude/backups`
- **Réglages** — launch at login, menu-bar-only mode, refresh interval, currency, editable pricing, rtk DB path, project roots

### Under the hood
- Signed with a Developer ID, notarized and stapled; Sparkle auto-update
- No telemetry: the only network calls are Anthropic's usage endpoint (with the Claude Code OAuth token already on your Mac, kept in memory) and the update feed
- macOS 14+, Apple Silicon and Intel

Landing page: https://vincentlauriat.github.io/ClaudeCockpit/
