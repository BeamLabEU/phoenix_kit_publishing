# PR #36 — Follow-up (after-action)

Sixteen-commit boss-directed batch: Latest band + band styles + animations,
admin header/status/save work, per-language slug fix, group-name AI
translation, compact back links. Two review rounds ran before the PR; this
records what they found and what happened to each finding.

## Round 1 — Phase-2 quality sweep (4 triage agents + own docs pass)

| Finding | Severity | Outcome |
|---|---|---|
| Group editor imported unreleased `ai_multilang_tabs` — hard compile error against published phoenix_kit_ai 0.16.0 | CRITICAL | Fixed — forward-compat dodge (`ai_tabs/1`, function_exported? + apply per the document_creator/projects precedent). Standalone suite green against the Hex pin. Delete at floor bump (AGENTS.md TODO) |
| `GroupAITranslatable.put_translation` logged nothing, dropped the actor | HIGH | Fixed — `publishing.group.updated` (mode auto, actor from opts, locale-agnostic metadata) per merged language; pinned |
| Per-merge `:group_updated` broadcast → N full listing reloads per translation run | MEDIUM | Fixed by removal — matches sibling adapters; core's `:translation_completed` carries the signal |
| `broadcast_updated` bare rescue swallowed exceptions silently | MEDIUM | Moot — the broadcast (and its rescue) was removed |
| `fetch/2` error atom `:not_found` vs the behaviour's `:resource_not_found` | LOW | Fixed + test updated |
| Form-preview translation merge uncapped | NITPICK | Fixed — same cap as persist paths |
| Band markup duplication (img/link/ring/min-h stanzas ×2–3) | NITPICK | Fixed — `band_cover_media` (owns the img→scrim→link stacking), `band_ring_class/1`, `band_minh_class/1` |
| Admin preview footer diverged from the new public back link | (own pass) | Fixed — compact style, inert |
| AGENTS.md count/coverage drift (~21→~22, missing animations/adapter/classification/dodge docs) | (own pass + agent) | Fixed |
| Adapter rollback + audit untested; classification edge cases | MEDIUM | Fixed — vanished-group rollback, audit-row, never-published-with-stacked-drafts tests. The proposed archived-ACTIVE-version case was **rejected**: unreachable through app flows; pre-existing pointer semantics own it |
| Save-rescue path, timestamp-mode slug assertion, `hover:shadow` refute breadth, loose 30x assertions | LOW | Accepted as-is (hard to trigger / branch untouched / file convention), except the custom-slug test which round 2 tightened |

## Round 2 — Five-AI adversarial panel (codex/grok/zai repo-access, agy/vibe)

| Finding | Adjudication | Outcome |
|---|---|---|
| Admin row self-contradiction: date cell "Unsaved draft" + language pills over-claiming beside the Published badge | REAL (A1+A2) | Fixed — live version supplies the visible publish date (`effective_overrides/3`); pills read version-accurate `language_statuses`. Pinned |
| Switcher slug edge: base-code resolution over the full `language_slugs` map could pick a sibling/legacy dialect's slug | REAL (B) | Fixed — `build_translation_links` pins the map to the exact language |
| `split_newest` same-second tie nondeterminism | LIKELY (D) | Fixed — uuid tie-break |
| Custom-slug test accepted any 30x | test-quality (F) | Fixed — asserts the slug survives redirect/render |
| Manual save vs AI merge last-write-wins on the `name_i18n` set | LIKELY (C) | **Surfaced to the maintainer in the PR body** — same class as all group fields; wholesale-replace is what makes form deletions work |
| `target_lang` accepted as arbitrary binary by the AI pipeline | LIKELY (E) | **Surfaced in the PR body** — phoenix_kit_ai-side, affects every adapter |
| FOR UPDATE test is sequential (would pass without the lock) | test-quality | Accepted — true concurrency impractical under the SQL sandbox; noted here so the label isn't over-read |
| `@behaviour FormBinding` skipped on the params-map binding | OPINION (all 5) | Accepted — documented dialyzer trade-off; durable fix is generalizing the FormBinding spec upstream in phoenix_kit_ai |
| `listing_animations` default-on + wider `transition` scope = subtle visual change on upgrade | changelog note | In the PR body for the release notes |
| False alarms killed by verification | — | pagination double-count, stretched-link clickjacking, JSONB enum injection, nil-data crash, dodge drift, empty-list crash, status-dropdown no-op |

## Gates

`mix precommit` clean; **1237 tests / 0 failures** against BOTH the published
phoenix_kit_ai 0.16.0 (no overrides) and the local checkout; features
browser-verified in the parent app throughout the session.

## Open

None. The two maintainer questions (C, E above) are surfaced in the PR body,
not deferred silently.
