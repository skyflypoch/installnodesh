#!/usr/bin/env bash
set -Eeuo pipefail

# will Remnanode installer v5

REMNA_DIR="/opt/remnanode"
NODE_PORT="${NODE_PORT:-}"
PANEL_DOMAIN="panel.willvpn.space"
PANEL_SOURCE_IP="${PANEL_SOURCE_IP:-}"
CERT_EMAIL="ilyamaksimovmail@gmail.com"
SITE_PORT="${SELFSTEAL_PORT:-9444}"
SITE_DIR="$REMNA_DIR/selfsteal/site"
ACME_DIR="$REMNA_DIR/selfsteal/acme"
NGINX_CONF="/etc/nginx/conf.d/remnanode-selfsteal.conf"
HY2_ACME_CONF="/etc/nginx/conf.d/remnanode-hysteria-acme.conf"
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-remnanode.sh"

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
  case "$answer" in
    y|Y|yes|Yes|YES|д|Д|да|Да|ДА) return 0 ;;
    *) return 1 ;;
  esac
}

ask_yes_no_default_yes() {
  local answer=""
  read -r -p "$1 [Y/n]: " answer </dev/tty
  case "$answer" in
    ""|y|Y|yes|Yes|YES|д|Д|да|Да|ДА) return 0 ;;
    *) return 1 ;;
  esac
}

