# Claude Cockpit — Design Spec

Date: 2026-09-21
Status: approved by Vincent (chat), autonomous execution mandate through the v1.0.0 Sparkle release.

## 1. Purpose

Claude Cockpit is a single native macOS app that merges four existing tools:

| Source | What it brings | Reuse strategy |
|---|---|---|
| ClaudeCodeUsage v1.3.1 | Local usage dashboard from `~/.claude/projects/**/*.jsonl`: tokens, cost, per model / project / agent / skill, daily chart, editable pricing | Port Swift code into `UsageKit` |
| ClaudeMenu v1.0.0 | Menu-bar panel: Anthropic Pro/Max quotas via OAuth usage API, pace projection, daily budget, RTK savings | Port Swift code into `QuotaKit` + menu-bar panel |
| RTKInfos v1.2.0 | Token savings from rtk's SQLite `history.db`: today / 7 days / all time / by command, live trace | Port `RTKCore` into `RTKKit` |
| SkillManager (Node/React) | Skills, agents, commands on three levels (Library / Global / Project), transfer between levels, plugin import | Rewrite natively in Swift as `SkillsKit` (skills, agents, commands only in v1) |

Everything is read-only against the user's data except the skills domain, which copies/moves files with a prior backup.

## 2. Decisions (Vincent, 2026-09-21)

- Form factor: **hybrid** — menu-bar item with a compact panel, plus a full main window. Optional "menu bar only" mode (no Dock icon).
- Skills scope for v1: **skills, agents and commands**, native Swift. No hooks, MCP, CLAUDE.md editor or memory editor.
- Name: **Claude Cockpit**. Product name `ClaudeCockpit`, bundle id `fr.vincentlauriat.claudecockpit`, GitHub repo `vincentlauriat/ClaudeCockpit`.
- UI language: French. Code, commits and docs: English.
- Sparkle: dedicated EdDSA key for this app (keychain account `ClaudeCockpit`, private half backed up in `~/Documents/SparkleKeys/`). Same pattern as ClaudeMenu.
- Release: `Scripts/release.sh` adapted from ClaudeMenu's (sign, notarize, staple, DMG with Finder layout, EdDSA sign, appcast). DMG in `release/`.

## 3. Architecture

```
ClaudeCockpit/                      ← xcodegen root (project.yml)
├── ClaudeCockpit/                  ← app target (UI + AppKit shell only)
│   ├── App/        CockpitApp.swift, AppDelegate.swift, UpdaterController.swift
│   ├── Store/      CockpitStore.swift (@MainActor @Observable hub), Settings.swift
│   ├── MenuBar/    MenuBarPanelView.swift (+ cards)
│   ├── Window/     MainWindowView.swift, Sidebar, sections/*
│   ├── Theme/      Theme.swift (tokens), components
│   └── Resources/  Assets.xcassets, Info.plist, entitlements
├── CockpitCore/                    ← local SPM package
│   ├── Package.swift
│   ├── Sources/CockpitShared/      FR formatters, ClaudePaths, DirectoryWatcher, Frontmatter
│   ├── Sources/UsageKit/           transcript scanner, pricing, insights, UsageSnapshot
│   ├── Sources/QuotaKit/           credentials, usage API client, pace math, GaugeSnapshot
│   ├── Sources/RTKKit/             SQLite repository, DB watcher, RTKSnapshot
│   ├── Sources/SkillsKit/          resource model, three-level store, transfer, plugin import
│   └── Tests/<Kit>Tests/           XCTest with fixtures (no NSApplication)
├── Scripts/                        release.sh, make-app-icon.swift, make-dmg-background.swift
├── docs/                           landing page (GitHub Pages), specs
├── appcast.xml
└── README.md, ARCHITECTURE_EN.md, ARCHITECTURE.md, CHANGES.md, ...
```

Dependencies: Sparkle ≥ 2.9.1 (app target), SQLite.swift ≥ 0.16 (RTKKit). macOS 14+, Swift 5.9, no App Sandbox (needs `~/.claude`, keychain, rtk DB).

### 3.1 Package module contracts

Each kit exposes one **service** (actor or `Sendable` class) producing an immutable **snapshot** struct. The app never touches files or network directly.

