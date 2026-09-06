"""
local_ludus provider — no-cloud substrate for Splunk Attack Range v5.

The VMs already exist: Ludus created them on Proxmox and they are reachable
over Tailscale MagicDNS. There is no cloud API to call, no Terraform state
to keep, no object-storage backend to provision, and no SSH keypair to
import into a cloud account.

This class satisfies the `BaseCloudProvider` ABC so `AttackRangeController`
can instantiate it, and makes every cloud operation an explicit no-op that
logs what it skipped. Anything that MUST return a value returns something
harmless and deterministic.

IMPORTANT — keep in sync with attack_range/cloud_providers/base_provider.py.
If upstream adds an @abstractmethod, this class must implement it or the
controller will raise TypeError at construction. attack_range_fork/
apply-patches.py verifies this on every run.
"""

from __future__ import annotations

import logging
import re
from typing import Optional

from .base_provider import BaseCloudProvider


class LocalLudusProvider(BaseCloudProvider):
    """No-op provider for ranges whose infrastructure Ludus already built."""

    def __init__(self, config: dict, logger: logging.Logger):
        super().__init__(config, logger)
        self.logger.info(
            "local_ludus provider active — VMs are managed by Ludus/Proxmox, "
            "no cloud API calls will be made"
        )

    # ------------------------------------------------------------------
    # BaseCloudProvider ABC
    # ------------------------------------------------------------------

    def get_region(self, required: bool = True) -> Optional[str]:
        """No cloud regions on bare metal. A stable string keeps any
        downstream f-string/path join from producing 'None'."""
        return "local"

    def sanitize_name(self, name: str) -> str:
        """Ludus VM names allow [A-Za-z0-9-]; mirror the cloud providers'
        contract of returning a safe, lowercase, deterministic name."""
        return re.sub(r"[^a-zA-Z0-9-]", "-", name).strip("-").lower()

    def check_backend_exists(self, backend_name: str) -> bool:
        """No Terraform remote backend — report 'exists' so callers skip
        creation instead of trying (and failing) to make one."""
        self.logger.debug("local_ludus: check_backend_exists -> True (no-op)")
        return True

    def create_backend(self, backend_name: str, region: str) -> None:
        self.logger.debug("local_ludus: create_backend skipped (no-op)")

    def delete_backend(self, backend_name: str, region: str) -> None:
        self.logger.debug("local_ludus: delete_backend skipped (no-op)")

    def import_ssh_key(
        self, key_name: str, public_key_content: str, region: str
    ) -> None:
        """Ludus installs the operator key at VM-provision time; there is
        no cloud keypair registry to import into."""
        self.logger.debug("local_ludus: import_ssh_key skipped (Ludus owns keys)")

    def delete_ssh_key(self, key_name: str, region: str) -> None:
        self.logger.debug("local_ludus: delete_ssh_key skipped (Ludus owns keys)")

    def update_backend_config(
        self, backend_params: dict, backend_file_path: str
    ) -> None:
        """No Terraform, so no backend.tf to write."""
        self.logger.debug("local_ludus: update_backend_config skipped (no Terraform)")

    # ------------------------------------------------------------------
    # Convenience hooks used by the patched controller
    # ------------------------------------------------------------------

    def get_inventory_path(self) -> str:
        """Where the patched ansible_manager reads the static inventory."""
        return "/inventory.yml"
