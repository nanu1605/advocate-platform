"""Create local-only env files if missing: supabase/.env (hook secret), .env (API), apps/client/env.local.json (app).
All values point at the local stack; none of them are production secrets."""

import base64
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCAL_ANON_KEY = (  # well-known key of every local Supabase stack
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9"
    ".CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
)


def write_once(path: Path, content: str) -> None:
    if path.exists():
        print(f"kept  {path.relative_to(ROOT)}")
        return
    path.write_text(content, encoding="utf-8")
    print(f"wrote {path.relative_to(ROOT)}")


def main() -> None:
    supa_env = ROOT / "supabase/.env"
    secret = "v1,whsec_" + base64.b64encode(os.urandom(32)).decode()
    write_once(supa_env, f"AUTH_HOOK_SECRET={secret}\nSUPABASE_AUTH_SMS_TWILIO_AUTH_TOKEN=unused-local\n")
    secret = next(line.split("=", 1)[1] for line in supa_env.read_text().splitlines() if line.startswith("AUTH_HOOK"))

    write_once(
        ROOT / ".env",
        "APP_ENV=local\nTZ=Asia/Kolkata\n"
        "DATABASE_URL=postgresql+asyncpg://postgres:postgres@127.0.0.1:55322/postgres\n"
        "REDIS_URL=redis://localhost:6379/0\nSUPABASE_URL=http://127.0.0.1:55321\n"
        f"SUPABASE_ANON_KEY={LOCAL_ANON_KEY}\nAUTH_HOOK_SECRET={secret}\n",
    )
    app_env = {
        "SUPABASE_URL": "http://127.0.0.1:55321",
        "SUPABASE_ANON_KEY": LOCAL_ANON_KEY,
        "API_URL": "http://127.0.0.1:8000",
        "POWERSYNC_URL": "http://127.0.0.1:55380",
    }
    write_once(ROOT / "apps/client/env.local.json", json.dumps(app_env, indent=2) + "\n")


if __name__ == "__main__":
    main()
