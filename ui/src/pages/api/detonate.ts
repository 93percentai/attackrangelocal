import type { APIRoute } from "astro";
import { exec as execCb } from "node:child_process";
import { promisify } from "node:util";

const exec = promisify(execCb);

// Wraps scripts/detonate-sample.sh. The script itself enforces the
// safety rails (isolation check, 60s watchdog). Here we just pipe
// "DETONATE\n" to satisfy the confirmation prompt because the UI
// has its own confirmation surface (the explicit POST button).
export const POST: APIRoute = async ({ request, redirect }) => {
  const form = await request.formData();
  const hash = (form.get("hash") ?? "").toString().trim();
  if (!hash || !/^([0-9a-f]{64}|--eicar)$/i.test(hash)) {
    return new Response("invalid hash", { status: 400 });
  }
  const cmd = `echo DETONATE | bash /opt/attackrangelocal/scripts/detonate-sample.sh ${hash}`;
  try {
    const { stdout, stderr } = await exec(cmd, { timeout: 120_000 });
    return new Response(stdout + "\n" + stderr, {
      status: 200,
      headers: { "content-type": "text/plain" },
    });
  } catch (e: any) {
    return new Response(
      `detonation failed: ${e?.message}\n${e?.stderr ?? ""}`,
      { status: 502 },
    );
  }
};
