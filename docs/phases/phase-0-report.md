# Phase 0 — Foundations: interim report (Track A)

Date: 24 Oct 2026. The gate is **not** reached: Track B needs founder accounts. This report covers Track A.

## Exit criteria (spec §17 Phase 0)

| Criterion | Status | Evidence |
|---|---|---|
| Runs on Android, iOS (TestFlight internal), Windows; sign-in + app lock work | **Partial** | Sign-in, consent and lock flow pass a widget test end to end in Hindi; phone OTP works against local Supabase. Builds blocked locally: Windows needs Developer Mode, Android needs SDK licences, iOS needs Codemagic (Track B). Android and Windows debug builds pass in CI |
| Kitchen-sink goldens pass in every theme × language × text scale | **Pass** | 180 goldens, stable on re-run (`just goldens`) |
| Contrast check passes in CI | **Pass** | `tools/check_contrast.py`: 0 failures, locally and in the CI backend job |
| RLS tests pass, incl. API-as-user isolation | **Pass** | 300 pgTAP assertions; `test_org_isolation`, device hijack → 403 |
| `LLMClient` refuses non-India profiles | **Pass** | `packages/legal_ai/tests/test_llm.py` |
| CI green | **Pass** | All 5 jobs green on `main` (backend, Flutter, Windows goldens, Android build, Windows build) |
| Staging deployed by Terraform | **Not started** | Needs AWS account (Track B) |
| Offline edit syncs after reconnect on 3 platforms | **Not started** | Needs PowerSync (Track B) |
| All seven spike ADRs written; provider fixtures recorded | **3 of 7** | 11a → ADR 0004, 11f → ADR 0005 (host part), 11g → ADR 0006. 11b–e need accounts/keys |

## Test totals (local, 24 Oct 2026)
- pgTAP: 300 assertions pass (mutation-checked: two deliberately wrong expectations fail).
- pytest: 18 pass (API, Send-SMS hook, LLM guard, worker task).
- Flutter: 17 unit + 1 onboarding flow + 90 accessibility + 180 goldens pass; `flutter analyze` clean.
- ruff, ruff format, pyright, brand-sync and seed-sync checks clean.

## What shipped
See `PROJECT_STATE.md` → Done.

## Deviations
See `PROJECT_STATE.md` → Deviations (ADRs 0001–0007).

## Founder actions needed
1. Windows Developer Mode (Settings → System → For developers) — Flutter Windows builds with plugins need it.
2. `flutter doctor --android-licenses` — accept the Android SDK licences.
3. Track B accounts (spec §18): AWS + Bedrock Mumbai, Supabase Pro, PowerSync, Apple/Google/Microsoft Partner Center, Codemagic, Sentry, eCourtsIndia, Sarvam; Meta Business verification + WhatsApp `otp_login`; DLT SMS; 20 MP CNRs + 10 voice notes.
4. Hindi string review; OTP lockout decision; privacy-policy URL.
