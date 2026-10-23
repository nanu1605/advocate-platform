# Phase 0 — Foundations: plan

Goal (spec §17): everything builds, signs in, looks right, is accessible and deploys before any feature work starts.

No founder accounts exist yet (23 Oct 2026), so work is split:
**Track A** needs nothing external and runs now; **Track B** waits for accounts and keys.

## Track A — local only

| # | Task | Main files |
|---|---|---|
| 0 | Toolchain: Flutter stable (S:\dev\flutter), MSVC/CMake/Win SDK, `just`, `uv`; pin versions | `PROJECT_STATE.md` |
| 1 | Repo scaffold, linters, pre-commit, `just` tasks, ADRs 0001/0002 | `justfile`, `pyproject.toml`, `.pre-commit-config.yaml`, `docs/adr/*` |
| 2 | Brand: `brand.json`, placeholder icon, `brand_sync.py`, Mukta fonts | `brand/*`, `tools/brand_sync.py`, `tools/make_placeholder_icon.py`, `apps/client/lib/core/brand/brand.g.dart` |
| 3 | Design tokens → ThemeExtensions (light/dark/sunlight), motion, reduce-motion, text scale; contrast check | `design/tokens.json`, `tools/check_contrast.py`, `apps/client/lib/core/theme/*` |
| 4 | Flutter app: Riverpod, go_router deep links, feature flags, en/hi ARB, P1 shell, Windows rail + Ctrl+K skeleton, Settings | `apps/client/lib/{app.dart,core/router,core/flags,core/l10n,features/*}` |
| 5 | Component kit (17 components, ADR 0001) + `/dev/kitchen-sink` + goldens | `apps/client/lib/ui/*`, `apps/client/test/golden/*` |
| 6 | Supabase local: P0 schema, triggers, `is_member`/`has_role`, RLS, pgTAP (5 actors), RLS-coverage check, plans seed | `supabase/migrations/*`, `supabase/tests/*`, `supabase/seed/*` |
| 7 | FastAPI skeleton: health, JWT (JWKS), run-as-user sessions, org context, error shape, rate limit, idempotency, P0 endpoints; Celery + beat; compose | `services/api/*`, `services/workers/*`, `packages/shared/*`, `infra/docker/compose.yml` |
| 8 | `legal_ai.llm` guard: refuse non-India profiles, strip sampling params | `packages/legal_ai/*` |
| 9 | App auth: phone → OTP (local test numbers) → consent → app lock → device registration; Send-SMS hook stub | `apps/client/lib/features/onboarding/*`, `services/api/.../auth_hook.py` |
| 10 | CI: Dart + Python lint/test, goldens, contrast, pgTAP, Android + Windows builds | `.github/workflows/*` |
| 11 | Local spikes 11a (editor), 11f (pdfrx), 11g (Devanagari PDFs) → ADRs | `docs/adr/*`, `docs/spikes/*` |

## Track B — waits for founder accounts

| # | Task | Blocked on |
|---|---|---|
| 12 | Supabase staging (Mumbai) + Send-SMS hook to WhatsApp/DLT | Supabase Pro, Meta verification / DLT |
| 13 | PowerSync dev: org-bucketed table e2e on 3 platforms; spike 11b; ADRs (Streams vs Rules, India hosting) | PowerSync account |
| 14 | Terraform staging, Sentry, Codemagic → TestFlight, Partner Center identity | AWS, Apple, Codemagic, Sentry, Partner Center |
| 15 | Spikes 11c (Bedrock India), 11d (Sarvam STT), 11e (eCourtsIndia fixtures) | AWS Bedrock, Sarvam, eCourtsIndia keys, 20 CNRs, 10 voice notes |

## Exit criteria (spec §17)
See spec §17 Phase 0. Track A alone cannot close the gate: TestFlight, staging Terraform, PowerSync e2e and
spikes 11b–e need Track B.
