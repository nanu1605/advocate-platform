# 0004 — Rich-text editor for drafting: flutter_quill (provisional) — spike 11a

Status: accepted, provisional — the Windows IME check below must pass before Phase 4 starts.

## Context
Spike 11a compares appflowy_editor (used under MPL-2.0) with flutter_quill for P4 drafting: tables, numbered
paragraphs, Devanagari input (Windows IME + mobile keyboards), DOCX round-trip. Run on 24 Oct 2026, Flutter 3.47.7.
Spike code: `docs/spikes/11a-11f-flutter/`.

## Findings
| | appflowy_editor 6.2.0 (Dec 2025) | flutter_quill 11.6.0 (Sep 2026) |
|---|---|---|
| Builds on Flutter 3.47 | **No** — `DeltaTextInputService` misses the new `TextInputClient.onFocusReceived` | Yes |
| Devanagari render (Mukta) | — | Correct shaping in widget test |
| Numbered paragraphs | — | Yes (ordered list attribute) |
| Tables | Plugin exists | Not in core |
| DOCX import/export | None | None |
| Licence | MPL-2.0 / AGPL-3.0 dual | MIT |
| Maintenance | No release for 10 months | Active |

## Decision
Use **flutter_quill**. Drafts are generated section by section (spec §12.10), so tables that drafts need — the
List of Dates chronology (F26) and annexure indexes — are structured blocks stored next to the Quill
document and rendered by docxtpl at export, not edited as free-form tables inside the editor. DOCX export runs on the
backend (Delta JSON → python-docx/docxtpl); DOCX import is not needed because templates are ours.

## Still open (blocks P4, not P1)
- Devanagari typing through the Windows IME (Hindi Traditional / Inscript / Google Input Tools) and Android/iOS
  keyboards in a real build. Needs Windows Developer Mode to build plugins on the founder's machine.
- If the IME check fails, fall back to a plain multiline `TextField` per section plus our own numbering.
