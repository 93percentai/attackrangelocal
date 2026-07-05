#!/usr/bin/env bash
# Non-interactive Ludus client + server install for Proxmox first-boot.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ludus-network.sh
source "${SCRIPT_DIR}/ludus-network.sh"

LUDUS_PROJECT_ID=54052321
LUDUS_ENV_FILE=/var/lib/ludus-bootstrap/ludus.env

ensure_expect() {
  if command -v expect >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing expect for unattended Ludus prompts..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends expect >/dev/null
}

skip_ludus_completions_prompt() {
  # Upstream install.sh skips the completions question when this file exists.
  mkdir -p /usr/share/bash-completion/completions
  touch /usr/share/bash-completion/completions/ludus
}

ludus_latest_tag() {
  curl -fsSL "https://gitlab.com/api/v4/projects/${LUDUS_PROJECT_ID}/repository/tags" \
    | grep -o '"name":"[^"]*' | cut -d'"' -f4 | head -n1
}

ludus_client_installed() {
  command -v ludus >/dev/null 2>&1
}

ludus_server_ready() {
  [[ -d /opt/ludus ]] \
    && systemctl is-active --quiet ludus.service 2>/dev/null \
    && ludus version >/dev/null 2>&1
}

ludus_install_in_progress() {
  if [[ -f /etc/systemd/system/ludus-install.service ]]; then
    if systemctl is-active --quiet ludus-install.service 2>/dev/null; then
      return 0
    fi
    if [[ ! -f /etc/systemd/system/ludus.service ]] \
      || ! systemctl is-active --quiet ludus.service 2>/dev/null; then
      return 0
    fi
  fi
  if [[ -d /opt/ludus/install ]] \
    && [[ ! -f /opt/ludus/install/.stage-3-complete ]] \
    && [[ ! -f /opt/ludus/install/.install-complete ]]; then
    return 0
  fi
  return 1
}

write_initial_admin_yml() {
  local dest="$1"
  local user_id name email password

  user_id="${LUDUS_API_USER_ID:-admin}"
  name="${LUDUS_API_USER_NAME:-Range Admin}"
  email="${LUDUS_API_USER_EMAIL:-admin@${AD_DOMAIN_FQDN:-range.local}}"
  password="${LUDUS_API_USER_PASSWORD:-${LUDUS_ADMIN_PASSWORD:-}}"

  if [[ -z "$password" ]]; then
    password="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)"
    echo "Generated Ludus admin password (saved in ${LUDUS_ENV_FILE%.env}-admin-password)"
    install -d -m 700 "$(dirname "$LUDUS_ENV_FILE")"
    printf '%s\n' "$password" > "${LUDUS_ENV_FILE%.env}-admin-password"
    chmod 600 "${LUDUS_ENV_FILE%.env}-admin-password"
  fi

  cat >"$dest" <<EOF
---
name: ${name}
email: ${email}
userID: ${user_id}
password: ${password}
EOF
  chmod 600 "$dest"
}

run_install_script_unattended() {
  local install_script="$1"
  ensure_expect
  skip_ludus_completions_prompt

  # Proxmox hosts need a UTF-8 locale or ludus-server can fail (upstream install.sh).
  if [[ -f /usr/bin/pveversion ]]; then
    export LANGUAGE=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8
    export LC_CTYPE=en_US.UTF-8
  fi

  expect <<EOF
set timeout 7200
log_user 1
spawn bash ${install_script}
expect {
  -re {\(y/n\):} {
    send "y\r"
    exp_continue
  }
  -re {Do you want to continue\\? \\(y/N\\):} {
    exec mkdir -p /opt/ludus/install
    exec cp -f ${install_script}.initial-admin.yml /opt/ludus/install/initial-admin.yml
    send "y\r"
    exp_continue
  }
  eof
}
EOF
}

install_ludus_client_and_server() {
  local install_url tag tmpdir install_script admin_yml

  : "${LUDUS_INSTALL_URL:=https://ludus.cloud/install}"
  tmpdir="$(mktemp -d)"
  install_script="${tmpdir}/ludus-install.sh"
  admin_yml="${install_script}.initial-admin.yml"

  curl -fsSL "$LUDUS_INSTALL_URL" -o "$install_script"
  chmod +x "$install_script"
  write_initial_admin_yml "$admin_yml"

  echo "Starting unattended Ludus install (server install may reboot twice)..."
  run_install_script_unattended "$install_script"
  rm -rf "$tmpdir"
}

