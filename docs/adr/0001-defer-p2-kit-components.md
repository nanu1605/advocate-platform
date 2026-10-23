# 0001 — Defer P2-only kit components to Phase 2

Status: accepted (founder, 23 Oct 2026)

## Context
Spec §17 Phase 0 task 4 asks for the full component kit (§5.11, 22 components) before feature work.
Five components are only used by features that ship in P2 or later: AIAnswerCard, SourceChip/CitationChip,
MicButton, VoiceConfirmSheet, ItemTracker.

## Decision
Phase 0 builds the 17 components P1 screens use, each with goldens (3 themes × en/hi × 1.0/2.0) and a
`/dev/kitchen-sink` entry. The five P2 components are built at the start of Phase 2, with the same golden matrix,
before any P2 feature screen.

## Consequences
- Faster P0; no rework if the AI/voice interaction design shifts after the P1 beta.
- The P0 exit criterion "kitchen-sink goldens pass" applies to the 17 built components.
- P2 plan must list these five as its first task.
