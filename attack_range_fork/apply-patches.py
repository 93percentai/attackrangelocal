#!/usr/bin/env python3
"""
Patch a clean checkout of splunk/attack_range so it can run against a
Ludus/Proxmox range instead of AWS/Azure/GCP.

Usage:
    python3 apply-patches.py <path-to-upstream-clone>

Design notes
------------
Every patch declares a MARKER string. A patch is considered applied iff its
marker is present in the file afterwards. `main()` re-reads every file at the
end and EXITS NON-ZERO if any marker is missing.

That verification gate exists because the previous version of this script
matched on regexes that silently stopped matching upstream, and the whole
thing degraded to a no-op that still printed "Done." — 11 of 12 patches were
failing in production without anyone noticing. Never let a patch failure be
a warning again.

Ground truth this targets (splunk/attack_range @ v5.0.0):
  * config key is `general.cloud_provider` (NOT `general.provider`)
  * dispatch variable is `self.cloud_provider_name`
  * AnsibleManager stores the provider string as `self.cloud_provider`
  * every def carries a return annotation: `-> None:` / `-> tuple:` / `-> dict:`
  * `attack_range.py` has NO `choices=`; it validates via a list membership
    check in the controller's __init__
  * CLI dispatch is `controller.simulate(args.target, techniques)` where
    `techniques` is a LOCAL variable parsed from args.techniques
"""

from __future__ import annotations

import ast
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Patch:
    """One source edit. `marker` must appear in `repl` so verification works."""
    name: str
    relpath: str
    pattern: str
    repl: str
    marker: str
    flags: int = re.MULTILINE
    required: bool = True
    applied: bool = field(default=False, init=False)


# --------------------------------------------------------------------------
# Patch definitions
# --------------------------------------------------------------------------

CONTROLLER = "attack_range/attack_range_controller.py"
ANSIBLE_MGR = "attack_range/managers/ansible_manager.py"
CLI = "attack_range.py"