install_ludus_server_only() {
  local tag tmpdir server_bin config_yml admin_yml

  ensure_expect
  tag="$(ludus_latest_tag)"
  [[ -n "$tag" ]] || { echo "Could not resolve Ludus release tag" >&2; return 1; }

  tmpdir="$(mktemp -d)"
  server_bin="${tmpdir}/ludus-server"
  config_yml="${tmpdir}/config.yml"
  admin_yml="${tmpdir}/initial-admin.yml"

  curl -fsSL \
    "https://gitlab.com/api/v4/projects/${LUDUS_PROJECT_ID}/packages/generic/ludus/${tag}/ludus-server-${tag}" \
    -o "$server_bin"
  chmod +x "$server_bin"
  render_ludus_server_config >"$config_yml"
  write_initial_admin_yml "$admin_yml"

  if [[ -f /usr/bin/pveversion ]]; then
    export LANGUAGE=en_US.UTF-8 LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 LC_CTYPE=en_US.UTF-8
  fi

  (
    cd "$tmpdir"
    expect <<EOF
set timeout 7200
log_user 1
spawn ./ludus-server
expect {
  -re {Do you want to continue\\? \\(y/N\\):} {
    exec mkdir -p /opt/ludus/install
    exec cp -f ${admin_yml} /opt/ludus/install/initial-admin.yml
    send "y\r"
    exp_continue
  }
  eof
}
EOF
  )

  rm -rf "$tmpdir"
}

wait_for_ludus_ready() {
  local i max="${LUDUS_INSTALL_WAIT_ITERATIONS:-720}"
  for ((i = 1; i <= max; i++)); do
    if ludus_server_ready; then
      return 0
    fi
    if command -v ludus-install-status >/dev/null 2>&1; then
      ludus-install-status 2>&1 | tail -10 || true
    elif ludus_install_in_progress; then
      systemctl status ludus-install.service --no-pager 2>&1 | tail -5 || true
    fi
    echo "Waiting for Ludus install to finish (${i}/${max})..."
    sleep 10
  done
  echo "Timed out waiting for Ludus to become ready" >&2
  return 1
}

write_ludus_env_file() {
  local env_file="$LUDUS_ENV_FILE"
  local root_key=/opt/ludus/install/root-api-key
  local api_key=""

  install -d -m 700 "$(dirname "$env_file")"

  if command -v ludus-install-status >/dev/null 2>&1; then
    local status_out
    status_out="$(ludus-install-status 2>&1 || true)"
    api_key="$(printf '%s\n' "$status_out" | sed -n "s/.*LUDUS_API_KEY='\([^']*\)'.*/\1/p" | head -1)"
    if [[ -z "$api_key" ]]; then
      api_key="$(printf '%s\n' "$status_out" | sed -n 's/.*API KEY[[:space:]]*|[[:space:]]*\([^ |]*\).*/\1/p' | head -1)"
    fi
  fi

  if [[ -z "$api_key" && -f "$root_key" ]]; then
    api_key="$(tr -d '\n' < "$root_key")"
  fi

  if [[ -z "$api_key" ]]; then
    echo "Ludus is up but no API key was found under /opt/ludus/install/" >&2
    return 1
  fi

  cat >"$env_file" <<EOF
# Written by scripts/bootstrap-ludus.sh — sourced by downstream pipeline scripts.
export LUDUS_API_KEY='${api_key}'
EOF
  chmod 600 "$env_file"

  cat >/etc/profile.d/attackrangelocal-ludus.sh <<EOF
# Ludus API key for unattended pipeline scripts (root shell).
export LUDUS_API_KEY='${api_key}'
EOF
  chmod 644 /etc/profile.d/attackrangelocal-ludus.sh
}

run_ludus_unattended_install() {
  if ludus_server_ready; then
    echo "Ludus server already running: $(ludus version)"
    write_ludus_env_file
    return 0
  fi

  if ludus_install_in_progress; then
    echo "Ludus install already in progress — waiting for completion..."
    wait_for_ludus_ready
    write_ludus_env_file
    return 0
  fi

  if ! ludus_client_installed; then
    install_ludus_client_and_server
    if ! ludus_server_ready && ! ludus_install_in_progress && [[ ! -d /opt/ludus ]]; then
      echo "Install script did not start the Ludus server — falling back to direct install..."
      install_ludus_server_only
    fi
  else
    echo "Ludus client present; installing server only..."
    install_ludus_server_only
  fi

  # ludus-server may reboot the host before install finishes.
  if ! ludus_server_ready; then
    if ludus_install_in_progress || [[ -d /opt/ludus ]]; then
      echo "Ludus install started (host may reboot). Waiting for completion..."
      wait_for_ludus_ready
    else
      echo "Ludus install did not start successfully" >&2
      return 1
    fi
  fi

  write_ludus_env_file
  echo "Ludus install complete: $(ludus version)"
}
