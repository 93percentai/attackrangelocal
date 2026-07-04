#!/usr/bin/env python3
"""
String-based patcher that adds the `local_ludus` provider hooks to a fresh
checkout of splunk/attack_range v5. Robust against minor line-number drift
because it matches on function definitions and code patterns, not line numbers.

Usage:
    python3 apply-patches.py <path-to-upstream-clone>

Patches applied (idempotent — safe to re-run):

  Patch 1   Register `local_ludus` as a valid cloud_provider in the controller.

  Patch 2   Gate WireGuard/VPN helpers when cloud_provider == local_ludus.

  Patch 3   Short-circuit inventory generation to /inventory.yml for local_ludus.

  Patch 4   simulate --loop / --random / --interval / --exclude + relaxed
            inventory host lookup for MagicDNS hostnames.

The companion `new-files/` tree copies in:
  - attack_range/cloud_providers/local_ludus_provider.py
  - templates/local_ludus/default.yml
"""

from __future__ import annotations
import re
import sys
from pathlib import Path


def regex_patch(file: Path, pattern: str, replacement: str, marker: str) -> None:
    text = file.read_text()
    if marker in text:
        print(f"  SKIP  {file.name} ({marker} already present)")
        return
    new, n = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE | re.DOTALL)
    if n == 0:
        print(f"  WARN  {file.name}: pattern not matched for {marker}")
        return
    file.write_text(new)
    print(f"  OK    {file.name}: applied {marker}")


