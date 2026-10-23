# PROJECT_STATE
Current phase: 0 — Foundations (status: Track A done; Track B on hold by founder, 24 Oct 2026)
Last updated: 2026-10-24

## Done (this phase)
- Monorepo per spec §8.1; private GitHub repo `nanu1605/advocate-platform`; `justfile`, ruff, pyright, very_good_analysis, pre-commit.
- Brand system: `brand/brand.json`, placeholder icon/logo, `tools/brand_sync.py` (Flutter constants + tokens, Android/iOS/Windows names).
- Design tokens → light/dark/sunlight themes; contrast check (`tools/check_contrast.py`) passes every §5.6 pair.
- Flutter app: Riverpod, go_router with onboarding redirect, feature flags, en/hi ARB, P1 shell (phone bar, Windows rail, Ctrl+K palette, window size memory), Settings.
- Component kit: 17 components (ADR 0001) + `/dev/kitchen-sink`; 180 goldens (3 themes × en/hi × 1.0/2.0); 90 accessibility checks.
- Pseudo-locale overflow check (spec §16.4): `tools/pseudo_l10n.py` reruns the widget tests with English 40% longer, in CI and `just pseudo`. The onboarding flow test runs in en and hi, through to Settings.
- Onboarding: language → phone OTP → itemised consent → app lock (device auth or salted PIN, 5-try sign-out) → Today; 5 wrong codes lock the OTP until a new one is sent ([ADR 0008](docs/adr/0008-otp-lockout.md)); consent screen links the privacy policy.
- Hindi strings: internal two-reviewer pass with a skeptical verify, 23 fixes (24 Oct 2026); native-speaker review still due.
- Supabase local (Mumbai-equivalent schema): 12 P0 tables, RLS on all, API-only write marker (ADR 0003), 300 pgTAP assertions (5 actors × CRUD).
- FastAPI: JWKS JWT, run-as-user transactions, org context, error shape, Redis rate limit, Send-SMS hook (3/10 min, 10/day), `/v1/me`, `/v1/consents`, `/v1/orgs`, `/v1/devices`; cross-org isolation tested.
- Celery app + beat (IST) with the `jobs.is_recent` window job; Docker Compose for Redis/API/worker/beat.
- `legal_ai.LLMClient` guard: refuses non-India profiles, other regions, the Mantle endpoint; strips sampling params.
- CI workflow (backend + pgTAP + pytest, Flutter, Windows goldens, Android + Windows builds) and Dependabot; all 5 jobs green on GitHub Actions, actions on their Node 24 majors.
- Spikes: 11a editor (ADR 0004), 11f pdfrx host part (ADR 0005), 11g Devanagari PDFs (ADR 0006).

## In progress
- Nothing running. On hold by founder (24 Oct 2026): Track B accounts (spec tasks 6-staging, 9, 10, spikes 11b–e), native-speaker Hindi review, privacy-policy page.

## Next up
1. Local Windows build: Developer Mode is on; Build Tools 2022 still needs the "C++ ATL" component (`Microsoft.VisualStudio.Component.VC.ATL`) for `flutter_secure_storage_windows` (`atlstr.h`). CI already builds Windows.
2. When the hold lifts, before the P1 beta: native-speaker review of `app_hi.arb` (spec §5.10) and the lawyer-drafted privacy policy live at https://jainavinfotech.in/privacy (the consent screen links there).
3. Track B as accounts arrive: Supabase staging (Mumbai), PowerSync e2e + spike 11b, Terraform staging + Sentry + Codemagic, spikes 11c/11d/11e.
4. Device checks left open by spikes 11a (Windows IME) and 11f (low-end Android scroll).

## Deviations from spec (with ADR links)
- Kit: 5 P2-only components deferred to P2 start — [ADR 0001](docs/adr/0001-defer-p2-kit-components.md).
- Local backend on Docker Desktop from the Windows checkout, not inside WSL2 — [ADR 0002](docs/adr/0002-backend-dev-on-docker-desktop.md).
- Supabase local ports moved to 553xx: Windows reserves 54236–54335 on this machine.
- Phosphor icons from vendored fonts; `phosphor_flutter` no longer builds — [ADR 0007](docs/adr/0007-vendored-phosphor-icons.md).
- Rich-text editor: flutter_quill, not appflowy_editor (does not build on Flutter 3.47) — [ADR 0004](docs/adr/0004-rich-text-editor.md).
- Riverpod without the code generator, and no freezed/json_serializable yet: P0 has no data models. Add them with the P1 data layer.
- Dart API client is hand-typed (spec §7.1 allows "generated or typed").
- `Idempotency-Key` handling arrives with the first job/money/message endpoint (P1 import); no P0 POST needs it.
- Contrast is enforced on tokens (exact); Flutter's pixel-sampling contrast guideline misreads thin anti-aliased glyphs and is not used.
- iOS `hi.lproj/InfoPlist.strings` is generated but not yet registered in the Xcode project (needs the Codemagic/iOS build, Track B).
- Feature flags are compiled-in (all off) until PowerSync syncs `feature_flags`.
- Wrong-OTP lockout (spec §15.2) is enforced in the app, backed by Supabase's code expiry and per-IP verify limit; Supabase phone OTP allows no server-side per-number count — [ADR 0008](docs/adr/0008-otp-lockout.md).
- Windows `APPLY_STANDARD_SETTINGS` defines `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`: `local_auth_windows` 2.0.2 builds with `/await`, which MSVC 14.51 rejects (STL1011). Remove when the plugin moves to C++20 `<coroutine>`.

## Questions for the founder
- None open.

## Pinned versions
Flutter 3.47.7 · Dart 3.13.5 · Python 3.14.6 · uv 0.11.26 · Node 24.17 · Supabase CLI 2.122.0 · Postgres 17 · Redis 8 ·
FastAPI 0.161.1 · Pydantic 2.14.1 · SQLAlchemy 2.1.6 · asyncpg 0.32.0 · Celery 5.6.3 · PyJWT 2.15.1 · structlog 26.1.0 ·
ruff 0.17.2 · pyright 1.1.414 · pytest 9.1.1 · flutter_riverpod 3.4.3 · go_router 18.1.1 · supabase_flutter 2.18.3 ·
dio 5.11.1 · local_auth 3.0.2 · flutter_secure_storage 11.2.0 · animations 3.0.0 · window_manager 0.5.2 · intl 0.20.3 ·
very_good_analysis 11.0.0 · flutter_quill 11.6.0 (P4) · pdfrx 2.10.1 (P1) · PowerSync SDK — pending (Track B)
