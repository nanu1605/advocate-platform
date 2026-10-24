# 0010 — Offline sync: PowerSync open edition locally, Sync Streams, Supabase uploads

Status: accepted for development and CI (24 Oct 2026). Production hosting needs a founder decision (below).

## Context
Spec §9.4 puts every device read on local SQLite synced by PowerSync. Phase 1 builds this while the founder's
accounts are on hold, so it has to run with no PowerSync account. §7.3 notes that the self-hosted open edition of
the PowerSync Service is under the FSL licence, which is an exception to hard rule 7 (permissive, MPL or LGPL only)
and needs this ADR plus founder approval.

## Decision
**Service.** The open edition (`journeyapps/powersync-service`, pinned 1.27.1) runs in `infra/docker/compose.yml`
for local development and CI only. It replicates the local Supabase database through the `powersync` publication
and keeps bucket storage in a disposable Postgres container (no MongoDB). Nothing in our code links to it: the app
talks to it over HTTP with the Apache-2.0 Flutter SDK (`powersync`). FSL-1.1 allows this use; it forbids offering
a competing sync product, which we don't.

**Sync Streams, not Sync Rules.** `infra/powersync/sync-config.yaml` uses Sync Streams (edition 3), as §9.4 asks.
One shared CTE (`user_orgs`: active memberships) feeds four auto-subscribed streams: reference (global bucket),
org rows (one bucket per organisation), the author's private notes (per organisation and user), and the user's
own rows. Bucket count per user = organisations × 2 + 2, far under the 1,000 limit.

**Auth.** The service verifies Supabase access tokens (ES256) against the project's JWKS with audience
`authenticated`, so no extra token endpoint or signing key exists.

**Uploads.** The connector applies each queued change to Supabase through PostgREST as the signed-in user, so RLS
and the §9.3 column triggers (ADR 0009) decide what is accepted. Errors that can never succeed (Postgres classes 22
and 23, and 42501) drop the change and log it; the next checkpoint restores the server's row on the device.
Anything else stays queued and retries. jsonb and array columns are JSON text on the device and are decoded before
upload (`jsonColumns`, checked against the database by a test).

**Checks.** `services/api/tests/test_sync.py` signs in six real users (owner, advocate, junior, clerk, outsider,
removed member) and downloads everything the service streams to each: every rule in §9.4 has a row that must pass
and one that must not. It also checks the publication, the sync config and the device schema against the database.
`apps/client/integration_test/sync_test.dart` runs the SDK end to end (download, offline write, reconnect, refused
write rolled back); it runs on a desktop or device, not in CI yet.

**On-device encryption** stays open until spike 11b (Track B) tests the SQLCipher build on all three platforms.
Until then the database relies on OS storage encryption plus the app lock (§9.4 fallback). Switching is a package
swap (`powersync_sqlcipher`) with a key from the secure store.

## Founder decision needed before production (Track B, task B0)
1. **PowerSync Cloud in an India region** (paid; preferred by §7.3 if offered), or
2. **Self-host this same open edition on AWS Mumbai**: an FSL exception to hard rule 7 that the founder must
   approve. It also needs a dedicated replication role (`replication`, `bypassrls`, password from Secrets Manager)
   instead of the local `postgres` user.

Either way the sync config, connector and tests stay as they are.

## Consequences
- `just dev` and CI start the sync service; the leakage tests fail CI if it is missing.
- Adding a synced table means updating the publication migration, the sync config and `schema.dart` together;
  tests catch any drift.
- Signing out clears the device database, including unsent changes. A warning for pending changes belongs with the
  sign-out UI (task 11).
