# Attack Range v5 patches

We don't maintain a hard fork of `splunk/attack_range`. Instead
`attack_range_fork/bootstrap.sh` clones upstream at a pinned tag
(`ATTACK_RANGE_REF`, default `v5.0.0`) into `attack_range_fork/upstream/`,
copies in the files under `new-files/`, then applies source edits with
`attack_range_fork/apply-patches.py`.

## The verification gate (read this first)

`apply-patches.py` **exits non-zero** unless, after patching:

1. every patch's marker string is present on disk, AND
2. every file it touched still parses as valid Python.

`bootstrap.sh` aborts on that non-zero exit. This is deliberate and it is
the most important property of the script.

**Why:** an earlier version of the patcher matched on regexes that had
drifted out of sync with upstream. It degraded to a near-total no-op —
**11 of 12 patches silently failed** — while still printing `Done.` and
exiting 0. The fork looked fine and was not. A patch failure must never
again be a warning you can scroll past.

If you see `PATCHING FAILED`, upstream changed shape. Open the file and
pattern it names, find the equivalent code, update the `Patch(...)` entry.
Do not work around it by skipping the patch: without them `local_ludus`
isn't a registered provider and Attack Range will try to reach a cloud API
that doesn't exist.

## Ground truth this targets

Verified against `splunk/attack_range@v5.0.0` (commit `5f63cd7`):

| Assumption | Reality |
|---|---|
| Config key | `general.cloud_provider` — **not** `general.provider` |
| Controller dispatch var | `self.cloud_provider_name` |
| AnsibleManager's copy | `self.cloud_provider` (a plain string) |
| Method signatures | all carry return annotations (`-> None:`, `-> tuple:`, `-> dict:`) |
| CLI provider validation | list-membership check in the controller `__init__`; there is **no** `choices=` in `attack_range.py` |
| CLI simulate dispatch | `controller.simulate(args.target, techniques)` — `techniques` is a **local** var parsed from `args.techniques` |
| `prompt_vpn_connection` | lives on `AnsibleManager`, not the controller |

## The 18 patches

### 1. Register `local_ludus` as a provider (3 patches)

| Patch | File | What |
|---|---|---|
| `provider-allowlist` | `attack_range_controller.py` | adds `"local_ludus"` to the accepted-provider list so `__init__` doesn't `sys.exit(1)` |
| `provider-import` | `attack_range_controller.py` | imports `LocalLudusProvider` next to the three cloud providers |
| `provider-dispatch` | `attack_range_controller.py` | adds the `elif` branch in `_init_cloud_provider` |

The provider itself is **copied in**, not patched:
`new-files/attack_range/cloud_providers/local_ludus_provider.py`.

It subclasses `BaseCloudProvider` and implements all **8** abstract methods
(`get_region`, `sanitize_name`, `check_backend_exists`, `create_backend`,
`delete_backend`, `import_ssh_key`, `delete_ssh_key`,
`update_backend_config`). Each is a logged no-op — Ludus already built the
VMs, there's no Terraform backend, no cloud keypair registry, no regions.

> If upstream adds an `@abstractmethod`, this class must implement it or
> the controller raises `TypeError` at construction.

### 2. Never reach Terraform (3 patches)

Ludus already owns the VM lifecycle, so every Terraform code path in the
controller is wrong for us — not just the VPN sub-step.

| Patch | File | What |
|---|---|---|
| `terraform-dir` | `attack_range_controller.py` | gives `_setup_directories()` an explicit `local_ludus` arm. Never used, but without it we silently land in the `else:  # aws` fall-through, which reads like intent |
| `build-shortcircuit` | `attack_range_controller.py` | returns from `build()` before `terraform_manager.update_variables()`. Saves the config, pulls in the static inventory, sets `status = "running"` so `simulate()` and the REST API work immediately |
| `destroy-shortcircuit` | `attack_range_controller.py` | returns from `destroy()` before `setup_remote_backend()`. There's no Terraform state and no cloud SSH key to clean up; `scripts/teardown.sh` removes the Ludus range itself |

`build()` runs Terraform for the **whole** build, not just a VPN phase —
there is no narrower seam to gate, which is why these short-circuits exist
alongside the `wg-gate-*` patches below rather than instead of them.

### 3. Bypass WireGuard — we use Tailscale (6 patches)

`wg-gate-*` early-return when the provider is `local_ludus`:

- `AnsibleManager.update_vpn_playbook`
- `AnsibleManager.update_vpn_config_playbook`
- `AnsibleManager._patch_wireguard_allowed_ips`
- `AnsibleManager._patch_wireguard_server_config`
- `AnsibleManager.prompt_vpn_connection`
- `AttackRangeController.build_vpn_phase` → returns `(None, None)`

