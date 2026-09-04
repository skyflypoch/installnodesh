#!/usr/bin/env bash
set -Eeuo pipefail

# WILLVPN REMNANODE INSTALLER v4
# Docker is already installed.
# Asks ONLY:
# 1) SECRET_KEY
# 2) whether Hysteria2 is needed
# 3) Hysteria2 domain, if needed

REMNA_DIR="/opt/remnanode"
NODE_PORT="2222"
CERT_EMAIL="ilyamaksimovmail@gmail.com"

die() { echo "ERROR: $*" >&2; exit 1; }

read_required() {
  local value=""
  while [[ -z "$value" ]]; do
    read -r -p "$1" value </dev/tty
  done
  printf '%s' "$value"
}

ask_yes_no() {
  local answer=""
  read -r -p "$1 [y/N]: " answer </dev/tty
  case "${answer,,}" in
    y|yes|д|да) return 0 ;;
    *) return 1 ;;
  esac
}

[[ $EUID -eq 0 ]] || die "Run as root"
command -v docker >/dev/null || die "Docker not found"
docker compose version >/dev/null 2>&1 || die "docker compose not found"

echo "=== WILLVPN Remnawave Node installer v4 ==="

SECRET_KEY="$(read_required 'SECRET_KEY: ')"

ENABLE_HY2=0
HY2_DOMAIN=""

if ask_yes_no "Нужна Hysteria2?"; then
  ENABLE_HY2=1
  HY2_DOMAIN="$(read_required 'Домен Hysteria2: ')"
fi

mkdir -p "$REMNA_DIR"

umask 077
cat > "$REMNA_DIR/.env" <<EOF
NODE_PORT=$NODE_PORT
SECRET_KEY=$SECRET_KEY
EOF
chmod 600 "$REMNA_DIR/.env"

cat > "$REMNA_DIR/docker-compose.yml" <<'EOF'
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    env_file:
      - .env
EOF

if (( ENABLE_HY2 )); then
  if ! command -v certbot >/dev/null || ! command -v dig >/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y certbot dnsutils
  fi

  RESOLVED_IP="$(dig +short A "$HY2_DOMAIN" | tail -n1)"
  [[ -n "$RESOLVED_IP" ]] || die "$HY2_DOMAIN does not resolve"

  if [[ ! -f "/etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem" ]]; then
    certbot certonly --standalone \
      -d "$HY2_DOMAIN" \
      --non-interactive \
      --agree-tos \
      -m "$CERT_EMAIL"
  fi

  cat >> "$REMNA_DIR/docker-compose.yml" <<'EOF'
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
EOF

  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/restart-remnanode.sh <<'EOF'
#!/bin/sh
docker restart remnanode
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-remnanode.sh
fi

cd "$REMNA_DIR"
docker compose pull
docker compose up -d

echo "=== DONE ==="
docker ps --filter name=remnanode
