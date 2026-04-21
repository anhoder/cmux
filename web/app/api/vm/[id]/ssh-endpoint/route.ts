import { unauthorized, verifyRequest } from "../../../../../services/vms/auth";
import {
  isActorMissingError,
  jsonResponse,
  notFoundVm,
  parseForwardedCreds,
  rivetClient,
  userOwnsVm,
} from "../../../../../services/vms/routeHelpers";

export const dynamic = "force-dynamic";

/**
 * Returns the SSH endpoint the mac client will dial to reach this VM's cmuxd-remote.
 *
 * Freestyle response shape: `{ host: "vm-ssh.freestyle.sh", port: 22,
 * username: "<vmId>+cmux", credential: { kind: "password", value: "<one-time token>" } }`.
 * Mac client hands this to the existing `cmux ssh` transport; no Next.js in the data plane.
 *
 * E2B returns 501-ish (provider throws) because E2B sandboxes don't expose raw TCP.
 *
 * Short-lived: each call mints a fresh identity + token. vmActor.remove revokes the identity
 * alongside the VM on destroy, so idle sessions don't accumulate zombie credentials.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  try {
    const user = await verifyRequest(request);
    if (!user) return unauthorized();
    const creds = parseForwardedCreds(request);
    if (!creds) return unauthorized();

    const { id } = await params;
    const client = rivetClient(creds);
    if (!(await userOwnsVm(client, user.id, id))) return notFoundVm(id);
    // `get` not `getOrCreate` — see the exec route for the rationale.
    try {
      const endpoint = await client.vmActor.get([id]).openSSH();
      return jsonResponse(endpoint);
    } catch (err) {
      if (isActorMissingError(err)) return notFoundVm(id);
      throw err;
    }
  } catch (err) {
    console.error("/api/vm/[id]/ssh-endpoint failed", err);
    return jsonResponse({ error: err instanceof Error ? err.message : "internal error" }, 500);
  }
}
