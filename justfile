# Task runner (spec §8.3). One command per line so recipes work in PowerShell (Windows) and sh (CI).
set windows-shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-Command"]
set dotenv-load := false

default:
    @just --list

# First-time setup: tools, local env files, dependencies
setup:
    npm install --no-fund --no-audit
    uv sync
    uv run python tools/dev_env.py
    cd apps/client; flutter pub get

# Start Supabase (553xx ports) + Redis, API, worker, beat
dev:
    npx supabase start
    docker compose -f infra/docker/compose.yml up -d --build

stop:
    docker compose -f infra/docker/compose.yml down
    npx supabase stop

# Recreate the local database from migrations + seed
db-reset:
    npx supabase db reset

# Regenerate seed SQL from config/ and reload the database
seed:
    uv run python tools/gen_seed.py
    npx supabase db reset

# All tests except goldens (needs `just dev` for integration tests)
test:
    uv run pytest
    npx supabase test db
    cd apps/client; flutter test --exclude-tags golden

# Golden tests (Windows renders the reference images; CI runs them on windows-latest)
goldens:
    cd apps/client; flutter test --tags golden

goldens-update:
    cd apps/client; flutter test --tags golden --update-goldens

# Regenerate brand/token-dependent files and app icons
brand:
    uv run python tools/brand_sync.py
    cd apps/client; dart run flutter_launcher_icons

contrast:
    uv run python tools/check_contrast.py

lint:
    uv run ruff check .
    uv run ruff format --check .
    uv run pyright
    uv run python tools/brand_sync.py --check
    uv run python tools/gen_seed.py --check
    cd apps/client; dart format --set-exit-if-changed lib test
    cd apps/client; flutter analyze

# Run the app against local Supabase + API
run device="windows":
    cd apps/client; flutter run -d {{device}} --dart-define-from-file=env.local.json
