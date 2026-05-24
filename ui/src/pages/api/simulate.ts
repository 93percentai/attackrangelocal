import type { APIRoute } from "astro";
import { triggerSimulate } from "@/lib/ludus";

export const POST: APIRoute = async ({ request }) => {
  let body: any = {};
  try { body = await request.json(); } catch { /* form post is fine too */ }
  if (!body.target) {
    return new Response("missing target", { status: 400 });
  }
  const result = await triggerSimulate({
    target: body.target,
    techniques: body.techniques ?? "",
    random: !!body.random,
    loop: !!body.loop,
    interval: body.interval ?? 30,
    exclude: body.exclude ?? "",
  });
  return new Response(result.detail, { status: result.ok ? 200 : 502 });
};
