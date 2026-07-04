// Thin wrappers around the shell tools we trust on the Ludus host.
// Designed to fail gracefully if a command isn't available (so the UI can
// still be browsed from a laptop that doesn't have ludus/tailscale).

import { exec as execCb } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";

const exec = promisify(execCb);

const ATTACK_RANGE_API =
  process.env.ATTACK_RANGE_API ?? "http://127.0.0.1:4000";
// Fixed attack_range_id baked into templates/local_ludus/default.yml —
// local_ludus is a persistent lab (Ludus owns the VMs), not a disposable
// cloud stack, so there's no per-build UUID to discover at runtime.
const ATTACK_RANGE_ID = process.env.ATTACK_RANGE_ID ?? "local-ludus-range";
const RANGE_ID = process.env.RANGE_ID ?? "42";
const STATUS_FILE =
  process.env.STATUS_FILE ?? "/var/lib/ludus-bootstrap/status";

async function run(cmd: string, timeoutMs = 5000): Promise<string> {
  try {
    const { stdout } = await exec(cmd, { timeout: timeoutMs, maxBuffer: 4 << 20 });
    return stdout.trim();
  } catch (err: any) {
    return `__error__:${err?.code ?? "exec"}: ${err?.stderr ?? err?.message ?? ""}`.trim();
  }
}

const RANGE_MODE = (process.env.RANGE_MODE ?? "full").toLowerCase();

const FULL_INVENTORY = [
  { name: "dc01",         role: "AD primary DC",     os: "Win Server 2022", vlan_ip: 5,  cpu: 2, ram: 3 },
  { name: "winclient1",   role: "Domain member",     os: "Windows 11",      vlan_ip: 20, cpu: 2, ram: 4 },
  { name: "winsrv1",      role: "Domain member",     os: "Win Server 2022", vlan_ip: 21, cpu: 1, ram: 2 },
  { name: "splunk",       role: "Splunk Enterprise", os: "Ubuntu 22.04",    vlan_ip: 10, cpu: 2, ram: 5 },
  { name: "elastic",      role: "Elastic + Kibana",  os: "Ubuntu 22.04",    vlan_ip: 50, cpu: 2, ram: 4 },
  { name: "linux",        role: "Linux victim",      os: "Ubuntu 22.04",    vlan_ip: 30, cpu: 1, ram: 2 },
  { name: "kali",         role: "Attacker",          os: "Kali Rolling",    vlan_ip: 40, cpu: 2, ram: 2 },
] as const;

const MINIMAL_INVENTORY = [
  { name: "dc01",         role: "DC + server",       os: "Win Server 2022", vlan_ip: 5,  cpu: 2, ram: 4 },
  { name: "winclient1",   role: "Domain member",     os: "Windows 11",      vlan_ip: 20, cpu: 2, ram: 3 },
  { name: "splunk",       role: "Splunk Enterprise", os: "Ubuntu 22.04",    vlan_ip: 10, cpu: 2, ram: 4 },
  { name: "linux",        role: "Linux victim",      os: "Ubuntu 22.04",    vlan_ip: 30, cpu: 1, ram: 1 },
  { name: "kali",         role: "Attacker",          os: "Kali Rolling",    vlan_ip: 40, cpu: 2, ram: 2 },
] as const;

export const VM_INVENTORY = RANGE_MODE === "minimal" ? MINIMAL_INVENTORY : FULL_INVENTORY;

export type VmStatus = {
  name: string;
  fqdn: string;
  role: string;
  os: string;
  vlan_ip: string;
  cpu: number;
  ram: number;
  proxmox_state: "running" | "stopped" | "unknown";
  tailscale_state: "online" | "offline" | "unknown";
  tailscale_ip: string | null;
};

export async function getBootstrapPhase(): Promise<string> {
  try {
    const s = await fs.readFile(STATUS_FILE, "utf8");
    return s.trim() || "unknown";
  } catch {
    return "unknown";
  }
}

