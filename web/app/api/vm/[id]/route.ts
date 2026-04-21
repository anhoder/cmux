import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import {
  jsonResponse,
  notFoundVm,
  parseBearer,
  rivetClient,
  userOwnsVm,
} from "../../../../services/vms/routeHelpers";

export const dynamic = "force-dynamic";

export async function DELETE(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  try {
    const user = await verifyRequest(request);
    if (!user) return unauthorized();
    const bearer = parseBearer(request);
    if (!bearer) return unauthorized();
    const { id } = await params;
    const client = rivetClient(bearer);
    // Prevent IDOR: a user may only destroy VMs tracked in their own coordinator actor.
    if (!(await userOwnsVm(client, user.id, id))) return notFoundVm(id);
    // vmActor.remove() runs provider.destroy() then c.destroy(); the coordinator drops the id.
    await client.vmActor.getOrCreate([id]).remove();
    await client.userVmsActor.getOrCreate([user.id]).forget(id);
    return jsonResponse({ ok: true });
  } catch (err) {
    console.error("/api/vm/[id] DELETE failed", err);
    // Return a safe summary only — don't echo the provider's error shape, which can
    // contain internal URLs or tokens.
    return jsonResponse({ error: err instanceof Error ? err.message : "internal error" }, 500);
  }
}