validate_domain() {
  local domain="$1" label
  [[ ${#domain} -le 253 && "$domain" == *.* ]] || die "Некорректный домен: $domain"
  [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || die "Некорректный домен: $domain"
  [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || die "Некорректный домен: $domain"
  IFS='.' read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || die "Некорректный домен: $domain"
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "Некорректный домен: $domain"
  done
}

configure_public_firewall() {
  local -a ports=(443/tcp)
  local port zone zones
  if (( ENABLE_SITE || ENABLE_HY2 )); then ports+=(80/tcp); fi
  if (( ENABLE_HY2 )); then ports+=(443/udp); fi

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    for port in "${ports[@]}"; do
      ufw allow "$port" >/dev/null || die "Не удалось разрешить $port в UFW"
    done
    echo "UFW: открыты ${ports[*]}"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    zones="$(firewall-cmd --get-active-zones | awk '/^[^[:space:]]/ {print $1}')"
    [[ -n "$zones" ]] || zones="$(firewall-cmd --get-default-zone)"
    for zone in $zones; do
      for port in "${ports[@]}"; do
        firewall-cmd --zone="$zone" --add-port="$port" >/dev/null || die "Не удалось разрешить $port в firewalld"
        firewall-cmd --permanent --zone="$zone" --add-port="$port" >/dev/null || die "Не удалось сохранить $port в firewalld"
      done
    done
    echo "firewalld: открыты ${ports[*]}"
  fi
}

valid_ipv4() {
  local ip="$1" part
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS='.' read -r -a parts <<< "$ip"
  for part in "${parts[@]}"; do
    [[ ${#part} -le 3 ]] && (( 10#$part <= 255 )) || return 1
  done
}

configure_panel_firewall() {
  local panel_ip="$PANEL_SOURCE_IP" resolved_ips
  if [[ -z "$panel_ip" ]]; then
    command -v getent >/dev/null 2>&1 || die "getent не найден: нельзя определить IP панели"
    resolved_ips="$(getent ahostsv4 "$PANEL_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)" || die "Не удалось определить IP панели"
    [[ -n "$resolved_ips" ]] || die "Нет A-записи для $PANEL_DOMAIN"
    [[ "$resolved_ips" != *$'\n'* ]] || die "У $PANEL_DOMAIN несколько A-адресов: укажите PANEL_SOURCE_IP"
    panel_ip="$resolved_ips"
  fi
  valid_ipv4 "$panel_ip" || die "Некорректный IP панели: $panel_ip"

  if ! command -v nft >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nftables
  fi
  mkdir -p /etc/remnanode /usr/local/sbin /etc/systemd/system/docker.service.d
  printf 'NODE_PORT=%s\nPANEL_IP=%s\n' "$NODE_PORT" "$panel_ip" > /etc/remnanode/panel-firewall.conf
  chmod 600 /etc/remnanode/panel-firewall.conf

  cat > /usr/local/sbin/remnanode-panel-firewall <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/remnanode/panel-firewall.conf

{
  if nft list table inet remnanode_panel >/dev/null 2>&1; then
    echo 'flush chain inet remnanode_panel input'
  else
    echo 'add table inet remnanode_panel'
    echo 'add chain inet remnanode_panel input { type filter hook input priority -150; policy accept; }'
  fi
  echo 'add rule inet remnanode_panel input iifname "lo" accept'
  printf 'add rule inet remnanode_panel input tcp dport %s ip saddr %s accept\n' "$NODE_PORT" "$PANEL_IP"
  printf 'add rule inet remnanode_panel input tcp dport %s drop\n' "$NODE_PORT"
} | nft -f -

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp >/dev/null
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  zones="$(firewall-cmd --get-active-zones | awk '/^[^[:space:]]/ {print $1}')"
  [[ -n "$zones" ]] || zones="$(firewall-cmd --get-default-zone)"
  for zone in $zones; do
    rule="rule family=\"ipv4\" source address=\"$PANEL_IP\" port port=\"$NODE_PORT\" protocol=\"tcp\" accept"
    if ! firewall-cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null; then
      firewall-cmd --zone="$zone" --add-rich-rule="$rule" >/dev/null
    fi
    if ! firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null; then
      firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule" >/dev/null
    fi
  done
fi
echo "Remnanode TCP $NODE_PORT доступен только с IP панели: $PANEL_IP"
EOF
  chmod 755 /usr/local/sbin/remnanode-panel-firewall

  cat > /etc/systemd/system/remnanode-panel-firewall.service <<'EOF'
[Unit]
Description=Restrict Remnanode management port to the panel
After=nftables.service ufw.service firewalld.service
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/remnanode-panel-firewall

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/docker.service.d/remnanode-panel-firewall.conf <<'EOF'
[Unit]
Requires=remnanode-panel-firewall.service
After=remnanode-panel-firewall.service
EOF
  systemctl daemon-reload
  systemctl enable remnanode-panel-firewall.service >/dev/null
  systemctl start remnanode-panel-firewall.service
}

write_site() {
  local variant title subtitle accent background surface layout
  variant=$(( $(printf '%s' "$SITE_DOMAIN" | cksum | awk '{print $1}') % 6 ))
  case "$variant" in
    0) title="The daily page"; subtitle="A little room for the present moment."; accent="#c36e51"; background="#f5f0e8"; surface="#e9dfd1"; layout="normal" ;;
    1) title="A small moment"; subtitle="Take a second. The rest can wait."; accent="#527d6b"; background="#edf2eb"; surface="#dce8dc"; layout="reverse" ;;
    2) title="Day by day"; subtitle="One quiet page for today."; accent="#6571a2"; background="#f0f0f7"; surface="#e0e2ef"; layout="normal" ;;
    3) title="The hours"; subtitle="Time for the things that matter."; accent="#a87554"; background="#f5eee9"; surface="#eadcd2"; layout="reverse" ;;
    4) title="Here and now"; subtitle="A clear view of this moment."; accent="#417b87"; background="#edf3f3"; surface="#dce9e9"; layout="normal" ;;
    5) title="Today, simply"; subtitle="A moment to begin again."; accent="#777254"; background="#f3f1e8"; surface="#e6e2d2"; layout="reverse" ;;
  esac
  cat > "$SITE_DIR/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="$background">
<title>$title — will project</title>
<style>
:root{color-scheme:light;--accent:$accent;--background:$background;--surface:$surface}*{box-sizing:border-box}body{margin:0;min-height:100vh;background:var(--background);color:#292b28;font-family:Arial,Helvetica,sans-serif}main{max-width:1100px;min-height:100vh;margin:auto;padding:36px 42px;display:flex;flex-direction:column}header,footer{display:flex;align-items:center;justify-content:space-between;font-size:13px;letter-spacing:.04em}header strong{font-size:17px;letter-spacing:-.04em}header span,footer{color:#777c75}.stage{display:grid;grid-template-columns:1.1fr .9fr;gap:7vw;align-items:center;flex:1;padding:72px 0}.stage.reverse .copy{order:2}.stage.reverse .clock{order:1}.copy{max-width:610px}.eyebrow,.clock-label{color:var(--accent);font-size:13px;font-weight:700;letter-spacing:.13em;text-transform:uppercase}h1{font-size:clamp(54px,8vw,108px);line-height:.98;letter-spacing:-.065em;font-weight:500;margin:23px 0 30px}p{font-size:18px;line-height:1.6;color:#656b65;margin:0}.clock{border-radius:26px;background:var(--surface);padding:36px;min-height:260px;display:flex;flex-direction:column;justify-content:space-between}.clock-time{font-size:clamp(52px,6vw,80px);line-height:1;letter-spacing:-.07em;font-variant-numeric:tabular-nums}.clock-date{color:#60665f;font-size:15px}footer{border-top:1px solid rgba(0,0,0,.1);padding-top:23px}@media(max-width:720px){main{padding:25px}.stage{grid-template-columns:1fr;gap:46px;padding:88px 0 62px}.stage.reverse .copy,.stage.reverse .clock{order:initial}h1{font-size:clamp(54px,15vw,88px)}.clock{min-height:220px;padding:28px}}
</style>
</head>
<body>
<main>
<header><strong>will project</strong><span>Every day has its hour</span></header>
<section class="stage $layout">
<div class="copy"><div class="eyebrow">A simple place</div><h1>$title</h1><p>$subtitle</p></div>
<div class="clock" aria-label="Local date and time"><span class="clock-label">Your local time</span><time id="clock-time" class="clock-time">--:--</time><time id="clock-date" class="clock-date"></time></div>
</section>
<footer><span>$SITE_DOMAIN</span><span>Made for the moment</span></footer>
</main>
<script>
const timeElement=document.getElementById('clock-time');
const dateElement=document.getElementById('clock-date');
function updateClock(){const now=new Date();timeElement.textContent=new Intl.DateTimeFormat('en',{hour:'2-digit',minute:'2-digit',hour12:false}).format(now);dateElement.textContent=new Intl.DateTimeFormat('en',{weekday:'long',day:'numeric',month:'long',year:'numeric'}).format(now);};
updateClock();
setInterval(updateClock,1000);
</script>
</body>
</html>
EOF
  chmod 644 "$SITE_DIR/index.html"
  printf '%s\n' "$SITE_DOMAIN" > "$REMNA_DIR/selfsteal/domain"
}

start_http_site() {
  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $SITE_DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_DIR;
        default_type text/plain;
    }
    location / {
        return 301 https://$SITE_DOMAIN\$request_uri;
    }
}
EOF
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

start_hy2_acme() {
  cat > "$HY2_ACME_CONF" <<EOF
server {
    listen 80;
    server_name $HY2_DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_DIR;
        default_type text/plain;
    }
    location / {
        return 404;
    }
}
EOF
  nginx -t
  systemctl reload nginx
}

