import { createClient } from "rivetkit/client";
import type { Registry } from "../../../../../services/vms/registry";
import { unauthorized, verifyRequest } from "../../../../../services/vms/auth";

export const dynamic = "force-dynamic";

function bearerFrom(request: Request): { accessToken: string; refreshToken: string } | null {
  const auth = request.headers.get("authorization");
  const refresh = request.headers.get("x-stack-refresh-token");
  if (!auth?.toLowerCase().startsWith("bearer ") || !refresh) return null;
  const a = auth.slice("bearer ".length).trim();
  const r = refresh.trim();
  if (!a || !r) return null;
  return { accessToken: a, refreshToken: r };
}

function clientFor(request: Request, bearer: { accessToken: string; refreshToken: string }) {
  const origin = new URL(request.url).origin;
  return createClient<Registry>({
    endpoint: `${origin}/api/rivet`,
    headers: {
      authorization: `Bearer ${bearer.accessToken}`,
      "x-stack-refresh-token": bearer.refreshToken,
    },
  });
}

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  try {
    const user = await verifyRequest(request);
    if (!user) return unauthorized();
    const bearer = bearerFrom(request);
    if (!bearer) return unauthorized();

    const body = (await request.json().catch(() => ({}))) as {
      command?: string;
      timeoutMs?: number;
    };
    if (!body.command) return jsonResponse({ error: "command is required" }, 400);

    const { id } = await params;
    const client = clientFor(request, bearer);
    const result = await client.vmActor
      .getOrCreate([id])
      .exec(body.command, body.timeoutMs ?? 30_000);
    return jsonResponse(result);
  } catch (err) {
    console.error("/api/vm/[id]/exec POST failed", err);
    return jsonResponse(
      { error: err instanceof Error ? `${err.name}: ${err.message}` : String(err) },
      500,
    );
  }
}
