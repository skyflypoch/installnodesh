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
  local variant accent background ink muted zone other_zone
  variant=$(( $(printf '%s' "$SITE_DOMAIN" | cksum | awk '{print $1}') % 6 ))
  case "$variant" in
    0) accent="#245f59"; background="#eef3f1"; ink="#183531"; muted="#59736d"; zone="Europe/Berlin"; other_zone="America/New_York" ;;
    1) accent="#345d86"; background="#eef2f7"; ink="#1d3349"; muted="#61778b"; zone="Europe/Helsinki"; other_zone="Europe/London" ;;
    2) accent="#6c6030"; background="#f3f3ec"; ink="#373627"; muted="#77755e"; zone="Europe/Amsterdam"; other_zone="Asia/Tokyo" ;;
    3) accent="#87554b"; background="#f5f0ee"; ink="#402d2b"; muted="#866d68"; zone="Europe/Tallinn"; other_zone="America/Toronto" ;;
    4) accent="#28677c"; background="#edf3f5"; ink="#1e3740"; muted="#5e7982"; zone="Europe/Warsaw"; other_zone="Asia/Singapore" ;;
    5) accent="#5e5883"; background="#f2f1f6"; ink="#333047"; muted="#747085"; zone="Europe/Vienna"; other_zone="America/Los_Angeles" ;;
  esac
  case "$SITE_DOMAIN" in
    de.*|de-*) zone="Europe/Berlin"; other_zone="Europe/London" ;;
    nl.*|nl-*) zone="Europe/Amsterdam"; other_zone="America/New_York" ;;
    fi.*|fi-*) zone="Europe/Helsinki"; other_zone="Europe/London" ;;
    ee.*|ee-*) zone="Europe/Tallinn"; other_zone="Europe/London" ;;
    pl.*|pl-*) zone="Europe/Warsaw"; other_zone="Asia/Tokyo" ;;
    hk.*|hk-*) zone="Asia/Hong_Kong"; other_zone="Europe/London" ;;
    ae.*|ae-*) zone="Asia/Dubai"; other_zone="Europe/London" ;;
  esac
  cat > "$SITE_DIR/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="__BACKGROUND__">
