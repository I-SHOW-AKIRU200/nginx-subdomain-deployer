#!/usr/bin/env bash
# ============================================================
#  Nginx Subdomain Deployer — Interactive Installer
#  Usage: bash <(curl -s https://raw.githubusercontent.com/YOU/nginx-subdomain-deployer/main/install.sh)
# ============================================================

set -euo pipefail

# ── Colours ─────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Constants ────────────────────────────────────────────────
REPO="https://raw.githubusercontent.com/YOU/nginx-subdomain-deployer/main"
INSTALL_DIR="/opt/nginx-subdomain-deployer"
SERVICE_USER="deployer"
APP_PORT=9000

# ── Helpers ──────────────────────────────────────────────────
print_banner() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║       Nginx Subdomain Deployer  v1.0.0           ║"
  echo "  ║   Automate wildcard-SSL reverse-proxy setup      ║"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

print_step() { echo -e "\n${CYAN}${BOLD}▶  $1${RESET}"; }
ok()         { echo -e "  ${GREEN}✔  $1${RESET}"; }
warn()       { echo -e "  ${YELLOW}⚠  $1${RESET}"; }
err()        { echo -e "  ${RED}✖  $1${RESET}"; }
info()       { echo -e "  ${DIM}ℹ  $1${RESET}"; }

press_enter() {
  echo ""
  read -rp "  Press [Enter] to continue…" _
}

confirm() {
  # confirm "Question" → returns 0 (yes) or 1 (no)
  local msg="$1"
  while true; do
    read -rp "  ${BOLD}${msg}${RESET} [y/N] " ans
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no|"") return 1 ;;
      *) warn "Please enter y or n." ;;
    esac
  done
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This step requires root / sudo."
    echo -e "  Re-run with: ${BOLD}sudo bash <(curl -s ${REPO}/install.sh)${RESET}"
    exit 1
  fi
}

# ── Main menu ────────────────────────────────────────────────
main_menu() {
  while true; do
    print_banner
    echo -e "  ${BOLD}What would you like to do?${RESET}\n"
    echo -e "    ${CYAN}[1]${RESET}  Download source"
    echo -e "    ${CYAN}[2]${RESET}  Set up everything"
    echo -e "    ${CYAN}[3]${RESET}  Exit"
    echo ""
    read -rp "  Enter choice [1-3]: " choice

    case "$choice" in
      1) menu_download ;;
      2) menu_setup ;;
      3) echo -e "\n  ${DIM}Bye!${RESET}\n"; exit 0 ;;
      *) warn "Invalid choice. Please enter 1, 2, or 3." ; sleep 1 ;;
    esac
  done
}

# ════════════════════════════════════════════════════════════
# [1]  DOWNLOAD SOURCE
# ════════════════════════════════════════════════════════════
menu_download() {
  print_banner
  print_step "Download Source"
  echo ""

  # Ask where to download
  read -rp "  ${BOLD}Destination directory${RESET} [default: ${INSTALL_DIR}]: " dest_input
  DEST="${dest_input:-$INSTALL_DIR}"

  echo ""

  # Check if destination already exists
  if [[ -d "$DEST" ]]; then
    warn "Directory ${DEST} already exists."
    if ! confirm "Overwrite / re-download?"; then
      info "Download cancelled."
      press_enter
      return
    fi
    rm -rf "$DEST"
  fi

  mkdir -p "$DEST"
  ok "Created directory: ${DEST}"

  print_step "Downloading files…"

  FILES=("app.py" "static/index.html" "requirements.txt" "setup.sh" "README.md" "sudoers.d/deployer")

  mkdir -p "$DEST/static" "$DEST/sudoers.d"

  local failed=0
  for f in "${FILES[@]}"; do
    printf "    Downloading %-35s" "${f}…"
    if curl -fsSL "${REPO}/source/${f}" -o "${DEST}/${f}" 2>/dev/null; then
      echo -e "${GREEN}✔${RESET}"
    else
      echo -e "${RED}✖ (not found)${RESET}"
      failed=$((failed+1))
    fi
  done

  echo ""
  if [[ $failed -eq 0 ]]; then
    ok "All files downloaded to ${DEST}"
  else
    warn "${failed} file(s) failed to download. Ensure the repository is public and correct."
  fi

  press_enter
}