### 4. Static inventory injection (1 patch)

`static-inventory` short-circuits
`AnsibleManager.update_inventory_attack_range_servers` to copy an
operator-supplied inventory instead of deriving one from Terraform outputs.

Path comes from `$LOCAL_LUDUS_INVENTORY`, default `/inventory.yml`
(mounted by `docker/attack-range.compose.yml` from `ansible/inventory.yml`).
Falls back to the generated inventory with a warning if the file is absent.

### 5. Continuous simulation (4 patches)

Upstream has **no** loop/scheduled mode — verified by grepping
`continuous|loop|interval|schedule` across `attack_range/`, `api/` and
`attack_range.py` on both `v5.0.0` and `develop`. These patches are ours
to keep.

| Patch | What |
|---|---|
| `simulate-flags` | adds `--loop`, `--random`, `--interval`, `--exclude` to the simulate subparser |
| `simulate-allow-random` | stops the CLI hard-exiting on empty `--techniques` when `--random` was given |
| `simulate-dispatch` | forwards the four new flags to `controller.simulate(...)` |
| `simulate-loop` | renames the original `simulate` body to `_simulate_once` and wraps it in a loop that sleeps `--interval` minutes and, with `--random`, draws a technique from the Atomics index CSVs minus `--exclude` |

Atomics index glob is overridable via `$ATOMICS_INDEX_GLOB`; default
`/opt/atomic-red-team/atomics/Indexes/Indexes-CSV/*.csv`. Falls back to
`T1082` with a warning if the index isn't present.

### 6. Stable `attack_range_id` (1 patch)

`build_action()` always passes `generate_id=True`, minting a fresh UUID on
every `attack_range build`. `local_ludus` is a persistent lab, not a
disposable cloud stack, so `fixed-id` peeks at the template and passes
`generate_id=False` when `general.cloud_provider` is `local_ludus`, keeping
the `attack_range_id` baked into
`new-files/templates/local_ludus/default.yml` (`local-ludus-range`).

That fixed id is what makes `scripts/start-attack-range.sh`'s seed `build`
idempotent, and it's the id the UI sends in its `POST
/attack-range/simulate` body.

The peek uses `yaml.safe_load`, which `attack_range.py` already imports.
(It must not use a `load_config` helper — no such name exists in `v5.0.0`,
and inside the `except Exception` guard a `NameError` would silently turn
this patch into a no-op.)

## Not a patch: the compose override

`docker/attack-range.compose.yml` lives in *this* repo, not the fork. It
sets host networking (so the container resolves lab VMs over the host's
tailnet by MagicDNS) and mounts `ansible/inventory.yml` at `/inventory.yml`
on **both** the `attack_range` and `api` services.

Both mounts matter: upstream tags the `attack_range` service
`profiles: [cli]`, so `up -d` never starts it — the long-running service is
`api`, and it's the one that needs `/inventory.yml` for the
`static-inventory` short-circuit to have something to copy.

```bash
docker compose \
  -f attack_range_fork/upstream/docker/docker-compose.yml \
  -f docker/attack-range.compose.yml \
  up -d
```

The CLI service is invoked directly instead
(`docker compose ... run --rm attack_range <args>`), which is how
`scripts/start-attack-range.sh` seeds the range and how
`scripts/start-continuous-sim.sh --laptop` drives the loop.

## Following a new upstream release

```bash
# 1. Point at the new tag
ATTACK_RANGE_REF=v5.1.0 attack_range_fork/bootstrap.sh

# 2. If it aborts with PATCHING FAILED, the message names the exact file
#    and pattern. Open the upstream file, find the equivalent code, update
#    the Patch(...) entry in apply-patches.py, re-run.
```

The patcher is string/regex based rather than a `.patch` file precisely so
that unrelated churn (whitespace, neighbouring lines, import reordering)
doesn't break it — only a change to the specific construct does.

## Known upstream drift on `develop`

`develop` is ~44 commits past `v5.0.0`. Things that would need pattern
updates before you could pin to it:

- `simulate()` became
  `simulate(self, target, techniques=None, atomics=None, atomic_files=None) -> dict`
- `build_vpn_phase` became a multi-line signature with a third
  `terraform_running_callback` parameter
- `BaseCloudProvider.update_backend_config(dict, ...)` was renamed to
  `write_backend_config(BackendParams, ...)` and a new abstract
  `get_backend_params()` was added — **this alone breaks
  `local_ludus_provider.py`** until it implements the new method

We stay on `v5.0.0` until there's a reason not to.