export async function getLudusRangeStatus(): Promise<Record<string, any>> {
  const out = await run("ludus range status -j", 4000);
  if (out.startsWith("__error__")) return { error: out };
  try {
    return JSON.parse(out);
  } catch {
    return { raw: out };
  }
}

export async function getTailscalePeers(): Promise<Record<string, { ip: string; online: boolean }>> {
  const out = await run("tailscale status --json", 4000);
  const peers: Record<string, { ip: string; online: boolean }> = {};
  if (out.startsWith("__error__")) return peers;
  try {
    const data = JSON.parse(out);
    const all = { ...(data.Self ? { [data.Self.ID]: data.Self } : {}), ...(data.Peer ?? {}) };
    for (const node of Object.values<any>(all)) {
      const host = (node.HostName ?? "").toLowerCase();
      const ip = (node.TailscaleIPs ?? [])[0] ?? null;
      if (host && ip) peers[host] = { ip, online: !!node.Online };
    }
  } catch { /* ignore */ }
  return peers;
}

export async function getVmStatuses(): Promise<VmStatus[]> {
  const [range, peers] = await Promise.all([getLudusRangeStatus(), getTailscalePeers()]);
  const proxmoxByName = new Map<string, string>();
  for (const vm of (range.VMs ?? range.vms ?? [])) {
    const n = (vm.name ?? vm.Name ?? "").toLowerCase();
    proxmoxByName.set(n, (vm.powerState ?? vm.PowerState ?? "unknown").toString().toLowerCase());
  }
  return VM_INVENTORY.map((vm) => {
    const fqdn = `${RANGE_ID}-${vm.name}`;
    const ts = peers[fqdn] ?? peers[fqdn.toLowerCase()];
    const px = [...proxmoxByName.entries()].find(([k]) => k.includes(vm.name));
    return {
      name: vm.name,
      fqdn,
      role: vm.role,
      os: vm.os,
      vlan_ip: `10.${RANGE_ID}.20.${vm.vlan_ip}`,
      cpu: vm.cpu,
      ram: vm.ram,
      proxmox_state: (px?.[1] === "running" ? "running" : px ? "stopped" : "unknown") as VmStatus["proxmox_state"],
      tailscale_state: ts ? (ts.online ? "online" : "offline") : "unknown",
      tailscale_ip: ts?.ip ?? null,
    };
  });
}

