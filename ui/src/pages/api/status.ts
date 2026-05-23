import type { APIRoute } from "astro";
import { getBootstrapPhase, getLudusRangeStatus, RANGE } from "@/lib/ludus";

export const GET: APIRoute = async () => {
  const [phase, ludus] = await Promise.all([getBootstrapPhase(), getLudusRangeStatus()]);
  return new Response(
    JSON.stringify({ range: RANGE, phase, ludus }, null, 2),
    { headers: { "content-type": "application/json" } },
  );
};