def plain_patch(file: Path, old: str, new: str, marker: str) -> None:
    text = file.read_text()
    if marker in text:
        print(f"  SKIP  {file.name} ({marker} already present)")
        return
    if old not in text:
        print(f"  WARN  {file.name}: anchor not found for {marker}")
        return
    file.write_text(text.replace(old, new, 1))
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
    utils = ar_pkg / "utils.py"

    print(f"Patching {upstream} ...")

    # ---- Patch 1: register local_ludus cloud provider ----
    if controller.exists():
        regex_patch(
            controller,
            r'if self\.cloud_provider_name not in \["aws", "azure", "gcp"\]:',
            'if self.cloud_provider_name not in ["aws", "azure", "gcp", "local_ludus"]:',
            "PATCH:local_ludus-provider-list",
        )
        regex_patch(
            controller,
            r'Supported providers: aws, azure, gcp',
            'Supported providers: aws, azure, gcp, local_ludus',
            "PATCH:local_ludus-provider-error-msg",
        )
        regex_patch(
            controller,
            r'^(?P<indent>[ \t]*)else:\s+# aws\s*\n'
            r'(?P=indent)    self\.cloud_provider = AWSProvider\(self\.config, self\.logger\)',
            r'\g<indent>elif self.cloud_provider_name == "local_ludus":\n'
            r'\g<indent>    from .cloud_providers.local_ludus_provider import LocalLudusProvider\n'
            r'\g<indent>    self.cloud_provider = LocalLudusProvider(self.config, self.logger)\n'
            r'\g<indent>else:  # aws\n'
            r'\g<indent>    self.cloud_provider = AWSProvider(self.config, self.logger)',
            "PATCH:local_ludus-init-provider",
        )
        plain_patch(
            controller,
            '        self.logger.info("[action] > build\\n")\n\n        # Check if config file path is provided\n',
            '        self.logger.info("[action] > build\\n")\n\n'
            '        if self.cloud_provider_name == "local_ludus":\n'
            '            self.config_manager.update_status("running")\n'
            '            self.logger.info("local_ludus: build skipped (Ludus owns VMs)")\n'
            '            return  # PATCH:local_ludus-build-skip\n\n'
            '        # Check if config file path is provided\n',
            "PATCH:local_ludus-build-skip",
        )
        regex_patch(
            controller,
            r'if abort_check and abort_check\(\):\s*\n'
            r'            raise RuntimeError\("Build aborted"\)\s*\n'
            r'        # Update status to build_vpn',
            'if abort_check and abort_check():\n'
            '            raise RuntimeError("Build aborted")\n'
            '        if self.cloud_provider_name == "local_ludus":\n'
            '            self.config_manager.update_status("running")\n'
            '            self.logger.info("local_ludus: VPN phase skipped (Tailscale handles access)")\n'
            '            return None, None  # PATCH:local_ludus-vpn-build\n'
            '        # Update status to build_vpn',
            "PATCH:local_ludus-vpn-build",
        )

    # ---- Patch 2: gate WireGuard helpers in ansible_manager ----
    if ansible_mgr.exists():
        for fn in (
            "update_vpn_playbook",
            "update_vpn_config_playbook",
            "_patch_wireguard_allowed_ips",
            "_patch_wireguard_server_config",
            "prompt_vpn_connection",
        ):
            marker = f"PATCH:local_ludus-wg-gate-{fn}"
            regex_patch(
                ansible_mgr,
                rf'(?P<sig>^(?P<indent>[ \t]*)def\s+{fn}\s*\(self[^)]*\)[^:]*:\s*\n)',
                r'\g<sig>'
                r'\g<indent>    if self.cloud_provider == "local_ludus":\n'
                rf'\g<indent>        return  # {marker}\n',
                marker,
            )

        # ---- Patch 3: static inventory injection ----
        regex_patch(
            ansible_mgr,
            r'self\.logger\.info\("Updating inventory with attack_range servers from config\.\.\."\)\s*\n',
            'self.logger.info("Updating inventory with attack_range servers from config...")\n\n'
            '        # PATCH:local_ludus-static-inventory\n'
            '        if self.cloud_provider == "local_ludus":\n'
            '            import shutil, os\n'
            '            src = "/inventory.yml"\n'
            '            if os.path.exists(src):\n'
            '                shutil.copy(src, self.inventory_path)\n'
            '                self.logger.info(f"local_ludus: copied static inventory from {src}")\n'
            '                return\n\n',
            "PATCH:local_ludus-static-inventory",
        )

    # ---- Patch 4a: simulate CLI flags (may already be present) ----
    if cli.exists():
        regex_patch(
            cli,
            r'(simulate_parser\.add_argument\(\s*"-te",\s*"--techniques",\s*\n\s*required=True,)',
            r'simulate_parser.add_argument(\n        "-te",\n        "--techniques",\n        required=False,',
            "PATCH:local_ludus-simulate-techniques-optional",
        )
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
        plain_patch(
            cli,
            '    techniques = [t.strip() for t in args.techniques.split(",") if t.strip()]\n'
            '    if not techniques:\n'
            '        print("Error: No techniques specified. Please provide at least one technique ID.")\n'
            '        sys.exit(1)\n',
            '    if getattr(args, "random", False):\n'
            '        techniques = []\n'
            '    else:\n'
            '        techniques = [t.strip() for t in (args.techniques or "").split(",") if t.strip()]\n'
            '        if not techniques:\n'
            '            print("Error: No techniques specified. Provide --techniques or use --random.")\n'
            '            sys.exit(1)\n',
            "PATCH:local_ludus-simulate-techniques-parse",
        )
        regex_patch(
            cli,
            r'controller\.simulate\(args\.target, techniques\)',
            'controller.simulate(args.target, techniques, '
            'loop=getattr(args, "loop", False), '
            'random_pick=getattr(args, "random", False), '
            'interval_minutes=getattr(args, "interval", 30), '
            'exclude=getattr(args, "exclude", ""))  # PATCH:local_ludus-simulate-dispatch',
            "PATCH:local_ludus-simulate-dispatch",
        )

    if controller.exists():
        regex_patch(
            controller,
            r'^(?P<indent>[ \t]*)def simulate\(self, target: str, techniques: list\) -> dict:\s*\n',
            r'\g<indent>def simulate(self, target: str, techniques: list, loop=False, random_pick=False, '
            r'interval_minutes=30, exclude="") -> dict:  # PATCH:local_ludus-simulate-sig\n'
            r'\g<indent>    import time, random, csv, glob\n'
            r'\g<indent>    _excluded = {t.strip() for t in (exclude or "").split(",") if t.strip()}\n'
            r'\g<indent>    def _pick():\n'
            r'\g<indent>        paths = sorted(glob.glob("/opt/atomic-red-team/atomics/Indexes/Indexes-CSV/*.csv"))\n'
            r'\g<indent>        techs = set()\n'
            r'\g<indent>        for p in paths:\n'
            r'\g<indent>            with open(p, newline="") as fh:\n'
            r'\g<indent>                for row in csv.DictReader(fh):\n'
            r'\g<indent>                    tid = (row.get("Technique #") or "").strip()\n'
            r'\g<indent>                    if tid.startswith("T") and tid not in _excluded:\n'
            r'\g<indent>                        techs.add(tid)\n'
            r'\g<indent>        return random.choice(sorted(techs)) if techs else "T1082"\n'
            r'\g<indent>    if not loop:\n'
            r'\g<indent>        return self._simulate_inner(target, [_pick()] if random_pick and not techniques else techniques)\n'
            r'\g<indent>    self.logger.info(f"simulate --loop: interval={interval_minutes}m exclude={_excluded}")\n'
            r'\g<indent>    while True:\n'
            r'\g<indent>        chosen = [_pick()] if random_pick else techniques\n'
            r'\g<indent>        try:\n'
            r'\g<indent>            self._simulate_inner(target, chosen)\n'
            r'\g<indent>        except Exception as e:\n'
            r'\g<indent>            self.logger.warning(f"simulate iteration failed ({chosen}): {e}")\n'
            r'\g<indent>        time.sleep(interval_minutes * 60)\n'
            r'\n'
            r'\g<indent>def _simulate_inner(self, target: str, techniques: list) -> dict:  # PATCH:local_ludus-inner\n',
            "PATCH:local_ludus-simulate-sig",
        )
        plain_patch(
            controller,
            '        if target not in inventory or \'hosts\' not in inventory.get(target, {}):\n'
            '            available_groups = [k for k, v in inventory.items() if isinstance(v, dict) and \'hosts\' in v]\n'
            '            error_msg = f"Inventory group \'{target}\' not found. Available groups: {\', \'.join(available_groups) if available_groups else \'None\'}"\n'
            '            self.logger.error(error_msg)\n'
            '            raise ValueError(error_msg)\n',
            '        def _inventory_has_target(inv, name):\n'
            '            if isinstance(inv, dict):\n'
            '                hosts = inv.get("hosts") or {}\n'
            '                if name in hosts:\n'
            '                    return True\n'
            '                if name in inv and isinstance(inv[name], dict) and inv[name].get("hosts"):\n'
            '                    return True\n'
            '                for child in (inv.get("children") or {}).values():\n'
            '                    if _inventory_has_target(child, name):\n'
            '                        return True\n'
            '            return False\n'
            '        if not _inventory_has_target(inventory, target):\n'
            '            available_groups = [k for k, v in inventory.items() if isinstance(v, dict) and "hosts" in v]\n'
            '            groups = ", ".join(available_groups) if available_groups else "None"\n'
            '            error_msg = f"Inventory target {target!r} not found. Available groups: {groups}"\n'
            '            self.logger.error(error_msg)\n'
            '            raise ValueError(error_msg)\n',
            "PATCH:local_ludus-inventory-lookup",
        )

    # ---- Patch 5: resolve local_ludus templates ----
    if utils.exists():
        regex_patch(
            utils,
            r'for provider in \["aws", "azure", "gcp"\]:',
            'for provider in ["aws", "azure", "gcp", "local_ludus"]:',
            "PATCH:local_ludus-template-resolve",
        )

    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
