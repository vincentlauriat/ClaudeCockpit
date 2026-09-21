# CLAUDE.md — Claude Cockpit

Native macOS app (Swift 5.9, SwiftUI + AppKit shell, macOS 14+) merging ClaudeCodeUsage, ClaudeMenu, RTKInfos and SkillManager. Spec: `docs/superpowers/specs/2026-09-21-claude-cockpit-design.md`. Architecture source of truth: `ARCHITECTURE_EN.md` (FR mirror `ARCHITECTURE.md`).

## Build
```bash
xcodegen generate
xcodebuild -project ClaudeCockpit.xcodeproj -scheme ClaudeCockpit -configuration Debug build CODE_SIGNING_ALLOWED=NO
cd CockpitCore && swift test          # core modules, no NSApplication needed
```

## Layout
- `ClaudeCockpit/` app target: UI only (`App/`, `Store/`, `MenuBar/`, `Window/`, `Theme/`, `Resources/`).
- `CockpitCore/` local SPM package: `CockpitShared`, `UsageKit`, `QuotaKit`, `RTKKit`, `SkillsKit` + tests.
- `Scripts/release.sh <version>`: sign, notarize, staple, DMG, Sparkle sign, appcast.

## Rules
- UI strings in French; code, commits, docs in English. Conventional commits.
- Never regenerate the Sparkle key (keychain account `ClaudeCockpit`).
- All file access to `~/.claude` is read-only except SkillsKit transfers, which back up first into `~/.claude/backups/`.
- Release artefacts go to `release/`.
