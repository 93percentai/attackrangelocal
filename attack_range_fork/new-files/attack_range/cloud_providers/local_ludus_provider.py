"""
local_ludus provider — placeholder substrate for Splunk Attack Range v5.

The VMs already exist (deployed by Ludus on Proxmox) and are reachable by
Tailscale MagicDNS. There is no infrastructure for Attack Range to "build"
or "destroy". All the heavy lifting that the AWS/Azure/GCP providers do via
Terraform is a no-op here.

Attack Range still drives:
  - Ansible-based VM configuration (when provider != local_ludus, this is
    skipped because Ludus already ran the P4T12ICK.ludus_ar_* roles)
  - The simulate engine (Invoke-AtomicTest via WinRM over Tailscale)
  - The web UI / REST API

Companion file copied in by attack_range_fork/bootstrap.sh.
"""

from __future__ import annotations
import logging


class LocalLudusProvider:
    """No-op provider that satisfies the BaseProvider interface enough for
    Attack Range's lifecycle methods to short-circuit cleanly."""

    name = "local_ludus"

    def __init__(self, config: dict, log: logging.Logger | None = None):
        self.config = config
        self.log = log or logging.getLogger("attack_range.local_ludus")
        self.log.info("local_ludus provider initialised — VMs are managed by Ludus")

    # ------------------------------------------------------------------
    # Lifecycle methods called by AttackRangeController. All no-ops.
    # ------------------------------------------------------------------

    def build_infrastructure(self, *_args, **_kwargs) -> None:
        self.log.info("local_ludus: build_infrastructure skipped (Ludus owns VMs)")

    def destroy_infrastructure(self, *_args, **_kwargs) -> None:
        self.log.info("local_ludus: destroy_infrastructure skipped (use scripts/teardown.sh)")

    def build_vpn_phase(self, *_args, **_kwargs) -> None:
        self.log.info("local_ludus: build_vpn_phase skipped (Tailscale handles VPN)")

    def prompt_vpn_connection(self, *_args, **_kwargs) -> None:
        return  # operator is already on the tailnet

    def stop(self, *_args, **_kwargs) -> None:
        self.log.info("local_ludus: stop skipped — use 'ludus range stop' on the Ludus host")

    def resume(self, *_args, **_kwargs) -> None:
        self.log.info("local_ludus: resume skipped — use 'ludus range start' on the Ludus host")

    # ------------------------------------------------------------------
    # Inventory hook — used by the patched ansible_manager.
    # ------------------------------------------------------------------

    def get_inventory_path(self) -> str:
        """The patched ansible_manager prefers /inventory.yml directly; this
        is here for completeness and for any code that asks the provider."""
        return "/inventory.yml"
