# advocate-platform

Case diary, research and drafting app for Indian advocates (working name **Pairavi**), by Jainav Infotech.
Flutter app (Android · iOS · Windows) + Supabase (Mumbai) + FastAPI/Celery. Build spec: `legal-ai-app-build-spec.md` v1.1.
Current status: [`PROJECT_STATE.md`](PROJECT_STATE.md).

## Local setup (Windows 11)

Prerequisites: Docker Desktop, Node 24, `uv`, Flutter stable on PATH, VS Build Tools 2022 (C++ desktop + C++ ATL), `just`,
Windows **Developer Mode** on (Flutter plugins need symlinks).

```bash
just setup     # deps + local env files (supabase/.env, .env, apps/client/env.local.json)
just dev       # Supabase on 553xx ports + Redis/API/worker/beat
just test      # pytest + pgTAP + flutter tests
just run       # app on Windows against the local stack
```

Local sign-in: phone `+91 99999 00001` (or `…00002`), OTP `123456`. Numbers `…00003–00005` are reserved for API tests.

Supabase Studio: http://127.0.0.1:55323 · API: http://127.0.0.1:8000/docs

## Layout
See spec §8.1. Key folders: `apps/client` (Flutter), `services/api`, `services/workers`, `packages/*`,
`supabase/` (migrations, pgTAP tests, seed), `config/`, `tools/`, `docs/adr`, `docs/phases`.

## Rules
Hard rules in spec §0.1 apply to every change: no scraping, no invented legal facts, client data stays in India,
no secrets in git, en + hi for every UI string, permissive licences only.