finish_https_site() {
  cat >> "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$SITE_PORT ssl http2;
    server_name $SITE_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$SITE_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SITE_DOMAIN/privkey.pem;
    root $SITE_DIR;
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  nginx -t
  systemctl reload nginx
}

[[ $EUID -eq 0 ]] || die "Run as root"
[[ "$SITE_PORT" =~ ^[1-9][0-9]*$ ]] && (( SITE_PORT >= 1024 && SITE_PORT <= 65535 )) || die "SELFSTEAL_PORT должен быть числом от 1024 до 65535"
if [[ -z "$NODE_PORT" && -f "$REMNA_DIR/.env" ]]; then
  NODE_PORT="$(sed -n 's/^NODE_PORT=//p' "$REMNA_DIR/.env" | tail -n1)"
fi
NODE_PORT="${NODE_PORT:-2222}"
[[ "$NODE_PORT" =~ ^[1-9][0-9]*$ ]] && (( NODE_PORT <= 65535 )) || die "Некорректный NODE_PORT: $NODE_PORT"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker не найден. Устанавливаю..."
  command -v curl >/dev/null 2>&1 || {
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl
  }
  curl -fsSL https://get.docker.com | sh
fi

docker compose version >/dev/null 2>&1 || die "docker compose not found"

echo "=== will Remnawave Node installer v5 ==="

