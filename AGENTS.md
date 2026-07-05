# AGENTS.md

## Cursor Cloud specific instructions

This repo is primarily an **infrastructure/deployment toolkit** for running Splunk
Attack Range v5 on a local Proxmox box (Ludus + Ansible + shell scripts + an
unattended ISO pipeline). The full product **cannot run in a cloud dev VM** — it
needs bare-metal/nested Proxmox, 16–30 GB RAM, Tailscale credentials, and hours of
provisioning. Do not attempt to run `scripts/deploy-range.sh`, Ludus, Ansible
playbooks, or the generated ISO as a VM here.

The unattended ISO build pipeline can be exercised in Cursor Cloud when the
required build tools and credentials are available. Building an ISO with
`scripts/build-iso-wizard.sh` or `iso/build-iso.sh` is allowed; booting or
validating the resulting ISO in a VM probably is not.

The Astro web UI in `ui/` (Node 22) is also runnable in this environment.
Everything below refers to it. See `docs/ui.md` for the full tour.

### Running the UI (dev loop)

```bash
cd ui
RANGE_ID=42 AD_DOMAIN_FQDN=range.local AD_DOMAIN_ADMIN=rangeadmin \
  ATTACK_RANGE_API=http://localhost:4000 \
  STATUS_FILE=/var/lib/ludus-bootstrap/status \
  npm run dev            # http://localhost:4321
```

- `npm run build` — production build (this is the closest thing to a full check; it passes).
- `npm run preview` — serve the built output on port 4321.
- There is **no `lint` or `check` script** in `package.json`. `npx astro check`
  reports pre-existing type errors only because `@types/node` is not a declared
  dependency (the `/api/*` routes use `node:child_process` etc.). These do **not**
  affect `npm run build` or runtime — do not "fix" them unless asked.

### Expected graceful degradation (not a bug)

The UI is server-rendered and its `/api/*` routes shell out to `ludus` /
`tailscale` and fetch the Attack Range API on port 4000. None of those exist in
this environment, so:

- `/api/status` returns `ludus: not found` error state.
- `/api/simulate` (the "Run once" button) returns
  `Attack Range API unreachable: fetch failed`.
- `/api/vms` still works — the VM grid is derived from static config, not live state.

This is **by design** (documented in `docs/ui.md`): the UI renders fully and
degrades to empty/error states when the host tools/backend are absent. Client-side
features (technique filtering, random pick, password reveal) work without any backend.