**CockpitShared**
- `ClaudePaths`: `home`, `claudeDir` (`~/.claude`), `projectsDir`, `credentialsFile`, `skillsDir`, `agentsDir`, `commandsDir`, `libraryDir` (`~/.claude/skillmanager/library`), `pluginsCacheDir`, `backupsDir`, `appSupportDir` (`~/Library/Application Support/ClaudeCockpit`).
- `FRFormat`: tokens (`12,3 k`, `1,2 M`), currency EUR/USD, percent, durations, relative dates, day labels. Pure functions.
- `DirectoryWatcher`: DispatchSource-based recursive-ish watcher emitting `AsyncStream<Void>` (debounced).
- `Frontmatter`: parse YAML-ish `---` header of markdown (name, description, plus raw dictionary).

**UsageKit** (port of ClaudeCodeUsage `Models/Services`)
- `UsageEvent`, `ModelFamily`, `ModelPricing`, `PricingSettings` (Codable, persisted by the app), `PricingCalculator`, `InsightEngine`, `BreakdownDimension`.
- `TranscriptScanner`: incremental scan with cache file in `appSupportDir/scan-cache.json`.
- `UsageSnapshot`: events + precomputed aggregates for a `UsageRange` and filters (models, project): totals, per-day series, per-model-family cost, per-project / agent / skill breakdown, sessions list.
- `UsageService` actor: `func refresh() async throws -> [UsageEvent]`; aggregation is a pure function `UsageAggregator.snapshot(events:range:filters:pricing:)`.

**QuotaKit** (port of ClaudeMenu `Services`)
- `CredentialStore` (keychain `Claude Code-credentials` via `/usr/bin/security`, fallback `~/.claude/.credentials.json`), `QuotaAPI` (GET `https://api.anthropic.com/api/oauth/usage`), `Meter`, `GaugeSnapshot`, `PaceProjection`, `UsageMath`.
- `QuotaService` actor: `func refresh(force: Bool) async throws -> GaugeSnapshot`; enforces 3-min minimum spacing, backoff 15 min after 429. Token kept in memory only.

**RTKKit** (port of RTKInfos `RTKCore`)
- `TrackingRepository` (read-only SQLite, one connection per query, schema validation), `DBWatcher` (FSEvents), `CommandRecord`, `RTKSnapshot` (today, last 7 days series, all-time, by command, recent trace).
- `RTKService`: `func snapshot() throws -> RTKSnapshot`, `var changes: AsyncStream<Void>`. Path resolution: `~/Library/Application Support/rtk/history.db`, then `~/.local/share/rtk/history.db`, overridable.

**SkillsKit** (new)
- `ResourceKind { skill, agent, command }`, `ResourceLevel { library, global, project(ProjectRef) }`, `ProjectRef { name, path }`.
- `ClaudeResource { id, kind, name, level, url, description, frontmatter, modifiedAt }`. Skills are directories with `SKILL.md`; agents and commands are single `.md` files.
- `PluginResource { plugin, org, version, name, url }` read-only from `~/.claude/plugins/cache/<org>/<plugin>/<version>/skills/*`.
- `ProjectScanner`: given roots (default `~/DevApps`, `~/Documents/GitHub`), depth ≤ 3, returns projects owning a `.claude/` directory.
- `ResourceStore` actor: `inventory(projects:) -> SkillsInventory`, `read(_:) -> String`, `transfer(_:to:mode: .copy|.move) throws`, `importPlugin(_:to:) throws`, `delete(_:) throws`. Every mutation first copies the affected files to `backupsDir/<ISO timestamp>/`. Names sanitized `[^A-Za-z0-9_-] → -`. Refuses paths outside `$HOME`.

### 3.2 App layer

- `CockpitStore` (`@MainActor @Observable`): one `SourceState` + snapshot per source (`usage`, `quota`, `rtk`, `skills`). `enum SourceState { idle, loading, ready(Date), failed(String) }`. Independent refresh loops: usage 30 s (off main thread), quota 3 min with backoff, rtk on DB change + 30 s fallback, skills on directory change + manual. Timers scheduled in `.common` run-loop mode (ClaudeMenu gotcha).
- `Settings` (`@AppStorage`): `launchAtLogin`, `menuBarOnly`, `usageRefreshSeconds`, `rtkDBPath`, `projectRoots`, `pricingJSON`, `currency`, section collapse states.
- `AppDelegate`: activation policy `.accessory` when `menuBarOnly`, else `.regular`; raises to `.regular` temporarily for Sparkle dialogs; "Check for Updates…" in the app menu; `SMAppService` for login item.

