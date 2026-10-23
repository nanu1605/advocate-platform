# 0002 — Local backend runs on Docker Desktop from the Windows checkout

Status: accepted (founder, 23 Oct 2026)

## Context
Spec §8.3 says to run Docker, the Supabase CLI and Python services inside WSL2, with Flutter on Windows.
The repository lives on `S:\` (a Windows drive). WSL2 reading `/mnt/s` is slow for bind mounts and Python
imports; a second checkout inside WSL would need constant syncing.

## Decision
One checkout at `S:\Projects\lawyer-app`. Docker Desktop (WSL2 engine) runs Postgres/Supabase, Redis and the
API/worker containers; `uv` runs Python tooling and tests natively on Windows; Flutter builds on Windows.
The Supabase CLI is invoked through `npx supabase` (no global install).

## Consequences
- CI runs on Linux runners, so path or line-ending assumptions are caught there.
- `.gitattributes` forces LF for shell, SQL and Python files.
- If Windows-native Python hits a Linux-only dependency (e.g. ClamAV, WeasyPrint system libs), that service runs
  only inside its Docker image.
