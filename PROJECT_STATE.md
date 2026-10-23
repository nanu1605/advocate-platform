# PROJECT_STATE
Current phase: 0 — Foundations (status: building — Track A done, Track B waiting on founder accounts)
Last updated: 2026-10-24

## Done (this phase)
- Monorepo per spec §8.1; private GitHub repo `nanu1605/advocate-platform`; `justfile`, ruff, pyright, very_good_analysis, pre-commit.
- Brand system: `brand/brand.json`, placeholder icon/logo, `tools/brand_sync.py` (Flutter constants + tokens, Android/iOS/Windows names).
- Design tokens → light/dark/sunlight themes; contrast check (`tools/check_contrast.py`) passes every §5.6 pair.
- Flutter app: Riverpod, go_router with onboarding redirect, feature flags, en/hi ARB, P1 shell (phone bar, Windows rail, Ctrl+K palette, window size memory), Settings.
- Component kit: 17 components (ADR 0001) + `/dev/kitchen-sink`; 180 goldens (3 themes × en/hi × 1.0/2.0); 90 accessibility checks.
- Onboarding: language → phone OTP → itemised consent → app lock (device auth or salted PIN, 5-try sign-out) → Today.
- Supabase local (Mumbai-equivalent schema): 12 P0 tables, RLS on all, API-only write marker (ADR 0003), 300 pgTAP assertions (5 actors × CRUD).
- FastAPI: JWKS JWT, run-as-user transactions, org context, error shape, Redis rate limit, Send-SMS hook (3/10 min, 10/day), `/v1/me`, `/v1/consents`, `/v1/orgs`, `/v1/devices`; cross-org isolation tested.
- Celery app + beat (IST) with the `jobs.is_recent` window job; Docker Compose for Redis/API/worker/beat.
- `legal_ai.LLMClient` guard: refuses non-India profiles, other regions, the Mantle endpoint; strips sampling params.
- CI workflow (backend + pgTAP + pytest, Flutter, Windows goldens, Android + Windows builds) and Dependabot; all 5 jobs green on GitHub Actions.
- Spikes: 11a editor (ADR 0004), 11f pdfrx host part (ADR 0005), 11g Devanagari PDFs (ADR 0006).

## In progress
- Nothing running. Track B (spec tasks 6-staging, 9, 10, spikes 11b–e) waits for accounts.

## Next up
1. Founder: enable Windows Developer Mode; accept Android SDK licences; review Dependabot PRs #1–#6 (#1 is a Redis client 6 → 8 major bump).
2. Track B as accounts arrive: Supabase staging (Mumbai), PowerSync e2e + spike 11b, Terraform staging + Sentry + Codemagic, spikes 11c/11d/11e.
3. Device checks left open by spikes 11a (Windows IME) and 11f (low-end Android scroll).

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
- 40% pseudo-locale overflow check (spec §16.4) not built yet; Hindi goldens at 2.0× text currently catch overflow.
- iOS `hi.lproj/InfoPlist.strings` is generated but not yet registered in the Xcode project (needs the Codemagic/iOS build, Track B).
- Feature flags are compiled-in (all off) until PowerSync syncs `feature_flags`.
- Windows `APPLY_STANDARD_SETTINGS` defines `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`: `local_auth_windows` 2.0.2 builds with `/await`, which MSVC 14.51 rejects (STL1011). Remove when the plugin moves to C++20 `<coroutine>`.

## Questions for the founder
- Hindi UI strings in `apps/client/l10n/app_hi.arb` are a first draft by Claude Code; spec §5.10 needs a native-speaker review.
- Wrong-OTP lockout after 5 attempts (spec §15.2): Supabase phone OTP has no per-number verify hook. Options: rely on Supabase's per-IP verify limit, or route verification through our API. Decide before the P1 beta.
- Privacy-policy URL for the consent screen link.

## Pinned versions
Flutter 3.47.7 · Dart 3.13.5 · Python 3.14.6 · uv 0.11.26 · Node 24.17 · Supabase CLI 2.122.0 · Postgres 17 · Redis 8 ·
FastAPI 0.161.1 · Pydantic 2.14.1 · SQLAlchemy 2.1.6 · asyncpg 0.32.0 · Celery 5.6.3 · PyJWT 2.15.1 · structlog 26.1.0 ·
ruff 0.17.2 · pyright 1.1.414 · pytest 9.1.1 · flutter_riverpod 3.4.3 · go_router 18.1.1 · supabase_flutter 2.18.3 ·
dio 5.11.1 · local_auth 3.0.2 · flutter_secure_storage 11.2.0 · animations 3.0.0 · window_manager 0.5.2 · intl 0.20.3 ·
very_good_analysis 11.0.0 · flutter_quill 11.6.0 (P4) · pdfrx 2.10.1 (P1) · PowerSync SDK — pending (Track B)
