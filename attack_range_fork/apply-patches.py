#!/usr/bin/env python3
"""
String-based patcher that adds the `local_ludus` provider hooks to a fresh
checkout of splunk/attack_range. Robust against minor line-number drift
because it matches on function definitions and code patterns, not line numbers.

Usage:
    python3 apply-patches.py <path-to-upstream-clone>

Patches applied (idempotent — safe to re-run):

  Patch 1   Register `local_ludus` as a valid provider in the CLI and the
            AttackRangeController constructor (alongside aws/azure/gcp).

  Patch 2   In managers/ansible_manager.py, gate every WireGuard-related
            method behind `if self.provider != "local_ludus"`.

  Patch 3   In managers/ansible_manager.py::update_inventory_attack_range_servers,
            short-circuit to read /inventory.yml when provider == local_ludus.

  Patch 4   In attack_range.py, add --loop / --interval / --random / --exclude
            to the simulate subparser. In attack_range_controller.py::simulate,
            wrap the body in a while loop driven by those flags.

The companion `new-files/` tree copies in:
  - attack_range/cloud_providers/local_ludus_provider.py
  - templates/local_ludus/default.yml
"""

from __future__ import annotations
import re
import sys
from pathlib import Path


def patch(file: Path, anchor: str, insert: str, marker: str) -> None:
    """Insert `insert` immediately after the first occurrence of `anchor`.
    Skips if `marker` already present in the file (idempotent)."""
    text = file.read_text()
    if marker in text:
        print(f"  SKIP  {file.name} (marker {marker!r} already present)")
        return
    if anchor not in text:
        print(f"  WARN  {file.name}: anchor not found: {anchor!r}")
        return
    new = text.replace(anchor, anchor + insert, 1)
    file.write_text(new)
    print(f"  OK    {file.name}: applied {marker}")