// Single-shot "Run once" trigger. Hits the real upstream Attack Range API
// route (POST /attack-range/simulate) with the schema it actually expects
// (SimulateRequest: attack_range_id, target, techniques[]) — the API has no
// loop/random/interval/exclude concept; that's CLI-only
// (attack_range.py simulate --loop, driven by scripts/start-continuous-sim.sh
// --laptop) or the separate Atomic Runner Windows-service path (--windows).
export async function triggerSimulate(opts: {
  target: string;
  techniques?: string;
}): Promise<{ ok: boolean; detail: string }> {
  const techniques = (opts.techniques ?? "")
    .split(",")
    .map((t) => t.trim())
    .filter(Boolean);
  if (techniques.length === 0) {
    return { ok: false, detail: "No techniques specified." };
  }
  const body = {
    attack_range_id: ATTACK_RANGE_ID,
    target: opts.target,
    techniques,
  };
  try {
    const r = await fetch(`${ATTACK_RANGE_API}/attack-range/simulate`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const text = await r.text();
    return { ok: r.ok, detail: text };
  } catch (e: any) {
    return { ok: false, detail: `Attack Range API unreachable: ${e?.message ?? e}` };
  }
}

export async function runIsolationCheck(): Promise<{ ok: boolean; log: string }> {
  const out = await run(
    "bash /opt/attackrangelocal/scripts/verify-isolation.sh 2>&1 || true",
    60000,
  );
  return { ok: !out.includes("FAIL") && !out.startsWith("__error__"), log: out };
}

export async function getAtomicRunnerStatus(target: string): Promise<{
  installed: boolean;
  running: boolean;
  log: string;
}> {
  const cmd = `ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new ` +
    `Administrator@${target} 'powershell -NoProfile -Command "Get-Service atomicrunnerservice ` +
    `| Select-Object -Property Name,Status,StartType | Format-List"' 2>&1 || true`;
  const out = await run(cmd, 8000);
  const installed = /atomicrunnerservice/i.test(out);
  const running = /Status\s*:\s*Running/i.test(out);
  return { installed, running, log: out };
}

// Curated technique catalogue for the simulate page. Mirrors the
// safe-to-loop set in ansible/files/atomic-schedule.csv plus a few extra
// one-shots that are useful manually.
export const TECHNIQUES: Array<{ id: string; name: string; tactic: string; loopSafe: boolean }> = [
  { id: "T1059.001", name: "PowerShell",                        tactic: "Execution",         loopSafe: true  },
  { id: "T1082",     name: "System Information Discovery",      tactic: "Discovery",         loopSafe: true  },
  { id: "T1057",     name: "Process Discovery",                 tactic: "Discovery",         loopSafe: true  },
  { id: "T1087.001", name: "Account Discovery: Local",          tactic: "Discovery",         loopSafe: true  },
  { id: "T1087.002", name: "Account Discovery: Domain",         tactic: "Discovery",         loopSafe: true  },
  { id: "T1046",     name: "Network Service Discovery",         tactic: "Discovery",         loopSafe: true  },
  { id: "T1069.001", name: "Permission Groups: Local",          tactic: "Discovery",         loopSafe: true  },
  { id: "T1069.002", name: "Permission Groups: Domain",         tactic: "Discovery",         loopSafe: true  },
  { id: "T1547.001", name: "Registry Run Keys",                 tactic: "Persistence",       loopSafe: true  },
  { id: "T1053.002", name: "Scheduled Task: at",                tactic: "Execution",         loopSafe: true  },
  { id: "T1033",     name: "System Owner/User Discovery",       tactic: "Discovery",         loopSafe: true  },
  { id: "T1518",     name: "Software Discovery",                tactic: "Discovery",         loopSafe: true  },
  { id: "T1016",     name: "System Network Config Discovery",   tactic: "Discovery",         loopSafe: true  },
  { id: "T1083",     name: "File and Directory Discovery",      tactic: "Discovery",         loopSafe: true  },
  { id: "T1552.001", name: "Credentials in Files",              tactic: "Credential Access", loopSafe: true  },
  { id: "T1070.001", name: "Clear Windows Event Logs",          tactic: "Defense Evasion",   loopSafe: true  },
  { id: "T1070.006", name: "Timestomp",                         tactic: "Defense Evasion",   loopSafe: true  },
  { id: "T1036.005", name: "Masquerading: Legit Name",          tactic: "Defense Evasion",   loopSafe: true  },
  { id: "T1007",     name: "System Service Discovery",          tactic: "Discovery",         loopSafe: true  },
  { id: "T1012",     name: "Query Registry",                    tactic: "Discovery",         loopSafe: true  },
  { id: "T1135",     name: "Network Share Discovery",           tactic: "Discovery",         loopSafe: true  },
  { id: "T1482",     name: "Domain Trust Discovery",            tactic: "Discovery",         loopSafe: true  },
  { id: "T1018",     name: "Remote System Discovery",           tactic: "Discovery",         loopSafe: true  },
  { id: "T1003.001", name: "LSASS Memory Dump",                 tactic: "Credential Access", loopSafe: false },
  { id: "T1003.006", name: "DCSync",                            tactic: "Credential Access", loopSafe: false },
  { id: "T1078.002", name: "Domain Accounts",                   tactic: "Initial Access",    loopSafe: false },
  { id: "T1021.002", name: "SMB/Admin Shares (lateral)",        tactic: "Lateral Movement",  loopSafe: false },
];

export const RANGE = { id: RANGE_ID };
