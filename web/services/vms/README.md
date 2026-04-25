# Cloud VMs service

Backend for `cmux vm new/ls/rm/exec/attach` and the sidebar Cloud VM surface. Stack Auth gates every public route. Provider API keys stay server-side. Freestyle and E2B prefer `cmuxd-remote` WebSocket PTY with short-lived leases; older Freestyle VMs can fall back to its SSH gateway.

## Layout

```text
services/vms/
  auth.ts             Stack Auth request verification helpers
  drivers/            Provider SDK adapters for E2B and Freestyle
  errors.ts           Typed Effect errors for VM workflows
  providerGateway.ts  Effect service wrapper around provider drivers
  repository.ts       Effect service for Postgres state and usage rows
  routeHelpers.ts     Shared authenticated REST route helpers
  workflows.ts        Effect workflows for create, list, destroy, exec, attach
db/
  schema.ts           Drizzle schema for VM state, leases, and usage events
  migrations/         SQL migrations applied by `bun db:migrate`
```

## HTTP surface

- `/api/vm`, authenticated `GET` list and `POST` create.
- `/api/vm/:id`, authenticated `DELETE` destroy.
- `/api/vm/:id/exec`, authenticated `POST` command execution.
- `/api/vm/:id/attach-endpoint`, authenticated `POST` PTY/RPC attach lease minting.
- `/api/vm/:id/ssh-endpoint`, authenticated `POST` legacy Freestyle SSH attach.

There is no raw actor or provider protocol endpoint. The old `/api/rivet/*` gateway has been removed.

## Authentication model

Public callers only use `/api/vm/*`. Each route calls Stack Auth first and returns `401` before any Postgres or provider operation when the caller is unauthenticated.

Ownership checks happen inside the Effect workflow by loading the VM row with both `user_id` and `provider_vm_id`. A user cannot destroy, exec, attach, or mint SSH credentials for a VM owned by another Stack Auth user.

The auth regression tests live in `web/tests/vm-route-auth.test.ts`. They verify unauthenticated create and list requests return `401` before the VM workflow runs.

## State model

- `cloud_vms` owns VM lifecycle state, provider ids, image ids, and per-user idempotency keys.
- `cloud_vm_leases` stores hashed PTY/RPC/SSH lease tokens, provider identity handles, session ids, expiry, and revocation timestamps.
- `cloud_vm_usage_events` records lifecycle, attach, SSH, and exec events for billing and audit rollups.

Create idempotency is enforced by the partial unique index on `(user_id, idempotency_key)`. A retry with the same key returns the existing VM after provisioning succeeds. A concurrent retry while the first create is still provisioning returns `409` instead of starting a second paid provider VM.

## Effect conventions

Routes stay thin. They parse HTTP input, set span attributes, and run an Effect workflow.

`workflows.ts` composes explicit services:

- `VmRepository`, Postgres reads and writes.
- `VmProviderGateway`, provider SDK calls wrapped in typed Effect errors.

Provider SDKs remain Promise-based adapters under `drivers/`, but all route-visible backend logic is modeled as Effect values with typed errors and explicit dependencies.

## Deployment

Vercel runs the Next.js application and all VM REST routes. Postgres is the persistent control plane. There is no Rivet deployment for this feature.

Set these Vercel environment variables per environment:

- `DATABASE_URL`, runtime Postgres connection string.
- `DIRECT_DATABASE_URL`, direct Postgres connection string for migrations.
- `E2B_API_KEY`, E2B provider key.
- `FREESTYLE_API_KEY`, Freestyle provider key.
- `E2B_CMUXD_WS_TEMPLATE`, E2B template alias/name for WebSocket PTY sandboxes.
- `FREESTYLE_SANDBOX_SNAPSHOT`, Freestyle snapshot id.
- `CMUX_VM_DEFAULT_PROVIDER`, `freestyle` or `e2b`.
- Stack Auth environment variables.
- Axiom/OpenTelemetry exporter variables.

Run Drizzle migrations before or during deployment, using the same migration flow documented in the backend setup plan.

## Local database development

Use `CMUX_PORT` to run multiple isolated web and database environments on one machine:

```bash
CMUX_PORT=10180 bun dev
```

`bun dev` sources `~/.secret/cmuxterm.env` or `~/.secrets/cmuxterm.env`, derives local database URLs from `CMUX_PORT`, starts this worktree's Docker Postgres, applies Drizzle migrations, then starts Next.js. When it exits or is interrupted, it stops the matching Docker Postgres container and network while preserving the volume.

The dev Postgres port is `CMUX_PORT + 10000`, so `CMUX_PORT=10180` maps to `localhost:20180`. `bun db:test` starts a separate test DB on `CMUX_PORT + 11000`, applies migrations twice, and runs behavior tests against a real Postgres database.

## Provider matrix

| Verb                        | Freestyle | E2B |
|-----------------------------|-----------|-----|
| `cmux vm new`               | yes       | yes |
| `cmux vm new --workspace`   | yes       | yes |
| `cmux vm new --detach`      | yes       | yes |
| `cmux vm attach <id>`       | yes       | yes |
| `cmux vm exec <id> -- ...`  | yes       | yes |
| `cmux vm ls / rm`           | yes       | yes |

E2B interactive paths require a cmuxd WebSocket PTY image. The backend writes only a hash of attach tokens to Postgres; raw tokens are returned once to the Mac client.

## Usage, limits, and pricing

The usage ledger is in Postgres today. Rate limits should happen before each paid provider create call, keyed by Stack Auth user id and provider. Do not rely on Postgres for hot request throttling long term. Use a dedicated rate-limit store such as Vercel KV, Upstash Redis, or Vercel's rate-limit product when it is available for the deployment tier.