SECRET_KEY="${SECRET_KEY:-}"
if [[ -z "$SECRET_KEY" && -f "$REMNA_DIR/.env" ]]; then
  SECRET_KEY="$(sed -n 's/^SECRET_KEY=//p' "$REMNA_DIR/.env" | tail -n1)"
fi
if [[ -z "$SECRET_KEY" ]]; then
  SECRET_KEY="$(read_required 'SECRET_KEY: ')"
fi

ENABLE_SITE=0
SITE_DOMAIN=""
if ask_yes_no_default_yes "Настроить сайт для REALITY self-steal?"; then
  ENABLE_SITE=1
  SITE_DOMAIN="$(read_required 'Домен этой ноды (например, de1.willproject.cc): ')"
  SITE_DOMAIN="$(printf '%s' "$SITE_DOMAIN" | tr '[:upper:]' '[:lower:]')"
  validate_domain "$SITE_DOMAIN"
fi

ENABLE_HY2=0
HY2_DOMAIN=""

if ask_yes_no "Нужна Hysteria2?"; then
  ENABLE_HY2=1
  HY2_DOMAIN="$(read_required 'Домен Hysteria2: ')"
  HY2_DOMAIN="$(printf '%s' "$HY2_DOMAIN" | tr '[:upper:]' '[:lower:]')"
  validate_domain "$HY2_DOMAIN"
  [[ "$HY2_DOMAIN" != "$SITE_DOMAIN" ]] || die "Домен Hysteria2 должен отличаться от домена сайта REALITY"
fi

configure_public_firewall

if (( ENABLE_SITE || ENABLE_HY2 )); then
  if ! command -v certbot >/dev/null || ! command -v dig >/dev/null || { (( ENABLE_SITE )) && ! command -v nginx >/dev/null; }; then
    apt-get update
    packages=(certbot dnsutils)
    if (( ENABLE_SITE )); then packages+=(nginx); fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  fi
fi