def regex_patch(file: Path, pattern: str, replacement: str, marker: str) -> None:
    text = file.read_text()
    if marker in text:
        print(f"  SKIP  {file.name} ({marker} already present)")
        return
    new, n = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE | re.DOTALL)
    if n == 0:
        print(f"  WARN  {file.name}: pattern not matched")
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

    # ---- Patch 1: register local_ludus as a valid CLI provider ----
    # Most v5 builds use argparse with choices=["aws","azure","gcp"]. We
    # rewrite that list to include local_ludus. Marker is the string
    # "local_ludus" itself; if it's already present we skip.
    if cli.exists():
        regex_patch(
            cli,
            r'choices\s*=\s*\["aws",\s*"azure",\s*"gcp"\]',
            'choices=["aws", "azure", "gcp", "local_ludus"]',
            '"local_ludus"',
        )

    # ---- Patch 1b: wire the controller's provider dispatcher ----
    # Add a branch that instantiates LocalLudusProvider. We capture the
    # leading whitespace of the gcp elif so the new elif matches the
    # surrounding indentation level (varies by Attack Range version).
    if controller.exists():
        regex_patch(
            controller,
            r'^(?P<indent>[ \t]*)elif self\.config\["general"\]\["provider"\] == "gcp":[^\n]*\n'
            r'(?P<body>(?:\1[ \t]+[^\n]*\n)+)',
            r'\g<0>'
            r'\g<indent>elif self.config["general"]["provider"] == "local_ludus":'
            r'  # PATCH:local_ludus-controller\n'
            r'\g<indent>    from attack_range.cloud_providers.local_ludus_provider import LocalLudusProvider\n'
            r'\g<indent>    self.provider = LocalLudusProvider(self.config, self.log)\n',
            "PATCH:local_ludus-controller",
        )

        # ---- Patch 2 + 2b: stub VPN phases when provider is local_ludus ----
        regex_patch(
            controller,
            r'(?P<sig>^(?P<indent>[ \t]*)def\s+build_vpn_phase\s*\(self[^)]*\):\s*\n)',
            r'\g<sig>'
            r'\g<indent>    if self.config["general"]["provider"] == "local_ludus":\n'
            r'\g<indent>        return  # PATCH:local_ludus-vpn-build\n',
            "PATCH:local_ludus-vpn-build",
        )
        regex_patch(
            controller,
            r'(?P<sig>^(?P<indent>[ \t]*)def\s+prompt_vpn_connection\s*\(self[^)]*\):\s*\n)',
            r'\g<sig>'
            r'\g<indent>    if self.config["general"]["provider"] == "local_ludus":\n'
            r'\g<indent>        return  # PATCH:local_ludus-vpn-prompt\n',
            "PATCH:local_ludus-vpn-prompt",
        )

    # ---- Patch 2c: gate WireGuard helpers in ansible_manager ----
    if ansible_mgr.exists():
        for fn in (
            "update_vpn_playbook",
            "update_vpn_config_playbook",
            "_patch_wireguard_allowed_ips",
            "_patch_wireguard_server_config",
        ):
            marker = f"PATCH:local_ludus-wg-gate-{fn}"
            regex_patch(
                ansible_mgr,
                rf'(?P<sig>^(?P<indent>[ \t]*)def\s+{fn}\s*\(self[^)]*\):\s*\n)',
                r'\g<sig>'
                r'\g<indent>    if getattr(self, "provider", None) == "local_ludus":\n'
                rf'\g<indent>        return  # {marker}\n',
                marker,
            )

        # ---- Patch 3: static inventory injection ----
        regex_patch(
            ansible_mgr,
            r'(?P<sig>^(?P<indent>[ \t]*)def\s+update_inventory_attack_range_servers\s*\(self[^)]*\):\s*\n)',
            r'\g<sig>'
            r'\g<indent>    # PATCH:local_ludus-static-inventory\n'
            r'\g<indent>    if getattr(self, "provider", None) == "local_ludus":\n'
            r'\g<indent>        import shutil, os\n'
            r'\g<indent>        src = "/inventory.yml"\n'
            r'\g<indent>        if os.path.exists(src):\n'
            r'\g<indent>            shutil.copy(src, self.inventory_path)\n'
            r'\g<indent>            self.log.info(f"local_ludus: copied static inventory from {src}")\n'
            r'\g<indent>            return\n',
            "PATCH:local_ludus-static-inventory",
        )

    # ---- Patch 4: simulate --loop / --random / --interval / --exclude ----
    if cli.exists():
        # Add flags to the simulate subparser. We look for the line that
        # creates --techniques and append our four new arguments after it.
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

        # Forward the new args to controller.simulate(). Match the existing
        # simulate dispatch line and replace it with a loop-aware call.
        regex_patch(
            cli,
            r'controller\.simulate\(\s*args\.target\s*,\s*args\.techniques\s*\)',
            'controller.simulate(args.target, args.techniques, '
            'loop=getattr(args, "loop", False), '
            'random_pick=getattr(args, "random", False), '
            'interval_minutes=getattr(args, "interval", 30), '
            'exclude=getattr(args, "exclude", ""))  # PATCH:local_ludus-simulate-dispatch',
            "PATCH:local_ludus-simulate-dispatch",
        )

    if controller.exists():
        # Wrap simulate() body in a loop. We RENAME the existing
        # `def simulate(self, target, techniques):` to `_simulate_inner`
        # so its body becomes a callable, then prepend a wrapper method
        # with the new signature. Indent is captured from the original
        # def so this works regardless of class nesting.
        regex_patch(
            controller,
            r'^(?P<indent>[ \t]*)def\s+simulate\(self,\s*target,\s*techniques\)\s*:\s*\n',
            r'\g<indent>def simulate(self, target, techniques, loop=False, random_pick=False, '
            r'interval_minutes=30, exclude=""):  # PATCH:local_ludus-simulate-sig\n'
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
            r'\g<indent>        return self._simulate_inner(target, _pick() if random_pick else techniques)\n'
            r'\g<indent>    self.log.info(f"simulate --loop: interval={interval_minutes}m exclude={_excluded}")\n'
            r'\g<indent>    while True:\n'
            r'\g<indent>        chosen = _pick() if random_pick else techniques\n'
            r'\g<indent>        try:\n'
            r'\g<indent>            self._simulate_inner(target, chosen)\n'
            r'\g<indent>        except Exception as e:\n'
            r'\g<indent>            self.log.warning(f"simulate iteration failed ({chosen}): {e}")\n'
            r'\g<indent>        time.sleep(interval_minutes * 60)\n'
            r'\n'
            r'\g<indent>def _simulate_inner(self, target, techniques):  # PATCH:local_ludus-inner\n',
            "PATCH:local_ludus-simulate-sig",
        )

    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
