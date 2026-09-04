#!/usr/bin/env bash
set -Eeuo pipefail

# Remnawave Node installer
# Docker is assumed to be already installed.
# Based on the user's Remnawave + Hysteria2 installation notes.

REMNA_DIR="/opt/remnanode"
ENV_FILE="$REMNA_DIR/.env"
COMPOSE_FILE="$REMNA_DIR/docker-compose.yml"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

die() {
  red "Ошибка: $*"
  exit 1
}

need_root() {
  [[ $EUID -eq 0 ]] || die "Запусти скрипт от root: sudo bash $0"
}

check_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker не найден. По условию он уже должен быть установлен."
  docker compose version >/dev/null 2>&1 || die "docker compose не найден."
  systemctl is-active --quiet docker || {
    yellow "Docker установлен, но сервис не запущен. Запускаю..."
    systemctl enable --now docker
  }
}

prompt_default() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="$3"
  local value
  read -r -p "$prompt_text [$default_value]: " value
  printf -v "$var_name" '%s' "${value:-$default_value}"
}

prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local value=""
  while [[ -z "$value" ]]; do
    read -r -p "$prompt_text: " value
  done
  printf -v "$var_name" '%s' "$value"
}

prompt_yes_no() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-n}"
  local answer
  if [[ "$default" == "y" ]]; then
    read -r -p "$prompt_text [Y/n]: " answer
    answer="${answer:-y}"
  else
    read -r -p "$prompt_text [y/N]: " answer
    answer="${answer:-n}"
  fi
  case "${answer,,}" in
    y|yes|д|да) printf -v "$var_name" '%s' "yes" ;;
    *)          printf -v "$var_name" '%s' "no" ;;
  esac
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

detect_public_ipv4() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  printf '%s' "$ip"
}

install_packages() {
  local pkgs=("$@")
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
}

