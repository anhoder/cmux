import { actor } from "rivetkit";
import { defaultProviderId, getProvider, type ProviderId } from "../drivers";
import type { registry } from "../registry";

export type UserVmEntry = {
  providerVmId: string; // the provider's own id — also the vmActor actor key
  provider: ProviderId;
  image: string;
  createdAt: number;
};

export type UserVmsState = {
  vms: UserVmEntry[];
};

// One coordinator per Stack Auth user. Tracks `{providerVmId, provider, image}` for every VM
// this user owns. We use the provider's own id everywhere — no cmux UUID layer on top.
// Rationale: both Freestyle (`ob7ho8876hklod2xizof`) and E2B (`i453t8zwgbo38qqlmsgsl`) mint
// 20-char alphanumeric ids already; stacking a UUID on top just muddies CLI output and docs.
export const userVmsActor = actor({
  options: { name: "UserVMs", icon: "users" },

  state: { vms: [] } as UserVmsState,

  actions: {
    list: (c) => c.state.vms,

    create: async (
      c,
      opts: { image?: string; provider?: ProviderId },
    ): Promise<UserVmEntry> => {
      const provider = opts.provider ?? defaultProviderId();
      // Provision the provider VM directly, then spawn a vmActor keyed on the provider id.
      // This avoids the vmActor.onCreate -> driver.create round trip (which used an extra
      // cmux-owned UUID) and means the actor key equals the provider id.
      const driver = getProvider(provider);
      const handle = await driver.create({ image: opts.image ?? "" });
      const entry: UserVmEntry = {
        providerVmId: handle.providerVmId,
        provider,
        image: handle.image,
        createdAt: handle.createdAt,
      };
      const client = c.client<typeof registry>();
      try {
        await client.vmActor.create([entry.providerVmId], {
          input: {
            userId: c.key[0] as string,
            provider,
            providerVmId: entry.providerVmId,
            image: entry.image,
          },
        });
      } catch (actorCreateError) {
        // vmActor.create failed *after* the provider already provisioned the VM. Without a
        // rollback, that VM lives on forever as an orphan (costing the user and cluttering
        // the Freestyle/E2B dashboard). Best-effort destroy + rethrow so the caller sees a
        // clean failure rather than a half-provisioned sandbox.
        try {
          await driver.destroy(entry.providerVmId);
        } catch {
          // The orphan-cleanup failure is less bad than the original; swallow but log.
          console.error(
            "userVmsActor.create: failed to roll back provider VM after vmActor.create error",
            { providerVmId: entry.providerVmId, provider },
          );
        }
        throw actorCreateError;
      }
      c.state.vms.push(entry);
      return entry;
    },

    forget: (c, providerVmId: string) => {
      c.state.vms = c.state.vms.filter((v) => v.providerVmId !== providerVmId);
    },
  },
});