# ════════════════════════════════════════════════════════════
# [2]  SETUP — interactive wizard
# ════════════════════════════════════════════════════════════
menu_setup() {
  need_root
  print_banner
  print_step "Interactive Setup Wizard"
  echo -e "  ${DIM}This will install all dependencies and configure the service.${RESET}\n"

  # ── Collect configuration ──────────────────────────────────
  # 1. Base domain
  while true; do
    read -rp "  ${BOLD}Your base domain${RESET} (e.g. example.com): " BASE_DOMAIN
    BASE_DOMAIN="${BASE_DOMAIN,,}"
    if [[ "$BASE_DOMAIN" =~ ^[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z]{2,})+$ ]]; then
      break
    fi
    warn "Invalid domain. Enter something like: example.com or sub.example.com"
  done

  # 2. Wildcard cert location
  DEFAULT_CERT_DIR="/etc/letsencrypt/live/${BASE_DOMAIN}"
  read -rp "  ${BOLD}SSL cert directory${RESET} [default: ${DEFAULT_CERT_DIR}]: " cert_input
  CERT_DIR="${cert_input:-$DEFAULT_CERT_DIR}"

  # 3. App port
  read -rp "  ${BOLD}Port for the deployer API${RESET} [default: ${APP_PORT}]: " port_input
  APP_PORT="${port_input:-$APP_PORT}"
  if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]] || ((APP_PORT < 1024 || APP_PORT > 65535)); then
    warn "Invalid port. Defaulting to 9000."
    APP_PORT=9000
  fi

  # 4. Service user
  read -rp "  ${BOLD}System user to run the service${RESET} [default: ${SERVICE_USER}]: " user_input
  SERVICE_USER="${user_input:-$SERVICE_USER}"

  # 5. Install directory
  read -rp "  ${BOLD}Install directory${RESET} [default: ${INSTALL_DIR}]: " dir_input
  INSTALL_DIR="${dir_input:-$INSTALL_DIR}"

  # 6. Auto-download source?
  echo ""
  local do_download=true
  if [[ -f "${INSTALL_DIR}/app.py" ]]; then
    info "Source already found at ${INSTALL_DIR}."
    if ! confirm "Re-download source?"; then
      do_download=false
    fi
  fi

  # ── Summary ────────────────────────────────────────────────
  echo ""
  echo -e "  ${BOLD}──── Configuration Summary ────────────────────${RESET}"
  echo -e "    Base domain   : ${CYAN}${BASE_DOMAIN}${RESET}"
  echo -e "    Cert dir      : ${CYAN}${CERT_DIR}${RESET}"
  echo -e "    Deployer port : ${CYAN}${APP_PORT}${RESET}"
  echo -e "    Service user  : ${CYAN}${SERVICE_USER}${RESET}"
  echo -e "    Install dir   : ${CYAN}${INSTALL_DIR}${RESET}"
  echo -e "  ${BOLD}───────────────────────────────────────────────${RESET}"
  echo ""

  if ! confirm "Proceed with installation?"; then
    info "Setup cancelled."
    press_enter
    return
  fi

  # ── Run setup ─────────────────────────────────────────────
  run_setup "$BASE_DOMAIN" "$CERT_DIR" "$APP_PORT" "$SERVICE_USER" "$INSTALL_DIR" "$do_download"

  press_enter
}

