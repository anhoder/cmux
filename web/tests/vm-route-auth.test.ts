import { beforeEach, describe, expect, mock, test } from "bun:test";

const getUser = mock(async () => null);
const runVmWorkflow = mock(async () => {
  throw new Error("unauthenticated VM routes must not reach the VM workflow");
});
const createVm = mock(() => ({ workflow: "create" }));
const listUserVms = mock(() => ({ workflow: "list" }));

mock.module("../app/lib/stack", () => ({
  stackServerApp: { getUser },
}));

mock.module("../services/vms/workflows", () => ({
  createVm,
  listUserVms,
  runVmWorkflow,
}));

const { GET, POST } = await import("../app/api/vm/route");

beforeEach(() => {
  getUser.mockClear();
  getUser.mockResolvedValue(null);
  runVmWorkflow.mockClear();
  createVm.mockClear();
  listUserVms.mockClear();
});

describe("VM REST auth", () => {
  test("rejects unauthenticated provisioning before reaching Postgres or providers", async () => {
    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        body: JSON.stringify({ provider: "freestyle" }),
      }),
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(getUser).toHaveBeenCalled();
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("rejects unauthenticated VM listing before reaching Postgres", async () => {
    const response = await GET(new Request("https://cmux.test/api/vm"));

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(runVmWorkflow).not.toHaveBeenCalled();
  });

  test("authenticated provisioning runs the Effect VM workflow", async () => {
    getUser.mockResolvedValue({
      id: "user-1",
      displayName: null,
      primaryEmail: "user@example.com",
    });
    runVmWorkflow.mockResolvedValue({
      providerVmId: "provider-vm-1",
      provider: "freestyle",
      image: "snapshot-test",
      createdAt: 1_777_000_000_000,
    });

    const response = await POST(
      new Request("https://cmux.test/api/vm", {
        method: "POST",
        headers: { "idempotency-key": "idem-1" },
        body: JSON.stringify({ provider: "freestyle", image: "snapshot-test" }),
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      id: "provider-vm-1",
      provider: "freestyle",
      image: "snapshot-test",
      createdAt: 1_777_000_000_000,
    });
    expect(createVm).toHaveBeenCalledWith({
      userId: "user-1",
      provider: "freestyle",
      image: "snapshot-test",
      idempotencyKey: "idem-1",
    });
    expect(runVmWorkflow).toHaveBeenCalled();
  });
});
