import type { APIRoute } from "astro";
import { runIsolationCheck } from "@/lib/ludus";

export const POST: APIRoute = async () => {
  const r = await runIsolationCheck();
  return new Response(JSON.stringify(r), {
    headers: { "content-type": "application/json" },
  });
};
