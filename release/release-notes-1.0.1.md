## Claude Cockpit 1.0.1

Maintenance release: the Quotas screens no longer mistake Anthropic's undocumented quota buckets for models.

### Fixed
- **Quotas** — the usage endpoint reports opaque buckets (`nimbus_quill`, …) next to the documented `five_hour`, `seven_day` and `seven_day_<model>` meters. They were displayed as "Modèle Nimbus Quill (7 jours)". They now live in a collapsed **Autres compartiments** card in the Quotas screen, labelled "Compartiment Nimbus Quill / API" with the raw API key and a one-line explanation, and as a single summary row in the menu-bar panel. Only `seven_day_<model>` keys are shown as per-model limits.

### Docs
- Interactive architecture diagram (pan, zoom, guided views, source references verified against the repository), linked from the README, the architecture docs and the landing page: https://vincentlauriat.github.io/ClaudeCockpit/diagrams/claude-cockpit-architecture.html

### Under the hood
- Signed with a Developer ID, notarized and stapled; delivered to 1.0.0 users through Sparkle.
- macOS 14+, Apple Silicon and Intel.
