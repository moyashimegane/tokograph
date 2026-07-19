# Claude Code transcript format — observed behavior

Observations verified 2026-07-18 against Claude Code 2.1.209 on a live dataset
(~116 files / ~159 MB / ~11,000 usage lines over 14 days). The format is
undocumented and these findings are not a contract: Tokograph detects and
surfaces deviations (diagnostics badge, `formatChanged` state) instead of
assuming them away.

## Where usage data lives

Claude Code writes one JSON object per line to
`<config-root>/projects/<encoded-project-dir>/<session-id>.jsonl`
(default retention 30 days, `cleanupPeriodDays`). The only usage-bearing
lines observed are `type: "assistant"` lines carrying:

- top-level `timestamp` (ISO-8601 UTC), `requestId`, `sessionId`,
  `isSidechain`, `version`
- `message.id`, `message.model`, and `message.usage` with `input_tokens`,
  `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`

## Why deduplication is required

About 62% of usage lines in the dataset were duplicates: resumed, forked,
and worktree-copied sessions re-write earlier lines into new files. A naive
sum overcounted roughly 2.4×.

Invariants the dedup design relies on, each verified over the full dataset:

- `message.id` is present on 100% of usage lines.
- No `message.id` maps to more than one `requestId` (0 violations), so
  `message.id` alone is a safe global dedup key.
- When the same `message.id` recurs with different usage values, the values
  only grow (streaming updates; 0 non-monotonic cases), so keeping the
  occurrence with the maximum total keeps the final state.

Occurrences that violate these invariants (different `model`, two different
`requestId`s, shrinking counts) are counted once and reported as collision
diagnostics, never merged silently.

## Rejected data sources and optimizations

- `~/.claude/stats-cache.json`: daily granularity only — cannot feed an
  hourly heatmap.
- mtime-based file pre-filtering: mtime is untrustworthy under copy,
  restore, and clock changes, and full re-reads measured fast enough that
  the optimization buys nothing.
