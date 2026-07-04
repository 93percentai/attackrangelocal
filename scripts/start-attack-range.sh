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

# Render inventory from current .env (RANGE_MODE picks full vs minimal)
set -a; source "${REPO_ROOT}/.env"; set +a
source "${REPO_ROOT}/scripts/lib/render-inventory.sh"
render_inventory

COMPOSE_FILES=(
  -f "${FORK_DIR}/docker/docker-compose.yml"
  -f "${REPO_ROOT}/docker/attack-range.compose.yml"
)

cd "${REPO_ROOT}"
docker compose "${COMPOSE_FILES[@]}" up -d

# Seed config/local-ludus-range.yml with general.status: running. Without
# this, /attack-range/simulate 404s with "attack range not found" forever --
# local_ludus never goes through the normal Terraform build flow that would
# otherwise create this file, since Ludus already provisioned the VMs.
# Idempotent: attack_range_fork's local_ludus patches reuse the same fixed
# attack_range_id (local-ludus-range) every time, so re-running this is safe.
echo "Registering the range with the Attack Range API (attack_range_id: local-ludus-range)..."
docker compose "${COMPOSE_FILES[@]}" --profile cli run --rm attack_range \
  build --template local_ludus/default.yml

echo "Attack Range web UI:  http://localhost:4321"
echo "Attack Range API:     http://localhost:4000  (swagger at /openapi/swagger)"
echo "Inventory mounted from: ${REPO_ROOT}/ansible/inventory.yml"
