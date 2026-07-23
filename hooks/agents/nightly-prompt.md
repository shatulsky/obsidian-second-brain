Read _CLAUDE.md. This is a sleeptime consolidation pass — the vault should be smarter when the user wakes up.

Phase 1 — Close the day:
- Read today's daily note. Append a ## End of Day section with a 3-5 bullet summary.
- Move any completed kanban tasks to Done.

Phase 2 — Reconcile:
- Scan wiki/entities/ for outdated roles, companies, or descriptions that conflict with newer daily notes.
- Scan wiki/concepts/ for claims contradicted by recently ingested sources.
- Auto-resolve clear winners. Flag ambiguous ones in wiki/decisions/.

Phase 3 — Synthesize:
- Scan sources ingested today and yesterday. Find concepts that appear in 2+ unrelated sources.
- If patterns found: create wiki/concepts/Synthesis — Title.md with evidence and interpretation.

Phase 4 — Heal:
- Find notes created today with no incoming links. Add links from relevant existing pages.
- Check if any entity pages reference old timeline entries without an "until" date that should be closed.
- Rebuild index.md to reflect today's changes.

Phase 5 — Log:
- Append to log.md: ## [YYYY-MM-DD] nightly | End of day + X reconciled, Y synthesized, Z orphans linked

Do not ask questions. Do not fix anything destructive — only add, update, link. Save and stop.
