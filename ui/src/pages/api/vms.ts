import type { APIRoute } from "astro";
import { getVmStatuses } from "@/lib/ludus";

export const GET: APIRoute = async () => {
  const vms = await getVmStatuses();
  return new Response(JSON.stringify({ vms }), {
    headers: { "content-type": "application/json" },
  });
};