PATCHES: list[Patch] = [

    # --- 1. Accept local_ludus as a valid provider -------------------------
    Patch(
        name="provider-allowlist",
        relpath=CONTROLLER,
        pattern=r'if self\.cloud_provider_name not in \["aws", "azure", "gcp"\]:',
        repl='if self.cloud_provider_name not in ["aws", "azure", "gcp", "local_ludus"]:  '
             '# PATCH:local_ludus-allowlist',
        marker="PATCH:local_ludus-allowlist",
    ),

    # --- 1b. Import + instantiate the provider ----------------------------
    Patch(
        name="provider-import",
        relpath=CONTROLLER,
        pattern=r'^from \.cloud_providers\.gcp_provider import GCPProvider$',
        repl='from .cloud_providers.gcp_provider import GCPProvider\n'
             'from .cloud_providers.local_ludus_provider import LocalLudusProvider  '
             '# PATCH:local_ludus-import',
        marker="PATCH:local_ludus-import",
    ),
    Patch(
        name="provider-dispatch",
        relpath=CONTROLLER,
        # Insert our branch ahead of the gcp branch inside _init_cloud_provider.
        pattern=r'(        elif self\.cloud_provider_name == "gcp":\n'
                r'            self\.cloud_provider = GCPProvider\(self\.config, self\.logger\)\n)',
        repl='        elif self.cloud_provider_name == "local_ludus":  '
             '# PATCH:local_ludus-dispatch\n'
             '            self.cloud_provider = LocalLudusProvider(self.config, self.logger)\n'
             r'\1',
        marker="PATCH:local_ludus-dispatch",
    ),

    # --- 1c. terraform_dir must resolve to *something* --------------------
    # _setup_directories() has no local_ludus arm, so we'd silently fall into
    # the `else:  # aws` branch. Nothing ever runs terraform for local_ludus
    # (see build/destroy short-circuits below), but leaving the path implicit
    # makes the fall-through look intentional when it isn't.
    Patch(
        name="terraform-dir",
        relpath=CONTROLLER,
        pattern=r'(        elif self\.cloud_provider_name == "gcp":\n'
                r'            self\.terraform_dir = os\.path\.join\(os\.path\.dirname\(__file__\), "\.\./terraform/gcp"\)\n)',
        repl=r'\1'
             '        elif self.cloud_provider_name == "local_ludus":\n'
             '            # PATCH:local_ludus-terraform-dir — never used; Ludus owns the\n'
             '            # VMs and build()/destroy() short-circuit before terraform.\n'
             '            self.terraform_dir = os.path.join(os.path.dirname(__file__), "../terraform/aws")\n',
        marker="PATCH:local_ludus-terraform-dir",
    ),

    # --- 1d. build() must not touch Terraform -----------------------------
    # Ludus already provisioned the VMs (scripts/deploy-range.sh). Persist the
    # config, pull in the static inventory, and mark the range running so the
    # API and `simulate` work immediately.
    Patch(
        name="build-shortcircuit",
        relpath=CONTROLLER,
        pattern=r'^(        # Update terraform variables with the updated config \(including attack_range_id\)\n'
                r'        self\.terraform_manager\.update_variables\(\)\n)',
        repl='        if self.cloud_provider_name == "local_ludus":\n'
             '            # PATCH:local_ludus-build-shortcircuit — no Terraform phase:\n'
             '            # Ludus created these VMs. Record the config and go straight\n'
             '            # to "running" so simulate()/the REST API are usable.\n'
             '            self.config_manager.save_config_to_attack_range(attack_range_id)\n'
             '            self.ansible_manager.update_inventory_attack_range_servers()\n'
             '            self.config_manager.update_status("running")\n'
             '            self.logger.info(\n'
             '                "local_ludus: VMs already provisioned by Ludus; "\n'
             '                f"attack range {attack_range_id} marked running.")\n'
             '            return\n\n'
             r'\1',
        marker="PATCH:local_ludus-build-shortcircuit",
    ),

    # --- 1e. destroy() must not run terraform destroy ---------------------
    Patch(
        name="destroy-shortcircuit",
        relpath=CONTROLLER,
        pattern=r'^(    def destroy\(self\) -> None:\n'
                r'(?:^        """(?:[^"]|"(?!""))*"""\n)?)',
        repl=r'\1'
             '        if self.cloud_provider_name == "local_ludus":\n'
             '            # PATCH:local_ludus-destroy-shortcircuit — there is no\n'
             '            # Terraform state and no cloud SSH key to clean up. Use\n'
             '            # scripts/teardown.sh to remove the Ludus range itself.\n'
             '            self.logger.info(\n'
             '                "local_ludus: nothing to destroy via Terraform. "\n'
             '                "Run scripts/teardown.sh to remove the Ludus range.")\n'
             '            if self.config_path:\n'
             '                self.config_manager.remove_config()\n'
             '            return\n',
        marker="PATCH:local_ludus-destroy-shortcircuit",
    ),

    # --- 2. Bypass WireGuard (we use Tailscale) ---------------------------
    # AnsibleManager keeps the provider string in self.cloud_provider.
    *[
        Patch(
            name=f"wg-gate-{fn}",
            relpath=ANSIBLE_MGR,
            pattern=rf'(^    def {fn}\(self[^\n]*\)\s*->\s*None:\n'
                    rf'(?:^        """(?:[^"]|"(?!""))*"""\n)?)',
            repl=r'\1'
                 '        if getattr(self, "cloud_provider", None) == "local_ludus":\n'
                 f'            return  # PATCH:local_ludus-wg-{fn}\n',
            marker=f"PATCH:local_ludus-wg-{fn}",
        )
        for fn in (
            "update_vpn_playbook",
            "update_vpn_config_playbook",
            "_patch_wireguard_allowed_ips",
            "_patch_wireguard_server_config",
            "prompt_vpn_connection",
        )
    ],

    # build_vpn_phase lives on the controller and returns a tuple.
    Patch(
        name="wg-gate-build_vpn_phase",
        relpath=CONTROLLER,
        pattern=r'(^    def build_vpn_phase\(self[^\n]*\)\s*->\s*tuple:\n'
                r'(?:^        """(?:[^"]|"(?!""))*"""\n)?)',
        repl=r'\1'
             '        if self.cloud_provider_name == "local_ludus":\n'
             '            # PATCH:local_ludus-wg-build_vpn_phase — Tailscale\n'
             '            # provides connectivity; there is no WireGuard router.\n'
             '            self.logger.info("local_ludus: skipping WireGuard phase")\n'
             '            return (None, None)\n',
        marker="PATCH:local_ludus-wg-build_vpn_phase",
    ),

    # --- 3. Static inventory injection ------------------------------------
    Patch(
        name="static-inventory",
        relpath=ANSIBLE_MGR,
        pattern=r'(^    def update_inventory_attack_range_servers\(self\)\s*->\s*None:\n'
                r'(?:^        """(?:[^"]|"(?!""))*"""\n)?)',
        repl=r'\1'
             '        if getattr(self, "cloud_provider", None) == "local_ludus":\n'
             '            # PATCH:local_ludus-static-inventory — Ludus already\n'
             '            # built the VMs; use the operator-supplied inventory\n'
             '            # instead of deriving one from Terraform outputs.\n'
             '            import os, shutil\n'
             '            src = os.environ.get("LOCAL_LUDUS_INVENTORY", "/inventory.yml")\n'
             '            if os.path.exists(src):\n'
             '                shutil.copy(src, self.inventory_path)\n'
             '                self.logger.info(f"local_ludus: inventory from {src}")\n'
             '                return\n'
             '            self.logger.warning(f"local_ludus: {src} missing; "\n'
             '                                "falling back to generated inventory")\n',
        marker="PATCH:local_ludus-static-inventory",
    ),

    # --- 4. Continuous simulate (--loop/--random/--interval/--exclude) -----
    # 4a: CLI flags. Upstream made --techniques optional in later commits but
    # v5.0.0 has required=True; we relax it so --random works standalone.
    Patch(
        name="simulate-flags",
        relpath=CLI,
        pattern=r'(    simulate_parser\.set_defaults\(func=simulate_action\))',
        repl='    # PATCH:local_ludus-simulate-flags\n'
             '    simulate_parser.add_argument("--loop", action="store_true",\n'
             '        help="repeat the simulation forever (Ctrl-C to stop)")\n'
             '    simulate_parser.add_argument("--random", action="store_true",\n'
             '        help="pick a random technique from the Atomics index each pass")\n'
             '    simulate_parser.add_argument("--interval", type=int, default=30,\n'
             '        help="minutes to sleep between passes when --loop (default 30)")\n'
             '    simulate_parser.add_argument("--exclude", type=str, default="",\n'
             '        help="comma-separated technique IDs to never run")\n'
             r'\1',
        marker="PATCH:local_ludus-simulate-flags",
    ),

    # 4b: don't hard-exit when --techniques is empty but --random was given.
    Patch(
        name="simulate-allow-random",
        relpath=CLI,
        pattern=r'(    techniques = \[t\.strip\(\) for t in args\.techniques\.split\(","\) if t\.strip\(\)\]\n)'
                r'    if not techniques:\n',
        repl='    # PATCH:local_ludus-simulate-allow-random\n'
             '    techniques = [t.strip() for t in (args.techniques or "").split(",") if t.strip()]\n'
             '    if not techniques and not getattr(args, "random", False):\n',
        marker="PATCH:local_ludus-simulate-allow-random",
    ),

    # 4c: forward the new flags. Upstream passes the LOCAL `techniques` list.
    Patch(
        name="simulate-dispatch",
        relpath=CLI,
        pattern=r'^    controller\.simulate\(args\.target, techniques\)$',
        repl='    controller.simulate(  # PATCH:local_ludus-simulate-dispatch\n'
             '        args.target,\n'
             '        techniques,\n'
             '        loop=getattr(args, "loop", False),\n'
             '        random_pick=getattr(args, "random", False),\n'
             '        interval_minutes=getattr(args, "interval", 30),\n'
             '        exclude=getattr(args, "exclude", ""),\n'
             '    )',
        marker="PATCH:local_ludus-simulate-dispatch",
    ),

    # 4d: controller.simulate gains the loop wrapper. The original body is
    # renamed to _simulate_once and called from the wrapper.
    Patch(
        name="simulate-loop",
        relpath=CONTROLLER,
        pattern=r'^    def simulate\(self, target: str, techniques: list\) -> dict:$',
        repl=(
            '    def simulate(self, target: str, techniques: list,  '
            '# PATCH:local_ludus-simulate-loop\n'
            '                 loop: bool = False, random_pick: bool = False,\n'
            '                 interval_minutes: int = 30, exclude: str = "") -> dict:\n'
            '        """Run techniques once, or forever when loop=True.\n'
            '\n'
            '        random_pick draws from the Atomic Red Team index CSVs that\n'
            '        ship with redcanaryco/atomic-red-team, minus `exclude`.\n'
            '        """\n'
            '        import csv, glob, os, random, time\n'
            '\n'
            '        excluded = {t.strip() for t in (exclude or "").split(",") if t.strip()}\n'
            '\n'
            '        def _pick() -> list:\n'
            '            idx = os.environ.get(\n'
            '                "ATOMICS_INDEX_GLOB",\n'
            '                "/opt/atomic-red-team/atomics/Indexes/Indexes-CSV/*.csv")\n'
            '            found = set()\n'
            '            for path in sorted(glob.glob(idx)):\n'
            '                try:\n'
            '                    with open(path, newline="") as fh:\n'
            '                        for row in csv.DictReader(fh):\n'
            '                            tid = (row.get("Technique #") or "").strip()\n'
            '                            if tid.startswith("T") and tid not in excluded:\n'
            '                                found.add(tid)\n'
            '                except OSError:\n'
            '                    continue\n'
            '            if not found:\n'
            '                self.logger.warning(\n'
            '                    f"no atomics index at {idx}; falling back to T1082")\n'
            '                return ["T1082"]\n'
            '            return [random.choice(sorted(found))]\n'
            '\n'
            '        if not loop:\n'
            '            return self._simulate_once(\n'
            '                target, _pick() if random_pick else techniques)\n'
            '\n'
            '        self.logger.info(\n'
            '            f"simulate --loop: every {interval_minutes}m, "\n'
            '            f"random={random_pick}, excluding {sorted(excluded)}")\n'
            '        result = {}\n'
            '        while True:\n'
            '            chosen = _pick() if random_pick else techniques\n'
            '            try:\n'
            '                result = self._simulate_once(target, chosen)\n'
            '            except Exception as exc:  # keep the loop alive\n'
            '                self.logger.warning(f"pass failed ({chosen}): {exc}")\n'
            '            time.sleep(interval_minutes * 60)\n'
            '        return result\n'
            '\n'
            '    def _simulate_once(self, target: str, techniques: list) -> dict:'
        ),
        marker="PATCH:local_ludus-simulate-loop",
    ),

    # --- 5. Keep a stable attack_range_id ---------------------------------
    # build_action() always passes generate_id=True, minting a fresh UUID on
    # every `build`. local_ludus is a persistent lab, not a disposable cloud
    # stack, so reuse the id baked into templates/local_ludus/default.yml.
    #
    # NB: this peeks at the template with `yaml`, which attack_range.py
    # already imports. (There is no `load_config` helper in v5.0.0 — using
    # one would raise NameError, get swallowed by the except, and turn this
    # patch into a silent no-op.)
    Patch(
        name="fixed-id",
        relpath=CLI,
        pattern=r'^(        config, config_path, attack_range_id = prepare_config_from_template\(\n'
                r'            args\.template,\n'
                r'            templates_dir,\n'
                r'            config_dir,\n)'
                r'            generate_id=True\n',
        repl='        # PATCH:local_ludus-fixed-id\n'
             '        try:\n'
             '            with open(resolve_template_path(args.template, templates_dir)) as _fh:\n'
             '                _peek = yaml.safe_load(_fh) or {}\n'
             '            _local_ludus = str(\n'
             '                _peek.get("general", {}).get("cloud_provider", "")\n'
             '            ).lower() == "local_ludus"\n'
             '        except Exception:\n'
             '            _local_ludus = False\n'
             r'\1'
             '            generate_id=not _local_ludus\n',
        marker="PATCH:local_ludus-fixed-id",
    ),
]


