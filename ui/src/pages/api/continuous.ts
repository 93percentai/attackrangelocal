import type { APIRoute } from "astro";
import { exec as execCb } from "node:child_process";
import { promisify } from "node:util";

const exec = promisify(execCb);

// Drives scripts/start-continuous-sim.sh on the Ludus host.
// On stop we just create the sentinel file the Atomic Runner watches for.
export const POST: APIRoute = async ({ request, redirect }) => {
  const form = await request.formData();
  const action = (form.get("action") ?? "").toString();
  const target = process.env.SIM_TARGET ?? `${process.env.RANGE_ID ?? "42"}-winclient1`;

  let cmd = "";
  if (action === "start") {
    cmd = "bash /opt/attackrangelocal/scripts/start-continuous-sim.sh --windows";
  } else if (action === "stop") {
    cmd = `ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new ` +
      `Administrator@${target} 'powershell -NoProfile -Command "New-Item C:\\AtomicRunner\\stop -Force"'`;
  } else {
    return new Response("bad action", { status: 400 });
  }

  try {
    await exec(cmd, { timeout: 180_000 });
  } catch (e: any) {
    return new Response(`failed: ${e?.message ?? e}\n${e?.stderr ?? ""}`, { status: 502 });
  }
  return redirect("/continuous", 303);
};