if (( ENABLE_SITE )); then
  existing_domain=""
  if [[ -f "$REMNA_DIR/selfsteal/domain" ]]; then
    existing_domain="$(cat "$REMNA_DIR/selfsteal/domain")"
  fi
  [[ -z "$existing_domain" || "$existing_domain" == "$SITE_DOMAIN" ]] || die "Установлен другой домен self-steal: $existing_domain"
  site_ips="$(dig +short A "$SITE_DOMAIN" | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/')"
  [[ -n "$site_ips" ]] || die "Нет A-записи для $SITE_DOMAIN"
  public_ip="${SELFSTEAL_PUBLIC_IP:-$(curl -4fsS --noproxy '*' --max-time 8 https://api.ipify.org)}"
  [[ "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Не удалось определить публичный IPv4 ноды"
  printf '%s\n' "$site_ips" | grep -Fxq "$public_ip" || die "A-запись $SITE_DOMAIN не указывает на IPv4 этой ноды ($public_ip). Нужна прямая DNS-запись без проксирования."
fi

if (( ENABLE_HY2 )); then
  hy2_ips="$(dig +short A "$HY2_DOMAIN" | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/')"
  [[ -n "$hy2_ips" ]] || die "Нет A-записи для $HY2_DOMAIN"
  public_ip="${public_ip:-${SELFSTEAL_PUBLIC_IP:-$(curl -4fsS --noproxy '*' --max-time 8 https://api.ipify.org)}}"
  printf '%s\n' "$hy2_ips" | grep -Fxq "$public_ip" || die "A-запись $HY2_DOMAIN не указывает на IPv4 этой ноды ($public_ip). Нужна прямая DNS-запись без проксирования."
fi

mkdir -p "$REMNA_DIR"

if (( ENABLE_SITE )); then
  install -d -m 755 "$REMNA_DIR/selfsteal" "$SITE_DIR" "$ACME_DIR"
  write_site
  start_http_site
  if (( ENABLE_HY2 )); then start_hy2_acme; fi
  if [[ -f "/etc/letsencrypt/live/$SITE_DOMAIN/fullchain.pem" ]]; then
    if [[ ! -f "/etc/letsencrypt/renewal/$SITE_DOMAIN.conf" ]] || ! grep -Eq '^authenticator[[:space:]]*=[[:space:]]*webroot$' "/etc/letsencrypt/renewal/$SITE_DOMAIN.conf"; then
      certbot renew --cert-name "$SITE_DOMAIN" --webroot --webroot-path "$ACME_DIR" --dry-run
      certbot renew --cert-name "$SITE_DOMAIN" --webroot --webroot-path "$ACME_DIR" --force-renewal
    fi
  else
    certbot certonly --webroot -w "$ACME_DIR" -d "$SITE_DOMAIN" --cert-name "$SITE_DOMAIN" --non-interactive --agree-tos -m "$CERT_EMAIL"
  fi
  finish_https_site
  curl -fsS --noproxy '*' --max-time 8 --resolve "$SITE_DOMAIN:$SITE_PORT:127.0.0.1" "https://$SITE_DOMAIN:$SITE_PORT/" >/dev/null || die "Локальная HTTPS-проверка self-steal не прошла"
fi

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

if [[ -d /etc/letsencrypt ]]; then
  cat >> "$REMNA_DIR/docker-compose.yml" <<'EOF'
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
EOF
fi

configure_panel_firewall

if (( ENABLE_HY2 )); then
  if [[ ! -f "/etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem" ]]; then
    if (( ENABLE_SITE )); then
      certbot certonly --webroot -w "$ACME_DIR" -d "$HY2_DOMAIN" --cert-name "$HY2_DOMAIN" --non-interactive --agree-tos -m "$CERT_EMAIL"
    else
      certbot certonly --standalone -d "$HY2_DOMAIN" --non-interactive --agree-tos -m "$CERT_EMAIL"
    fi
  fi
fi

if (( ENABLE_SITE || ENABLE_HY2 )); then
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  if [[ ! -f "$RENEW_HOOK" ]]; then
    printf '#!/bin/sh\n' > "$RENEW_HOOK"
  fi
  if (( ENABLE_SITE )) && ! grep -Fxq 'systemctl reload nginx' "$RENEW_HOOK"; then
    printf '%s\n' 'systemctl reload nginx' >> "$RENEW_HOOK"
  fi
  if (( ENABLE_HY2 )) && ! grep -Fxq 'docker restart remnanode' "$RENEW_HOOK"; then
    printf '%s\n' 'docker restart remnanode' >> "$RENEW_HOOK"
  fi
  chmod +x "$RENEW_HOOK"
fi

cd "$REMNA_DIR"
docker compose pull
docker compose up -d

echo "=== DONE ==="
docker ps --filter name=remnanode
if (( ENABLE_SITE )); then
  echo "После настройки REALITY сайт будет доступен по адресу: https://$SITE_DOMAIN/"
  echo "REALITY: target=127.0.0.1:$SITE_PORT, serverNames=[\"$SITE_DOMAIN\"], xver=0"
  echo "В Remnawave укажите этот домен в SNI клиентского профиля и target в конфигурации REALITY."
fi
if (( ENABLE_HY2 )); then
  echo "Hysteria2: отдельный домен $HY2_DOMAIN, сертификат /etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem"
fi
