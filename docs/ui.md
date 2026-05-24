# Replacement Attack Range UI

Upstream Splunk Attack Range v5 ships an Astro web UI (`app/`, port 4321)
built around the cloud-provider lifecycle: pick AWS/Azure/GCP, build
infrastructure, manage WireGuard client configs, share access with
teammates, destroy when done. **None of that applies here.** On
local_ludus, infrastructure is owned by Ludus, the VPN is Tailscale, and
"destroy" goes through `scripts/teardown.sh`.

So we **replace** the upstream UI with one tailored to this deployment.

## What's in it

Five pages, one purpose each:

| Path | Shows |
|---|---|
| `/` Range overview | VM grid (Proxmox + Tailscale state per host), running/online counts, lockdown badge, deep links |
| `/simulate` | Pick a target + technique(s), run via the patched Attack Range API. Filter, random pick, destructive techniques flagged |
| `/continuous` | Atomic Runner service status on win-client1, schedule, start/stop, list of looped vs excluded techniques |
| `/network` | Lockdown phase, permanent egress allowlist, hard-blocked nets, one-click verify-isolation runner |
| `/forest` | AD root, domain admin (password reveal), topology table, ready-to-paste DC commands |

Plus JSON endpoints under `/api/*` for scripting:
- `GET  /api/status`   — bootstrap phase + raw `ludus range status`
- `GET  /api/vms`      — VM status list (Proxmox state, Tailscale presence)
- `POST /api/simulate` — `{ target, techniques }` → forwards to Attack Range API
- `POST /api/isolation`— runs `scripts/verify-isolation.sh`, returns log
- `POST /api/continuous` form-encoded `action=start|stop`

## Visual

Dark theme, zinc + cyan accent, monospace for technical fields, Inter for
chrome. Tight cards, badges with dot indicators (●/○), no marketing fluff.
Designed to read fluently in a 14" laptop window over Tailscale.

## How it runs

The UI is a small Astro 5 app with the Node adapter (server-rendered so
the API routes can shell out to `ludus` and `tailscale` on the host).
`ui/Dockerfile` produces a single image; `docker/attack-range.compose.yml`
adds the `ui` service alongside the patched Attack Range and disables the
upstream `app` service via a `disabled-upstream-ui` profile.

Start everything together with `scripts/start-attack-range.sh` (which
already does the right compose invocation), or manually:

```bash
docker compose \
  -f attack_range_fork/upstream/docker/docker-compose.yml \
  -f docker/attack-range.compose.yml \
  up -d --build
```

UI: <http://localhost:4321> (same port as upstream, so bookmarks survive).

## Dev loop

Iterate on the UI without rebuilding the container:

```bash
cd ui
npm install
RANGE_ID=42 AD_DOMAIN_FQDN=range.local AD_DOMAIN_ADMIN=rangeadmin \
  ATTACK_RANGE_API=http://localhost:4000 \
  STATUS_FILE=/var/lib/ludus-bootstrap/status \
  npm run dev   # http://localhost:4321
```

If `ludus` / `tailscale` aren't on your laptop's PATH, the API routes
return graceful empty/error states — the UI still renders.

## Why a full replacement and not a fork

Upstream's UI is tightly coupled to the cloud-provider lifecycle: most
components assume a Terraform-driven build, an existing WireGuard router,
the share-by-client-config flow. A patch would either delete most of the
component tree or leave dead UI surface. A clean rewrite at ~15 small
files is shorter and easier to maintain across upstream releases — the
fork's REST API on port 4000 is stable; that's all we depend on.
