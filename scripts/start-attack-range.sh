#!/usr/bin/env bash
# Starts the patched Attack Range v5 (local_ludus provider) in Docker on
# your laptop. The container joins the host's tailnet via --net=host so it
# can reach lab VMs by MagicDNS.
#
# Prereqs:
#   - attack_range_fork/bootstrap.sh has been run (clones + patches upstream)
#   - .env populated
#   - You are joined to the same tailnet as the lab
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FORK_DIR="${REPO_ROOT}/attack_range_fork/upstream"

if [[ ! -d "$FORK_DIR" ]]; then
  echo "Attack Range fork not present. Run: attack_range_fork/bootstrap.sh" >&2
  exit 1
fi

# Render inventory + Attack Range config from current .env
set -a; source "${REPO_ROOT}/.env"; set +a
source "${REPO_ROOT}/scripts/lib/render-inventory.sh"
render_inventory
bash "${REPO_ROOT}/scripts/prepare-attack-range-config.sh"

cd "${REPO_ROOT}"
docker compose \
  -f "${FORK_DIR}/docker/docker-compose.yml" \
  -f "${REPO_ROOT}/docker/attack-range.compose.yml" \
  up -d

echo "Attack Range web UI:  http://localhost:4321"
echo "Attack Range API:     http://localhost:4000  (swagger at /openapi/swagger)"
echo "Inventory mounted from: ${REPO_ROOT}/ansible/inventory.yml"
