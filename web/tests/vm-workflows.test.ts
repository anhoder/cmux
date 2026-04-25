import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepositoryLive } from "../services/vms/repository";
import {
  createVm,
  openSshEndpoint,
} from "../services/vms/workflows";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

let sql: Sql | null = null;

function databaseURL() {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  return url;
}

function providerLayer(provider: VmProviderGatewayShape) {
  return Layer.mergeAll(VmRepositoryLive, Layer.succeed(VmProviderGateway, provider));
}

beforeAll(() => {
  if (!runDbTests) return;
  sql = postgres(databaseURL(), { max: 1 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

describe("VM Effect workflows", () => {
  dbTest("creates one provider VM per user idempotency key and records usage", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "e2b" as const,
            providerVmId: "provider-vm-idem-1",
            status: "running" as const,
            image: "cmuxd-ws:test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    const program = createVm({
      userId: "user-workflow-idem",
      provider: "e2b",
      image: "cmuxd-ws:test",
      idempotencyKey: "idem-1",
    });
    const layer = providerLayer(provider);
    const first = await Effect.runPromise(program.pipe(Effect.provide(layer)));
    const second = await Effect.runPromise(program.pipe(Effect.provide(layer)));

    expect(first).toEqual(second);
    expect(createCalls).toBe(1);

    const [{ vmCount }] = await sql<{ vmCount: string }[]>`
      select count(*)::text as "vmCount" from cloud_vms where user_id = 'user-workflow-idem'
    `;
    const [{ usageCount }] = await sql<{ usageCount: string }[]>`
      select count(*)::text as "usageCount" from cloud_vm_usage_events
      where user_id = 'user-workflow-idem' and event_type = 'vm.created'
    `;
    expect(vmCount).toBe("1");
    expect(usageCount).toBe("1");
  });

  dbTest("revokes the previous SSH identity before minting a replacement", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    const [vm] = await sql<{ id: string }[]>`
      insert into cloud_vms (user_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-ssh', 'freestyle', 'provider-vm-ssh-1', 'snapshot-test', 'running')
      returning id
    `;

    let mintCount = 0;
    const revoked: string[] = [];
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () =>
        Effect.sync(() => {
          mintCount += 1;
          return {
            transport: "ssh" as const,
            host: "vm-ssh.freestyle.sh",
            port: 22,
            username: "provider-vm-ssh-1+cmux",
            publicKeyFingerprint: null,
            credential: { kind: "password" as const, value: `token-${mintCount}` },
            identityHandle: `identity-${mintCount}`,
          };
        }),
      revokeSSHIdentity: (_provider, identityHandle) =>
        Effect.sync(() => {
          revoked.push(identityHandle);
        }),
    };
    const layer = providerLayer(provider);

    const endpoint1 = await Effect.runPromise(
      openSshEndpoint({ userId: "user-workflow-ssh", providerVmId: "provider-vm-ssh-1" }).pipe(
        Effect.provide(layer),
      ),
    );
    const endpoint2 = await Effect.runPromise(
      openSshEndpoint({ userId: "user-workflow-ssh", providerVmId: "provider-vm-ssh-1" }).pipe(
        Effect.provide(layer),
      ),
    );

    expect(endpoint1.identityHandle).toBe("identity-1");
    expect(endpoint2.identityHandle).toBe("identity-2");
    expect(revoked).toEqual(["identity-1"]);

    const leases = await sql<{ providerIdentityHandle: string; revokedAt: Date | null }[]>`
      select provider_identity_handle as "providerIdentityHandle", revoked_at as "revokedAt"
      from cloud_vm_leases
      where vm_id = ${vm.id}
      order by provider_identity_handle
    `;
    expect(leases).toHaveLength(2);
    expect(leases[0]).toMatchObject({ providerIdentityHandle: "identity-1" });
    expect(leases[0]?.revokedAt).toBeInstanceOf(Date);
    expect(leases[1]).toMatchObject({ providerIdentityHandle: "identity-2", revokedAt: null });
  });
});
