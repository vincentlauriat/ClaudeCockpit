## Claude Cockpit 1.1.2

### Fixed
- **User turns no longer claim attachments you never made.** Every `attachment`
  line in a transcript was counted, whatever it carried. A census of ~128,000
  such lines found that 99.75% are Claude Code's own plumbing: hook output,
  token reminders, the environment, the date, the skill listing.

  On a 1,035-session archive that produced **28,679 user bubbles whose only
  content was a phantom "1 pièce jointe"**, plus 2,954 real prompts carrying a
  false one. Both are now zero.

  Only genuine file attachments count, and a file restored by a compaction is
  recognised as re-injected context rather than something you attached. When you
  do attach a file, its **name** is shown instead of a bare count.

This release re-indexes your transcripts once on first launch; the transcripts
themselves are never written to.