<meta name="description" content="Compare local times between cities and plan across time zones.">
<title>Clockline — time zone converter</title>
<style>
:root{color-scheme:light;--accent:__ACCENT__;--background:__BACKGROUND__;--ink:__INK__;--muted:__MUTED__}
*{box-sizing:border-box}
html{font-family:"Avenir Next","Segoe UI",Arial,sans-serif}
body{margin:0;min-height:100vh;background:var(--background);color:var(--ink)}
button,input,select{font:inherit}
button{cursor:pointer}
.page{max-width:1120px;min-height:100vh;margin:auto;padding:0 34px;display:flex;flex-direction:column}
.topbar{min-height:84px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid rgba(28,54,50,.15)}
.brand{display:inline-flex;align-items:center;gap:10px;color:var(--ink);text-decoration:none;font-size:25px;font-weight:750;letter-spacing:-.07em}
.brand-mark{width:12px;height:12px;border:3px solid var(--accent);border-radius:50%}
.topbar-note{font-size:14px;color:var(--muted)}
main{flex:1}
.intro{padding:76px 0 43px;max-width:680px}
.intro h1{font-size:clamp(43px,6.2vw,76px);letter-spacing:-.065em;line-height:1.03;font-weight:650;margin:0 0 20px}
.intro p{font-size:18px;line-height:1.55;color:var(--muted);margin:0;max-width:540px}
.workspace{display:grid;grid-template-columns:1.06fr .94fr;gap:18px}
.planner,.result{border-radius:22px;min-height:420px}
.planner{background:#fff;padding:33px;border:1px solid rgba(28,54,50,.12)}
.field-row{display:grid;grid-template-columns:1fr 1fr;gap:15px}
.field{display:flex;flex-direction:column;gap:9px}
.field label{font-size:14px;font-weight:650}
.field select,.field input{width:100%;min-width:0;height:52px;border:1px solid #c9d4d0;border-radius:11px;background:#fff;color:var(--ink);padding:0 14px;font-size:16px}
.field select:focus-visible,.field input:focus-visible,.button:focus-visible,.result-bottom button:focus-visible{outline:3px solid var(--accent);outline-offset:3px}
.time-field{margin-top:27px}
.actions{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-top:27px}
.button{min-height:46px;padding:0 18px;border-radius:10px;border:1px solid #c9d4d0;background:#fff;color:var(--ink);font-weight:650}
.button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.button:hover{filter:brightness(.96)}
.result{background:var(--ink);color:#fff;padding:38px;display:flex;flex-direction:column;justify-content:space-between}
.result-label{font-size:15px;color:#c8d8d3}
.result-time{display:block;font-size:clamp(64px,7vw,101px);line-height:1;letter-spacing:-.075em;font-weight:600;font-variant-numeric:tabular-nums;margin:30px 0 13px}
.result-date{font-size:18px;line-height:1.45;color:#e0eae6;margin:0}
.result-bottom{display:flex;align-items:center;justify-content:space-between;gap:18px;border-top:1px solid rgba(255,255,255,.25);padding-top:24px}
.result-bottom span{font-size:14px;color:#c8d8d3}
.result-bottom button{background:transparent;border:1px solid rgba(255,255,255,.48);border-radius:9px;color:#fff;padding:10px 14px;font-weight:600}
.result-bottom button:hover{background:rgba(255,255,255,.1)}
.live{display:grid;grid-template-columns:1fr 1fr;gap:18px;margin:23px 0 68px}
.live-item{display:flex;align-items:baseline;justify-content:space-between;gap:20px;padding:17px 4px;border-bottom:1px solid rgba(28,54,50,.17)}
.live-item span{color:var(--muted);font-size:14px}
.live-item strong{font-size:21px;font-variant-numeric:tabular-nums;font-weight:650}
.status{min-height:20px;font-size:14px;color:var(--muted);margin:18px 0 0}
.status.error{color:#a13636}
.footer{border-top:1px solid rgba(28,54,50,.15);padding:24px 0 32px;font-size:13px;color:var(--muted);display:flex;justify-content:space-between;gap:18px}
@media(max-width:760px){.page{padding:0 20px}.topbar{min-height:72px}.topbar-note{display:none}.intro{padding:54px 0 32px}.intro p{font-size:16px}.workspace{grid-template-columns:1fr}.planner,.result{min-height:0}.planner{padding:24px}.result{padding:28px;min-height:280px}.result-time{font-size:72px;margin:24px 0 12px}.live{margin:13px 0 44px}.footer{flex-direction:column}}
@media(max-width:480px){.field-row{grid-template-columns:1fr}.result-time{font-size:64px}.live{grid-template-columns:1fr;gap:0}.actions .button{flex:1}.result-bottom{align-items:flex-start;flex-direction:column}}
</style>
</head>
<body>
<div class="page">
<header class="topbar"><a class="brand" href="/">clockline<span class="brand-mark" aria-hidden="true"></span></a><span class="topbar-note">Time zone converter</span></header>
<main>
<section class="intro"><h1>Find the right hour.</h1><p>Compare local times before you call, book or travel. Choose a time in one city to see the same moment in another.</p></section>
<section class="workspace" aria-label="Time zone converter">
<div class="planner">
<div class="field-row"><div class="field"><label for="from-zone">From</label><select id="from-zone"></select></div><div class="field"><label for="to-zone">To</label><select id="to-zone"></select></div></div>
<div class="field time-field"><label for="from-time">Date and time in the first city</label><input id="from-time" type="datetime-local" required></div>
<div class="actions"><button class="button primary" id="now-button" type="button">Use current time</button><button class="button" id="swap-button" type="button">Swap cities</button></div>
<p class="status" id="status" role="status" aria-live="polite"></p>
</div>
<div class="result" aria-live="polite"><div><span class="result-label" id="result-label">In the second city</span><strong class="result-time" id="result-time">--:--</strong><p class="result-date" id="result-date">Choose a date and time</p></div><div class="result-bottom"><span>The same moment, in local time</span><button id="copy-button" type="button">Copy result</button></div></div>
</section>
<section class="live" aria-label="Current local times"><div class="live-item"><span id="live-from-label"></span><strong id="live-from-time">--:--</strong></div><div class="live-item"><span id="live-to-label"></span><strong id="live-to-time">--:--</strong></div></section>
</main>
<footer class="footer"><span>Time zones and daylight saving changes are applied automatically.</span><span>__DOMAIN__</span></footer>
</div>
<script>
const places=[['Europe/Berlin','Berlin'],['Europe/London','London'],['Europe/Amsterdam','Amsterdam'],['Europe/Helsinki','Helsinki'],['Europe/Tallinn','Tallinn'],['Europe/Warsaw','Warsaw'],['Europe/Vienna','Vienna'],['Asia/Dubai','Dubai'],['Asia/Hong_Kong','Hong Kong'],['Asia/Singapore','Singapore'],['Asia/Tokyo','Tokyo'],['America/New_York','New York'],['America/Toronto','Toronto'],['America/Los_Angeles','Los Angeles']];
const placeNames=Object.fromEntries(places);
const fromZone=document.getElementById('from-zone');
const toZone=document.getElementById('to-zone');
const fromTime=document.getElementById('from-time');
const resultLabel=document.getElementById('result-label');
const resultTime=document.getElementById('result-time');
const resultDate=document.getElementById('result-date');
const status=document.getElementById('status');
const liveFromLabel=document.getElementById('live-from-label');
const liveToLabel=document.getElementById('live-to-label');
const liveFromTime=document.getElementById('live-from-time');
const liveToTime=document.getElementById('live-to-time');
for(const [zone,name] of places){fromZone.add(new Option(name,zone));toZone.add(new Option(name,zone));};
function stored(key,fallback){try{const value=localStorage.getItem(key);return placeNames[value]?value:fallback;}catch{return fallback;}};
function remember(){try{localStorage.setItem('clockline-from',fromZone.value);localStorage.setItem('clockline-to',toZone.value);}catch{}};
fromZone.value=stored('clockline-from','__FROM_ZONE__');
toZone.value=stored('clockline-to','__TO_ZONE__');
let previousFromZone=fromZone.value;
function pieces(date,zone){const values={};for(const part of new Intl.DateTimeFormat('en-GB',{timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(date)){if(part.type!=='literal'){values[part.type]=Number(part.value);}};return values;};
function inputValue(date,zone){const p=pieces(date,zone);return String(p.year).padStart(4,'0')+'-'+String(p.month).padStart(2,'0')+'-'+String(p.day).padStart(2,'0')+'T'+String(p.hour).padStart(2,'0')+':'+String(p.minute).padStart(2,'0');};
function instantFromWall(value,zone){const match=/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(value);if(!match){return null;};const target=Date.UTC(Number(match[1]),Number(match[2])-1,Number(match[3]),Number(match[4]),Number(match[5]));let instant=target;for(let attempt=0;attempt<4;attempt++){const p=pieces(new Date(instant),zone);const shown=Date.UTC(p.year,p.month-1,p.day,p.hour,p.minute);const shift=target-shown;instant+=shift;if(shift===0){break;}};const result=new Date(instant);return inputValue(result,zone)===value?result:null;};
function clock(date,zone){return new Intl.DateTimeFormat('en-GB',{timeZone:zone,hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).format(date);};
function calendar(date,zone){return new Intl.DateTimeFormat('en-GB',{timeZone:zone,weekday:'long',day:'numeric',month:'long',year:'numeric'}).format(date);};
function renderLive(){const now=new Date();liveFromLabel.textContent='Right now in '+placeNames[fromZone.value];liveToLabel.textContent='Right now in '+placeNames[toZone.value];liveFromTime.textContent=clock(now,fromZone.value);liveToTime.textContent=clock(now,toZone.value);};
function render(){resultLabel.textContent='In '+placeNames[toZone.value];const date=instantFromWall(fromTime.value,fromZone.value);if(!date){resultTime.textContent='--:--';resultDate.textContent='Choose a valid local date and time';status.textContent='This local time may not exist because the clocks changed. Try another time.';status.classList.add('error');renderLive();return;};resultTime.textContent=clock(date,toZone.value);resultDate.textContent=calendar(date,toZone.value);status.textContent='';status.classList.remove('error');renderLive();};
fromTime.value=inputValue(new Date(),fromZone.value);
fromZone.addEventListener('change',()=>{const date=instantFromWall(fromTime.value,previousFromZone);previousFromZone=fromZone.value;if(date){fromTime.value=inputValue(date,fromZone.value);}remember();render();});
toZone.addEventListener('change',()=>{remember();render();});
fromTime.addEventListener('input',render);
document.getElementById('now-button').addEventListener('click',()=>{fromTime.value=inputValue(new Date(),fromZone.value);render();});
document.getElementById('swap-button').addEventListener('click',()=>{const date=instantFromWall(fromTime.value,fromZone.value);const oldFrom=fromZone.value;fromZone.value=toZone.value;toZone.value=oldFrom;previousFromZone=fromZone.value;if(date){fromTime.value=inputValue(date,fromZone.value);}remember();render();});
document.getElementById('copy-button').addEventListener('click',async()=>{const date=instantFromWall(fromTime.value,fromZone.value);if(!date){render();return;};const value=clock(date,toZone.value)+' '+calendar(date,toZone.value)+' in '+placeNames[toZone.value];try{await navigator.clipboard.writeText(value);status.textContent='Copied the converted time.';status.classList.remove('error');}catch{status.textContent='Copy is unavailable in this browser.';status.classList.add('error');}});
render();
setInterval(renderLive,30000);
</script>
</body>
</html>
HTML
  sed \
    -e "s|__ACCENT__|$accent|g" \
    -e "s|__BACKGROUND__|$background|g" \
    -e "s|__INK__|$ink|g" \
    -e "s|__MUTED__|$muted|g" \
    -e "s|__FROM_ZONE__|$zone|g" \
    -e "s|__TO_ZONE__|$other_zone|g" \
    -e "s|__DOMAIN__|$SITE_DOMAIN|g" \
    "$SITE_DIR/index.html" > "$SITE_DIR/index.next.html"
  mv "$SITE_DIR/index.next.html" "$SITE_DIR/index.html"
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
