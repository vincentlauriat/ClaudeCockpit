# Contributing

Thanks for taking a look. This is a small, focused macOS app; the bar is simply that a change
builds, is covered where it can be, and reads like the code around it.

## Prerequisites

- macOS 14 Sonoma or later
- Xcode 15 or later (Swift 5.9)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

SwiftPM resolves the two dependencies for you: Sparkle 2.9.1+ and SQLite.swift 0.16+.

## Build and test

```bash
xcodegen generate
xcodebuild -project ClaudeCockpit.xcodeproj -scheme ClaudeCockpit \
           -configuration Debug CODE_SIGNING_ALLOWED=NO build

cd CockpitCore && swift test
```

`.xcodeproj` is not committed. `project.yml` is the source of truth, so run `xcodegen generate`
after every clone and after every edit to it. Always build before opening a pull request; never
assume a change compiles.

## Where code goes

Logic belongs in `CockpitCore`, the local SwiftPM package, and interface belongs in the
`ClaudeCockpit` app target. The package has no UI framework in it and builds without an
`NSApplication`, which is what keeps `swift test` fast. If a change needs to open a file, hit the
network or touch a database, it goes in a kit behind a service that returns an immutable
snapshot, not in a view.

## Tests

Tests live in `CockpitCore/Tests/<Kit>Tests/`, one suite per module, and run with `swift test`
from `CockpitCore`. There are no UI tests. Anything touching the filesystem runs against a
temporary `HOME` passed through `ClaudePaths`; anything touching the network sits behind
`TokenProviding` or `QuotaFetching` and gets a stub. Time-dependent logic takes an injected
clock. A new kit gets a new test target in `Package.swift`.

## Conventions

- **UI strings are French**, with full accents. Code identifiers, comments, commit messages and
  documentation are English.
- **Conventional commits**, short and in the present tense: `add`, `fix`, `update`.
- Documentation comes in pairs: `ARCHITECTURE_EN.md` is the source of truth and `ARCHITECTURE.md`
  is its exact French mirror. Edit both in the same commit.
- Fix root causes. Do not add logging around a bug or silence a warning to make it go away.

## Pull requests

Work on a feature branch and open a pull request against `main`. Never push to `main` directly.
Say what changed and why, and mention anything you could not verify. If a change touches the
release pipeline, the Sparkle configuration or `project.yml`, say so explicitly in the
description.

One thing is off-limits: the Sparkle EdDSA key. Never run `generate_keys` for the account
`ClaudeCockpit` and never change `SUPublicEDKey` in `project.yml`. Every installed copy would
reject every future update, permanently.
