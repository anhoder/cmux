# Cloud VMs service

Backend for `cmux vm new/ls/rm/exec/attach` and the upcoming sidebar Cloud button. Stack Auth gated, manaflow-owned provider keys (no BYO). Freestyle attaches over its SSH gateway. E2B attaches over `cmuxd-remote` WebSocket PTY with a short-lived one-use lease because E2B sandboxes do not expose raw TCP.

## Layout

```text
services/vms/
  drivers/
    types.ts       VMProvider interface, shared types, errors
    e2b.ts         E2BProvider — real driver over @e2b SDK
    freestyle.ts   FreestyleProvider — real driver over @freestyle/sdk
    index.ts       getProvider / defaultProviderId
  actors/
    vm.ts          One per VM. Tracks connection count for idle-pause.
    userVms.ts     Coordinator per Stack Auth user. Lists/creates/forgets VMs.
  registry.ts      RivetKit setup({ use: { vmActor, userVmsActor } })
  routeHelpers.ts  Shared REST helpers: bearer parsing, server-controlled Rivet
                   base URL, ownership check, internal-secret gate header.
  auth.ts          verifyRequest / unauthorized — Stack Auth bearer verification
```

## HTTP surface

- `/api/rivet/*` — authoritative. `registry.handler(request)` speaks the native RivetKit
  protocol (HTTP POST to action endpoints, WebSocket for attach). Swift client hits this directly.
- `/api/vm` — REST facade for curl + debug: `GET` (list) / `POST` (create).
- `/api/vm/:id` — REST facade for curl + debug: `DELETE` (destroy).
- `/api/vm/:id/exec` — REST facade for curl + debug: `POST` (run a command).

All endpoints verify `Authorization: Bearer <stack access token>` plus `X-Stack-Refresh-Token:
<refresh>` from the Mac client (matches the tokens the Mac app stashes in keychain after
`cmux auth login`). Browsers going through `/handler/*` hit the same functions via the Stack
Auth cookie path.

## Env

See `web/.env.example`. The VM-specific vars:

- `E2B_API_KEY` — manaflow's key, used by E2BProvider.
- `FREESTYLE_API_KEY` — manaflow's key, used by FreestyleProvider.
- `E2B_CMUXD_WS_TEMPLATE` — E2B template alias/name for interactive WebSocket PTY sandboxes.
  Produced by `web/scripts/build-cloud-vm-images.ts`.
- `E2B_SANDBOX_TEMPLATE` — legacy scratch template. Pass explicitly with `--image` if needed.
- `FREESTYLE_SANDBOX_SNAPSHOT` — Freestyle snapshot id for `vm new` / `vm attach`. Produced by
  `web/scripts/build-cloud-vm-images.ts`.
- `CMUX_VM_DEFAULT_PROVIDER` — `freestyle` (default) or `e2b`.

## Provider matrix

| Verb                        | Freestyle | E2B            |
|-----------------------------|-----------|----------------|
| `cmux vm new` (shell)       | ✓         | ✓              |
| `cmux vm new --workspace`   | ✓         | ✓              |
| `cmux vm new --detach`      | ✓         | ✓              |
| `cmux vm attach <id>`       | ✓         | ✓              |
| `cmux vm exec <id> -- ...`  | ✓         | ✓              |
| `cmux vm ls / rm`           | ✓         | ✓              |

E2B interactive paths require a cmuxd WebSocket PTY image. The backend writes only a hash of the
attach token into `/tmp/cmux/attach-lease.json`; the raw token is returned once to the Mac client.

## Lifecycle

- `userVmsActor.create({ image, provider })` allocates a cmux UUID, spawns `vmActor(uuid)` with
  input, appends to the user's list, returns `{ id, provider, image }`.
- `vmActor.onCreate` calls the provider driver to provision a real sandbox and stores
  `providerVmId` in actor state.
- A client WebSocket connection keeps `c.conns.size >= 1`. Disconnecting schedules `autoPause`
  10 minutes out.
- `autoPause` re-checks `c.conns.size` first, so a reconnect race is a no-op. If still zero,
  it calls `driver.pause()`.
- `vmActor.remove` calls `driver.destroy()` then `c.destroy()`. `userVmsActor.forget(id)`
  removes the id from the coordinator.

## Next steps

- Keep Freestyle SSH and E2B WebSocket attach paths sharing the same `POST /api/vm/:id/attach-endpoint`
  contract.
- Add `/api/vm/:id/pause`, `/api/vm/:id/resume`, `/api/vm/:id/snapshot` REST wrappers once Swift
  client wants them.

See `plans/task-cmux-vm-cloud/cloud-vms-and-per-surface-ssh.md` for the full roadmap and
`plans/task-cmux-vm-cloud/cli-vm-new-shell-and-workspace.md` for the latest CLI shape.