# ════════════════════════════════════════════════════════════
#  Core setup logic
# ════════════════════════════════════════════════════════════
run_setup() {
  local BASE_DOMAIN="$1"
  local CERT_DIR="$2"
  local PORT="$3"
  local SUSER="$4"
  local IDIR="$5"
  local DO_DL="$6"
  local FQDN_WILDCARD="*.${BASE_DOMAIN}"

  echo ""

  # ── Step 1: System deps ──────────────────────────────────
  print_step "[1/7] Installing system dependencies"
  apt-get update -qq && ok "apt updated"
  apt-get install -y -qq nginx python3 python3-pip python3-venv curl wget \
    && ok "nginx, python3, pip installed"

  # ── Step 2: Download source ──────────────────────────────
  if [[ "$DO_DL" == "true" ]]; then
    print_step "[2/7] Downloading source files"
    mkdir -p "$IDIR/static" "$IDIR/sudoers.d"
    local FILES=("app.py" "static/index.html" "requirements.txt")
    local failed=0
    for f in "${FILES[@]}"; do
      printf "    %-40s" "Downloading ${f}…"
      if curl -fsSL "${REPO}/source/${f}" -o "${IDIR}/${f}" 2>/dev/null; then
        echo -e "${GREEN}✔${RESET}"
      else
        echo -e "${RED}✖${RESET}"
        failed=$((failed+1))
      fi
    done
    if [[ $failed -gt 0 ]]; then
      err "Some source files failed to download. Aborting."
      return 1
    fi
    ok "Source downloaded to ${IDIR}"
  else
    print_step "[2/7] Skipping download (using existing source)"
    ok "Using files in ${IDIR}"
  fi

  # ── Step 3: Patch config into app.py ────────────────────
  print_step "[3/7] Patching configuration into app.py"
  sed -i "s|BASE_DOMAIN = \"killersharmabot.online\"|BASE_DOMAIN = \"${BASE_DOMAIN}\"|g" "${IDIR}/app.py"
  sed -i "s|Path(f\"/etc/letsencrypt/live/{BASE_DOMAIN}\")|Path(\"${CERT_DIR}\")|g"     "${IDIR}/app.py"
  ok "app.py patched with your domain and cert path"

  # ── Step 4: Python venv + deps ──────────────────────────
  print_step "[4/7] Setting up Python virtual environment"
  python3 -m venv "${IDIR}/venv"
  "${IDIR}/venv/bin/pip" install -q --upgrade pip
  "${IDIR}/venv/bin/pip" install -q fastapi uvicorn[standard] pydantic
  ok "Python venv ready at ${IDIR}/venv"

  # ── Step 5: Service user + permissions ──────────────────
  print_step "[5/7] Creating service user and setting permissions"

  if id "$SUSER" &>/dev/null; then
    info "User '${SUSER}' already exists — skipping creation."
  else
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SUSER"
    ok "Created system user: ${SUSER}"
  fi

  chown -R "${SUSER}:${SUSER}" "$IDIR"
  chown "${SUSER}:${SUSER}" /etc/nginx/sites-available
  ok "Ownership set"

  # Sudoers for narrow nginx + ln -s rights
  cat > "/etc/sudoers.d/${SUSER}" <<EOF
# Allow ${SUSER} to manage nginx and create symlinks for sites-enabled only
${SUSER} ALL=(root) NOPASSWD: /usr/sbin/nginx -t
${SUSER} ALL=(root) NOPASSWD: /usr/sbin/nginx -s reload
${SUSER} ALL=(root) NOPASSWD: /bin/ln -s /etc/nginx/sites-available/* /etc/nginx/sites-enabled/*
EOF
  chmod 440 "/etc/sudoers.d/${SUSER}"
  ok "Sudoers rule written: /etc/sudoers.d/${SUSER}"

  # ── Step 6: Systemd service ──────────────────────────────
  print_step "[6/7] Installing systemd service"
  cat > /etc/systemd/system/nginx-deployer.service <<EOF
[Unit]
Description=Nginx Subdomain Deployer API
After=network.target

[Service]
Type=simple
User=${SUSER}
WorkingDirectory=${IDIR}
ExecStart=${IDIR}/venv/bin/uvicorn app:app --host 127.0.0.1 --port ${PORT} --workers 1
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now nginx-deployer.service
  ok "Service enabled and started on port ${PORT}"

  # ── Step 7: Nginx gateway for the deployer UI itself ────
  print_step "[7/7] Configuring Nginx gateway for deployer UI"

  DEPLOYER_FQDN="deployer.${BASE_DOMAIN}"
  CONF="/etc/nginx/sites-available/${DEPLOYER_FQDN}.conf"

  if [[ -f "$CONF" ]]; then
    warn "Nginx config for ${DEPLOYER_FQDN} already exists — skipping."
  else
    cat > "$CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DEPLOYER_FQDN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DEPLOYER_FQDN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass         http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    ln -sf "$CONF" "/etc/nginx/sites-enabled/${DEPLOYER_FQDN}.conf"
    nginx -t && nginx -s reload
    ok "Nginx gateway created: https://${DEPLOYER_FQDN}"
  fi

  # ── Done ─────────────────────────────────────────────────
  echo ""
  echo -e "  ${GREEN}${BOLD}╔══════════════════════════════════════════════╗"
  echo -e "  ║          ✔  Installation Complete!          ║"
  echo -e "  ╚══════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${BOLD}Deployer UI  :${RESET} ${CYAN}https://deployer.${BASE_DOMAIN}${RESET}"
  echo -e "  ${BOLD}Local API    :${RESET} ${CYAN}http://127.0.0.1:${PORT}${RESET}"
  echo -e "  ${BOLD}Service log  :${RESET} journalctl -u nginx-deployer -f"
  echo ""
}

# ── Entry point ──────────────────────────────────────────────
main_menu