ensure_base_tools() {
  local missing=()
  for x in curl ss awk grep sed; do
    command -v "$x" >/dev/null 2>&1 || true
  done
  command -v ss >/dev/null 2>&1 || missing+=(iproute2)
  command -v curl >/dev/null 2>&1 || missing+=(curl)

  if ((${#missing[@]})); then
    install_packages "${missing[@]}"
  fi
}

write_compose() {
  local with_hy2="$1"

  mkdir -p "$REMNA_DIR"

  cat > "$COMPOSE_FILE" <<'EOF'
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

  if [[ "$with_hy2" == "yes" ]]; then
    cat >> "$COMPOSE_FILE" <<'EOF'
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
EOF
  fi
}

write_env() {
  umask 077
  cat > "$ENV_FILE" <<EOF
NODE_PORT=$NODE_PORT
SECRET_KEY=$SECRET_KEY
EOF
  chmod 600 "$ENV_FILE"
}

dns_check() {
  local domain="$1"
  local server_ip="$2"

  command -v dig >/dev/null 2>&1 || install_packages dnsutils

  bold "Проверяю DNS $domain ..."
  local resolved
  resolved="$(dig +short A "$domain" | tail -n1 || true)"

  if [[ -z "$resolved" ]]; then
    yellow "A-запись пока не резолвится."
    yellow "Создай A-запись: $domain -> $server_ip"
    yellow "Если используешь Cloudflare — проксирование должно быть выключено."
    prompt_yes_no CONTINUE_DNS "Продолжить всё равно?" "n"
    [[ "$CONTINUE_DNS" == "yes" ]] || exit 1
    return
  fi

  if [[ -n "$server_ip" && "$resolved" != "$server_ip" ]]; then
    yellow "DNS сейчас указывает на $resolved, а IP сервера определён как $server_ip."
    prompt_yes_no CONTINUE_DNS "Продолжить всё равно?" "n"
    [[ "$CONTINUE_DNS" == "yes" ]] || exit 1
  else
    green "DNS OK: $domain -> $resolved"
  fi
}

issue_certificate() {
  install_packages certbot dnsutils

  if [[ -d "/etc/letsencrypt/live/$HY2_DOMAIN" ]]; then
    green "Сертификат для $HY2_DOMAIN уже существует."
    prompt_yes_no REISSUE_CERT "Перевыпустить/обновить его сейчас?" "n"
    if [[ "$REISSUE_CERT" != "yes" ]]; then
      return
    fi
  fi

  local listener=""
  listener="$(ss -ltnp 'sport = :80' 2>/dev/null | tail -n +2 || true)"

  if [[ -n "$listener" ]]; then
    yellow "TCP/80 занят:"
    printf '%s\n' "$listener"
    yellow "Standalone certbot не сможет занять порт 80."

    local containers
    containers="$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E '(^|,| )0\.0\.0\.0:80->|(^|,| ):::80->|(^|,| )80/tcp' || true)"

    if [[ -n "$containers" ]]; then
      yellow "Похожие Docker-контейнеры:"
      printf '%s\n' "$containers"
    fi

    prompt_yes_no STOP_CONTAINER "Хочешь временно остановить Docker-контейнер, который держит 80 порт?" "n"
    if [[ "$STOP_CONTAINER" == "yes" ]]; then
      prompt_required PORT80_CONTAINER "Имя контейнера"
      docker inspect "$PORT80_CONTAINER" >/dev/null 2>&1 || die "Контейнер '$PORT80_CONTAINER' не найден."
      docker stop "$PORT80_CONTAINER"
      trap 'docker start "$PORT80_CONTAINER" >/dev/null 2>&1 || true' EXIT
      certbot certonly --standalone \
        -d "$HY2_DOMAIN" \
        --non-interactive \
        --agree-tos \
        -m "$CERT_EMAIL"
      docker start "$PORT80_CONTAINER"
      trap - EXIT
    else
      red "Сертификат автоматически не выпущен."
      yellow "Освободи TCP/80 или выпусти сертификат через DNS-01, затем запусти этот скрипт повторно."
      exit 1
    fi
  else
    certbot certonly --standalone \
      -d "$HY2_DOMAIN" \
      --non-interactive \
      --agree-tos \
      -m "$CERT_EMAIL"
  fi

  [[ -f "/etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem" ]] || die "fullchain.pem не найден."
  [[ -f "/etc/letsencrypt/live/$HY2_DOMAIN/privkey.pem" ]] || die "privkey.pem не найден."
  green "TLS-сертификат готов."
}

install_cert_hook() {
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/restart-remnanode.sh <<'EOF'
#!/bin/sh
docker restart remnanode
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-remnanode.sh
}

print_hy2_json() {
  cat <<EOF

============================================================
HYSTERIA2 INBOUND ДЛЯ REMNAWAVE CONFIG PROFILE
============================================================

{
  "tag": "Hysteria2",
  "port": $HY2_PORT,
  "listen": "0.0.0.0",
  "protocol": "hysteria",
  "settings": {
    "clients": [],
    "version": 2
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  },
  "streamSettings": {
    "network": "hysteria",
    "security": "tls",
    "tlsSettings": {
      "alpn": ["h3"],
      "certificates": [
        {
          "certificateFile": "/etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem",
          "keyFile": "/etc/letsencrypt/live/$HY2_DOMAIN/privkey.pem"
        }
      ]
    },
    "hysteriaSettings": {
      "version": 2,
      "up": "$HY2_UP mbps",
      "down": "$HY2_DOWN mbps",
      "udpIdleTimeout": 60
    }
  }
}

============================================================
ЧТО ЕЩЁ СДЕЛАТЬ В ПАНЕЛИ
============================================================

1. Config Profiles -> нужный профиль -> Edit.
   Добавь этот объект в массив "inbounds".

2. Если у тебя в routing DNS-правиле есть inboundTag, добавь туда:
   "Hysteria2"

3. Nodes -> эта нода -> Edit -> Inbound Configurations.
   Включи Hysteria2.

4. Hosts -> Create Host:
   Remark: Hysteria2
   Address: $HY2_DOMAIN
   Port: $HY2_PORT
   Inbound: Hysteria2
   SNI: $HY2_DOMAIN
   ALPN: h3
   Fingerprint: chrome или пусто
   Allow Insecure: OFF
   Visibility: ON

5. Internal Squads -> нужный Squad -> включи Hysteria2.

6. Subscription Settings:
   включи "Использовать JSON в базовой подписке", если используешь Happ.

7. В клиенте подписку лучше удалить и добавить заново.
EOF
}

main() {
  need_root
  ensure_base_tools
  check_docker

  bold "=== Remnawave Node installer ==="
  echo "Docker пропускаем: считаем, что он уже установлен."
  echo

  prompt_required SECRET_KEY "Вставь SECRET_KEY из Remnawave Nodes -> Add Node"
  prompt_default NODE_PORT "Node Port" "2222"
  valid_port "$NODE_PORT" || die "Некорректный NODE_PORT."

  prompt_yes_no ENABLE_HY2 "Добавить Hysteria2?" "y"

  PUBLIC_IP="$(detect_public_ipv4)"
  if [[ -n "$PUBLIC_IP" ]]; then
    green "Определён публичный IPv4: $PUBLIC_IP"
  else
    yellow "Публичный IPv4 определить не удалось."
    prompt_required PUBLIC_IP "Введи IPv4 сервера"
  fi

  if [[ "$ENABLE_HY2" == "yes" ]]; then
    echo
    prompt_required HY2_DOMAIN "Домен Hysteria2, например est.willvpn.space"
    prompt_required CERT_EMAIL "Email для Let's Encrypt"
    prompt_default HY2_PORT "UDP-порт Hysteria2" "443"
    prompt_default HY2_UP "Hysteria2 up, Mbps" "100"
    prompt_default HY2_DOWN "Hysteria2 down, Mbps" "100"

    valid_port "$HY2_PORT" || die "Некорректный Hysteria2 port."
    [[ "$HY2_UP" =~ ^[0-9]+$ ]] || die "HY2 up должен быть числом."
    [[ "$HY2_DOWN" =~ ^[0-9]+$ ]] || die "HY2 down должен быть числом."

    dns_check "$HY2_DOMAIN" "$PUBLIC_IP"
    issue_certificate
    install_cert_hook
  fi

  mkdir -p "$REMNA_DIR"
  write_env
  write_compose "$ENABLE_HY2"

  bold "Подтягиваю образ и запускаю ноду..."
  cd "$REMNA_DIR"
  docker compose pull
  docker compose up -d

  echo
  bold "=== Проверка ==="
  docker ps --filter name=remnanode
  echo
  ss -tulpn | grep -E ":${NODE_PORT}\b" || yellow "Порт $NODE_PORT пока не виден. Проверь docker logs remnanode."

  if [[ "$ENABLE_HY2" == "yes" ]]; then
    echo
    bold "Сертификат:"
    certbot certificates || true

    echo
    bold "Сертификаты внутри remnanode:"
    docker exec remnanode ls -la "/etc/letsencrypt/live/$HY2_DOMAIN/" || true

    echo
    yellow "Важно: UDP/$HY2_PORT появится только ПОСЛЕ того, как ты добавишь Hysteria2 inbound в Config Profile и включишь его для этой ноды."

    print_hy2_json
  fi

  echo
  green "Готово."
  echo
  echo "Полезные команды:"
  echo "  docker logs --tail 100 remnanode"
  echo "  docker exec remnanode tail -100 /var/log/supervisor/xray.out.log"
  echo "  docker exec remnanode tail -100 /var/log/supervisor/xray.err.log"
  echo "  ss -tulpn | grep -E ':(${NODE_PORT}"
  if [[ "$ENABLE_HY2" == "yes" ]]; then
    echo -n "|${HY2_PORT}"
  fi
  echo ")'"
}

main "$@"
