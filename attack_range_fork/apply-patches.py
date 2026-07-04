#!/usr/bin/env python3
"""
String-based patcher that adds the `local_ludus` provider hooks to a fresh
checkout of splunk/attack_range. Matches on exact (but minimal) code
fragments taken from the pinned ATTACK_RANGE_REF tag, so a `WARN: literal
text not found` means upstream has drifted and the anchor below needs to be
updated to match the new source (see docs/attack-range-patches.md).

Usage:
    python3 apply-patches.py <path-to-upstream-clone>

Patches applied (idempotent -- safe to re-run):

  Patch 1   Register `local_ludus` as a valid provider: extend the
            AttackRangeController's cloud_provider allow-list, wire up
            _init_cloud_provider()/_setup_directories() to recognise it.

  Patch 2   Short-circuit AttackRangeController.build() and .destroy() for
            local_ludus: Ludus already created and destroys the VMs, so
            there is no Terraform/WireGuard phase to run. build() copies the
            static inventory and marks general.status = "running" directly;
            destroy() just removes the config file.

  Patch 3   In managers/ansible_manager.py::update_inventory_attack_range_servers,
            short-circuit to read /inventory.yml when provider == local_ludus,
            instead of synthesizing AWS-shaped (10.0.2.x / SSH-key) entries
            from the `attack_range:` config list.

  Patch 4   In attack_range.py, add --loop / --interval / --random / --exclude
            to the simulate subparser and forward them into
            AttackRangeController.simulate(). In attack_range_controller.py,
            wrap the existing simulate() body (renamed to _simulate_inner) in
            a loop driven by those flags, with random-technique selection
            pulled from the Atomic Red Team Indexes CSVs.

  Patch 5   In attack_range.py build_action(), reuse the fixed
            attack_range_id baked into templates/local_ludus/default.yml
            instead of minting a new UUID on every `build` call -- local_ludus
            is a persistent lab, not a disposable cloud stack.

The companion `new-files/` tree copies in:
  - attack_range/cloud_providers/local_ludus_provider.py
  - templates/local_ludus/default.yml
"""

from __future__ import annotations
import re
import sys
from pathlib import Path


def insert_after(file: Path, anchor: str, insert: str, marker: str) -> None:
    """Insert `insert` immediately after the first occurrence of `anchor`.
    Skips if `marker` already present in the file (idempotent)."""
    text = file.read_text()
    if marker in text:
        print(f"  SKIP  {file.name} (marker {marker!r} already present)")
        return
    if anchor not in text:
        print(f"  WARN  {file.name}: anchor not found for {marker!r}")
        return
    new = text.replace(anchor, anchor + insert, 1)
    file.write_text(new)
    print(f"  OK    {file.name}: applied {marker}")


def replace_literal(file: Path, old: str, new: str, marker: str) -> None:
    """Replace the first occurrence of the exact substring `old` with `new`.
    Skips if `marker` already present in the file (idempotent)."""
    text = file.read_text()
    if marker in text:
        print(f"  SKIP  {file.name} ({marker} already present)")
        return
    if old not in text:
        print(f"  WARN  {file.name}: literal text not found for {marker!r}")
        return
    text = text.replace(old, new, 1)
    file.write_text(text)
    print(f"  OK    {file.name}: applied {marker}")


