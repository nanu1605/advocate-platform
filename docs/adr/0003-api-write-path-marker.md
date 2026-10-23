# 0003 — API-only writes are marked with `app.write_path`

Status: accepted

## Context
Spec §9.1/§9.3 separates device writes (PowerSync upload → Supabase) from API-only writes (anything that creates
matters, costs money, sends messages or runs AI). Both arrive in Postgres as role `authenticated` with the same JWT
claims, so RLS alone cannot tell them apart.

## Decision
The API sets `app.write_path = 'api'` (transaction-local) next to `request.jwt.claims` on every request.
`public.via_api()` reads it, and every API-only INSERT/UPDATE policy requires it. PostgREST/PowerSync clients cannot
set arbitrary settings (no exposed function wraps `set_config`), so a device cannot pass this check.

Rules for future migrations:
- Never expose a function in `public`/`graphql_public` that calls `set_config` with caller-supplied names.
- API-only tables: write policies include `via_api()`. Device-writable tables/columns: policies without it,
  plus column-restricting triggers where §9.3 limits columns.

## Consequences
- pgTAP tests cover both paths per table (`tests.matrix(..., api => true/false)`).
- Inserts whose `RETURNING` needs a SELECT policy satisfied only by an AFTER trigger (e.g. new org → owner
  membership) must insert with a client-chosen id and read back.