### 3.3 UI

**Menu bar** (`MenuBarExtra(.window)`, 340 pt): label = weekly quota percent. Panel: quota hero (weekly %, reset countdown, segmented bar, pace sentence) → daily budget card → "Aujourd'hui" strip (local cost today, tokens today, RTK tokens saved today) → footer buttons: Ouvrir le cockpit, Rafraîchir, Réglages, Quitter. Sections collapsible, states persisted.

**Main window** (`NavigationSplitView`, min 1060×700), sidebar sections:
1. Vue d'ensemble — 4 hero tiles (quota semaine, coût du jour, tokens économisés RTK 7 j, skills actifs) + insights list + quick chart.
2. Usage local — port of the ClaudeCodeUsage dashboard (filters, stat grid, cards, daily chart, breakdown table, sessions list + detail).
3. Quotas — port of the ClaudeMenu limits section at full width (per-model meters, sustainable pace, tokens consumed).
4. RTK — port of the RTKInfos dashboard (compression gauge, today strip, 7-day chart, all-time tiles, by-command bars, live trace).
5. Skills / 6. Agents / 7. Commandes — same layout: level picker (Library / Global / Projet ▾), searchable list, detail pane with rendered markdown, actions: Copier vers…, Déplacer vers…, Importer depuis un plugin, Révéler dans le Finder, Supprimer (confirmation).
8. Réglages — general (login item, menu-bar only, refresh), pricing editor, RTK DB path, project roots, updates.

Theme: dark-first, warm accent (Claude orange `#D97757`) + emerald for RTK savings, system font + monospaced digits. Light mode supported through semantic colors.

### 3.4 Error handling

Every source is independent; a failing source shows an inline banner in its section and in the panel, never blocks others. Network errors from the quota API keep the last snapshot with "données du <time>". Missing rtk DB → RTK section shows an install hint. Missing credentials → quota section explains how to log in with Claude Code. Skills mutations are all-or-nothing per operation, and the backup path is shown in the confirmation toast.

### 3.5 Testing

XCTest on `CockpitCore` only (`swift test`): transcript fixtures (JSONL), pricing math, pace math, RTK repository against a fixture `history.db` built in a temp dir, SkillsKit inventory/transfer/backup in a temp `HOME`. No UI tests.

## 4. Release pipeline

`Scripts/release.sh <version>`: xcodegen → `xcodebuild` Release with `CODE_SIGNING_ALLOWED=NO` → ditto staging → codesign Sparkle nested binaries then app (`--options runtime --timestamp`, retry ×5) → DMG with background + Applications alias → notarize with profile `AppliMacVincentGithub` → staple → `sign_update --account ClaudeCockpit` → write `appcast.xml` (`sparkle:version` = CFBundleVersion = git commit count) → print `gh release create` command.

Feed URL: `https://raw.githubusercontent.com/vincentlauriat/ClaudeCockpit/main/appcast.xml`.

## 5. Publication

- Public GitHub repo `vincentlauriat/ClaudeCockpit`, MIT license, GitHub Pages from `docs/`.
- Landing page `docs/index.html` (trilingual EN/FR/zh-Hant like the sibling apps), screenshots in `docs/screenshots/`.
- Reference on `vincentlauriat.github.io` (sticker + manifest row) and `lauriat.fr` (tools section, `outils/claudecockpit/`, `llms.txt`, sitemap), following the ClaudeMenu precedent of 2026-09-21.
- App icon: generated by `Scripts/make-app-icon.swift` (CoreGraphics): dark rounded square, warm gradient, cockpit gauge arc with needle, subtle glow.

## 6. Out of scope (v1)

Hooks, MCP servers, CLAUDE.md editing, memory editing, iOS target, localisation beyond French UI, in-app markdown editing of skills.