def regex_patch(file: Path, pattern: str, replacement: str, marker: str) -> None:
    text = file.read_text()
    if marker in text:
        print(f"  SKIP  {file.name} ({marker} already present)")
        return
    new, n = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE | re.DOTALL)
    if n == 0:
        print(f"  WARN  {file.name}: pattern not matched for {marker!r}")
        return
    file.write_text(new)
    print(f"  OK    {file.name}: applied {marker}")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    upstream = Path(sys.argv[1]).resolve()
    if not upstream.is_dir():
        print(f"Not a directory: {upstream}", file=sys.stderr)
        return 1

    ar_pkg = upstream / "attack_range"
    cli = upstream / "attack_range.py"
    controller = ar_pkg / "attack_range_controller.py"
    ansible_mgr = ar_pkg / "managers" / "ansible_manager.py"

    print(f"Patching {upstream} ...")

    # ================================================================
    # Patch 1: register local_ludus as a valid provider
    # ================================================================
    if controller.exists():
        replace_literal(
            controller,
            'if self.cloud_provider_name not in ["aws", "azure", "gcp"]:',
            'if self.cloud_provider_name not in ["aws", "azure", "gcp", "local_ludus"]:  # PATCH:local_ludus-provider-allowlist',
            "PATCH:local_ludus-provider-allowlist",
        )

        replace_literal(
            controller,
            '        elif self.cloud_provider_name == "gcp":\n'
            '            self.terraform_dir = os.path.join(os.path.dirname(__file__), "../terraform/gcp")\n'
            '        else:  # aws\n',
            '        elif self.cloud_provider_name == "gcp":\n'
            '            self.terraform_dir = os.path.join(os.path.dirname(__file__), "../terraform/gcp")\n'
            '        elif self.cloud_provider_name == "local_ludus":\n'
            '            # PATCH:local_ludus-terraform-dir -- unused: local_ludus never calls terraform_manager.\n'
            '            self.terraform_dir = os.path.join(os.path.dirname(__file__), "../terraform/aws")\n'
            '        else:  # aws\n',
            "PATCH:local_ludus-terraform-dir",
        )

        replace_literal(
            controller,
            '        elif self.cloud_provider_name == "gcp":\n'
            '            self.cloud_provider = GCPProvider(self.config, self.logger)\n'
            '        else:  # aws\n'
            '            self.cloud_provider = AWSProvider(self.config, self.logger)\n',
            '        elif self.cloud_provider_name == "gcp":\n'
            '            self.cloud_provider = GCPProvider(self.config, self.logger)\n'
            '        elif self.cloud_provider_name == "local_ludus":\n'
            '            # PATCH:local_ludus-provider-init\n'
            '            from .cloud_providers.local_ludus_provider import LocalLudusProvider\n'
            '            self.cloud_provider = LocalLudusProvider(self.config, self.logger)\n'
            '        else:  # aws\n'
            '            self.cloud_provider = AWSProvider(self.config, self.logger)\n',
            "PATCH:local_ludus-provider-init",
        )

    # ================================================================
    # Patch 2: short-circuit build() and destroy() for local_ludus --
    # Ludus already owns VM lifecycle, there is no Terraform/VPN phase.
    # ================================================================
    if controller.exists():
        replace_literal(
            controller,
            '        # Update terraform variables with the updated config (including attack_range_id)\n'
            '        self.terraform_manager.update_variables()\n',
            '        # PATCH:local_ludus-build-shortcircuit -- Ludus already provisioned\n'
            '        # the VMs (see scripts/deploy-range.sh); there is no Terraform/VPN\n'
            '        # phase to run here. Persist the config and mark the range running\n'
            '        # so simulate()/the API work immediately.\n'
            '        if self.cloud_provider_name == "local_ludus":\n'
            '            self.config_manager.save_config_to_attack_range(attack_range_id)\n'
            '            self.ansible_manager.update_inventory_attack_range_servers()\n'
            '            self.config_manager.update_status("running")\n'
            '            self.logger.info("local_ludus: VMs already provisioned by Ludus; marked attack range as running.")\n'
            '            self.logger.info(f"Attack Range ID: {attack_range_id}")\n'
            '            return\n\n'
            '        # Update terraform variables with the updated config (including attack_range_id)\n'
            '        self.terraform_manager.update_variables()\n',
            "PATCH:local_ludus-build-shortcircuit",
        )

        replace_literal(
            controller,
            '        self.logger.info("[action] > destroy\\n")\n\n'
            '        # Setup remote backend (S3/Azure Storage/GCS) if needed\n'
            '        self.backend_manager.setup_remote_backend()\n',
            '        self.logger.info("[action] > destroy\\n")\n\n'
            '        # PATCH:local_ludus-destroy-shortcircuit -- no Terraform infra to\n'
            '        # tear down; use scripts/teardown.sh to remove the Ludus VMs.\n'
            '        if self.cloud_provider_name == "local_ludus":\n'
            '            self.logger.info("local_ludus: nothing to destroy via Terraform. Run scripts/teardown.sh to remove the Ludus range.")\n'
            '            if self.config_path:\n'
            '                self.config_manager.remove_config()\n'
            '            return\n\n'
            '        # Setup remote backend (S3/Azure Storage/GCS) if needed\n'
            '        self.backend_manager.setup_remote_backend()\n',
            "PATCH:local_ludus-destroy-shortcircuit",
        )

    # ================================================================
    # Patch 3: static inventory injection (ansible_manager.py)
    # ================================================================
    if ansible_mgr.exists():
        insert_after(
            ansible_mgr,
            "import json\nimport os\n",
            "import shutil  # PATCH:local_ludus-imports\n",
            "PATCH:local_ludus-imports",
        )

        replace_literal(
            ansible_mgr,
            '        self.logger.info("Updating inventory with attack_range servers from config...")\n\n'
            '        inventory = self._load_inventory()\n',
            '        self.logger.info("Updating inventory with attack_range servers from config...")\n\n'
            '        # PATCH:local_ludus-static-inventory -- Ludus already generated a\n'
            '        # complete, working inventory (Tailscale MagicDNS hostnames, correct\n'
            '        # per-OS connection vars). Copy it verbatim instead of synthesizing\n'
            '        # AWS-style 10.0.2.x entries from the attack_range: config list.\n'
            '        if self.cloud_provider == "local_ludus":\n'
            '            src = "/inventory.yml"\n'
            '            if os.path.exists(src):\n'
            '                shutil.copy(src, self.inventory_path)\n'
            '                self.logger.info(f"local_ludus: copied static inventory from {src}")\n'
            '                return\n'
            '            self.logger.warning(f"local_ludus: {src} not found; leaving inventory untouched")\n'
            '            return\n\n'
            '        inventory = self._load_inventory()\n',
            "PATCH:local_ludus-static-inventory",
        )

    # ================================================================
    # Patch 4: simulate --loop / --random / --interval / --exclude
    # ================================================================
    if cli.exists():
        # 4a. Add flags to the simulate subparser (anchor: the --techniques
        # argument definition, which ends right before share_parser.set_defaults
        # would be added elsewhere -- anchor on the closing paren + newline).
        regex_patch(
            cli,
            r'(simulate_parser\.add_argument\(\s*"-te",\s*"--techniques".*?\)\s*\n)',
            r'\1'
            r'    simulate_parser.add_argument("--loop", action="store_true",\n'
            r'        help="[PATCH:local_ludus-simulate-flags] run in infinite loop")\n'
            r'    simulate_parser.add_argument("--random", action="store_true",\n'
            r'        help="pick random techniques each iteration")\n'
            r'    simulate_parser.add_argument("--interval", type=int, default=30,\n'
            r'        help="minutes between iterations (default 30)")\n'
            r'    simulate_parser.add_argument("--exclude", type=str, default="",\n'
            r'        help="comma-separated T-IDs to never run")\n',
            "PATCH:local_ludus-simulate-flags",
        )

        # 4b. Forward the new args to controller.simulate().
        replace_literal(
            cli,
            "    controller.simulate(args.target, techniques)\n",
            "    controller.simulate(args.target, techniques, "
            "loop=getattr(args, \"loop\", False), "
            "random_pick=getattr(args, \"random\", False), "
            "interval_minutes=getattr(args, \"interval\", 30), "
            "exclude=getattr(args, \"exclude\", \"\"))  # PATCH:local_ludus-simulate-dispatch\n",
            "PATCH:local_ludus-simulate-dispatch",
        )

        # 4c. local_ludus is a persistent lab: reuse the fixed attack_range_id
        # baked into the template instead of minting a new UUID on every build.
        replace_literal(
            cli,
            "        # Prepare config from template (loads template, adds metadata, saves to config folder)\n"
            "        config, config_path, attack_range_id = prepare_config_from_template(\n"
            "            args.template,\n"
            "            templates_dir,\n"
            "            config_dir,\n"
            "            generate_id=True\n"
            "        )\n",
            "        # Prepare config from template (loads template, adds metadata, saves to config folder)\n"
            "        # PATCH:local_ludus-fixed-id -- local_ludus is a persistent lab (Ludus\n"
            "        # owns the VMs); reuse the template's fixed attack_range_id instead of\n"
            "        # minting a new UUID on every `build` invocation.\n"
            "        try:\n"
            "            _peek_cfg = load_config(resolve_template_path(args.template, templates_dir)) or {}\n"
            "            _is_local_ludus = str(_peek_cfg.get(\"general\", {}).get(\"cloud_provider\", \"\")).lower() == \"local_ludus\"\n"
            "        except Exception:\n"
            "            _is_local_ludus = False\n"
            "        config, config_path, attack_range_id = prepare_config_from_template(\n"
            "            args.template,\n"
            "            templates_dir,\n"
            "            config_dir,\n"
            "            generate_id=not _is_local_ludus\n"
            "        )\n",
            "PATCH:local_ludus-fixed-id",
        )

    if controller.exists():
        # 4d. Wrap simulate(): rename the existing method to _simulate_inner
        # (body untouched) and add a new simulate() wrapper in front of it
        # that understands loop/random_pick/interval_minutes/exclude.
        replace_literal(
            controller,
            "    def simulate(self, target: str, techniques: list) -> dict:\n",
            '    def simulate(self, target: str, techniques: list, loop: bool = False,\n'
            '                 random_pick: bool = False, interval_minutes: int = 30,\n'
            '                 exclude: str = "") -> dict:\n'
            '        """\n'
            '        [PATCH:local_ludus-simulate-sig] Run Atomic Red Team techniques against\n'
            '        a target, optionally forever with randomly-chosen non-excluded techniques.\n'
            '        Delegates each iteration to _simulate_inner (the original simulate() body).\n'
            '        """\n'
            "        if not loop:\n"
            "            run_techniques = [self._pick_random_technique(exclude)] if random_pick else techniques\n"
            "            return self._simulate_inner(target, run_techniques)\n\n"
            "        excluded = {t.strip() for t in (exclude or \"\").split(\",\") if t.strip()}\n"
            '        self.logger.info(f"simulate --loop: interval={interval_minutes}m exclude={excluded}")\n'
            "        last_output = None\n"
            "        while True:\n"
            "            chosen = [self._pick_random_technique(exclude)] if random_pick else techniques\n"
            "            try:\n"
            "                last_output = self._simulate_inner(target, chosen)\n"
            "            except Exception as e:\n"
            '                self.logger.warning(f"simulate iteration failed ({chosen}): {e}")\n'
            "            time.sleep(interval_minutes * 60)\n"
            "        return last_output\n\n"
            "    def _pick_random_technique(self, exclude: str = \"\") -> str:\n"
            '        """Pick a random non-excluded technique ID from the Atomic Red Team Indexes CSVs."""\n'
            "        import csv, glob, random\n"
            "        excluded = {t.strip() for t in (exclude or \"\").split(\",\") if t.strip()}\n"
            '        paths = sorted(glob.glob("/opt/atomic-red-team/atomics/Indexes/Indexes-CSV/*.csv"))\n'
            "        techs = set()\n"
            "        for p in paths:\n"
            '            with open(p, newline="") as fh:\n'
            "                for row in csv.DictReader(fh):\n"
            '                    tid = (row.get("Technique #") or "").strip()\n'
            '                    if tid.startswith("T") and tid not in excluded:\n'
            "                        techs.add(tid)\n"
            '        return random.choice(sorted(techs)) if techs else "T1082"\n\n'
            "    def _simulate_inner(self, target: str, techniques: list) -> dict:\n",
            "PATCH:local_ludus-simulate-sig",
        )

    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