# --------------------------------------------------------------------------
# Engine
# --------------------------------------------------------------------------

def apply_patch(root: Path, p: Patch) -> str:
    """Return one of: applied | already | MISSING-FILE | NO-MATCH."""
    target = root / p.relpath
    if not target.exists():
        return "MISSING-FILE"

    text = target.read_text()
    if p.marker in text:
        p.applied = True
        return "already"

    new, n = re.subn(p.pattern, p.repl, text, count=1, flags=p.flags)
    if n == 0:
        return "NO-MATCH"

    target.write_text(new)
    p.applied = True
    return "applied"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    root = Path(sys.argv[1]).resolve()
    if not root.is_dir():
        print(f"not a directory: {root}", file=sys.stderr)
        return 1

    print(f"Patching {root}")
    failures: list[Patch] = []

    for p in PATCHES:
        status = apply_patch(root, p)
        symbol = {"applied": "OK  ", "already": "SKIP",
                  "NO-MATCH": "FAIL", "MISSING-FILE": "FAIL"}[status]
        print(f"  {symbol}  {p.name:34s} {p.relpath}  ({status})")
        if status in ("NO-MATCH", "MISSING-FILE") and p.required:
            failures.append(p)

    # ---- Verification gate -------------------------------------------
    # Re-read from disk. A patch counts as landed only if its marker is
    # actually in the file. This is what makes silent failure impossible.
    print("\nVerifying markers on disk...")
    unverified = []
    for p in PATCHES:
        target = root / p.relpath
        if not target.exists() or p.marker not in target.read_text():
            unverified.append(p)

    # Every file we edited must still be valid Python. A patch that lands
    # its marker but produces a SyntaxError is worse than one that misses.
    syntax_errors = []
    for relpath in sorted({p.relpath for p in PATCHES}):
        target = root / relpath
        if not target.exists():
            continue
        try:
            ast.parse(target.read_text(), filename=str(target))
        except SyntaxError as exc:
            syntax_errors.append((relpath, exc))

    if syntax_errors:
        print(f"\n{'=' * 66}")
        print("PATCHING PRODUCED INVALID PYTHON — fork is broken.")
        print(f"{'=' * 66}")
        for relpath, exc in syntax_errors:
            print(f"  {relpath}:{exc.lineno}: {exc.msg}")
            if exc.text:
                print(f"    {exc.text.rstrip()}")
        return 1

    if unverified or failures:
        print(f"\n{'=' * 66}")
        print("PATCHING FAILED — the fork is NOT usable as-is.")
        print(f"{'=' * 66}")
        for p in unverified:
            print(f"  missing marker: {p.marker}")
            print(f"    file:    {p.relpath}")
            print(f"    pattern: {p.pattern[:96]}")
        print(
            "\nUpstream almost certainly changed shape. Open the file(s) above,\n"
            "find the equivalent code, and update the pattern in this script.\n"
            "Do NOT ship an unpatched fork: local_ludus will not be a valid\n"
            "provider and Attack Range will try to talk to a cloud API."
        )
        return 1

    print(f"All {len(PATCHES)} patches verified present; "
          f"{len({p.relpath for p in PATCHES})} files parse as valid Python.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
