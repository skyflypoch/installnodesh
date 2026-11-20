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
SHARED_HY2_HOOK="/etc/letsencrypt/renewal-hooks/deploy/00-remnanode-shared-hy2-cert.sh"
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-remnanode.sh"
THEME_FILE="$REMNA_DIR/selfsteal/theme"
SPEED_PORT="${SELFSTEAL_SPEED_PORT:-$((SITE_PORT + 1))}"
SITE_THEMES=(speedtest lg mirror nightly podcast lectures gameserver)
SYSCTL_CONF="/etc/sysctl.d/90-remnanode-net.conf"
CF_HELPER="/usr/local/sbin/remnanode-cf-dns"
CF_ENV="/etc/remnanode/cloudflare.env"
USE_CF=0
NODE_IPV4=""
NODE_IPV6=""

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

# Проверяем DNS против всех IPv4 ноды, а не только IP исходящего соединения.
# SELFSTEAL_PUBLIC_IP нужен для дополнительного публичного IP за 1:1 NAT,
# который провайдер не назначает непосредственно сетевому интерфейсу.
collect_node_ipv4() {
  local outgoing_ip=""
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show scope global | awk '{split($4, parts, "/"); print parts[1]}'
  fi
  if [[ -n "${SELFSTEAL_PUBLIC_IP:-}" ]]; then
    printf '%s\n' "$SELFSTEAL_PUBLIC_IP"
  fi
  # Исходящий IP полезен, если у сервера NAT. Ошибка внешнего сервиса не критична.
  outgoing_ip="$(curl -4fsS --noproxy '*' --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if valid_ipv4 "$outgoing_ip"; then
    printf '%s\n' "$outgoing_ip"
  fi
}

check_domain_dns() {
  local domain="$1" dns_ip local_ip match=""
  local -a dns_ips=() server_ips=()
  if [[ -n "${SELFSTEAL_PUBLIC_IP:-}" ]]; then
    valid_ipv4 "$SELFSTEAL_PUBLIC_IP" || die "Некорректный SELFSTEAL_PUBLIC_IP: $SELFSTEAL_PUBLIC_IP"
  fi
  mapfile -t dns_ips < <(dig +short A "$domain" ${DNS_RESOLVER:+"@$DNS_RESOLVER"} | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print}' | sort -u)
  (( ${#dns_ips[@]} > 0 )) || die "Нет A-записи для $domain"
  mapfile -t server_ips < <(collect_node_ipv4 | sort -u)
  (( ${#server_ips[@]} > 0 )) || die "Не удалось определить IPv4 ноды (ip addr и api.ipify.org). Укажите SELFSTEAL_PUBLIC_IP."
  for dns_ip in "${dns_ips[@]}"; do
    for local_ip in "${server_ips[@]}"; do
      if [[ "$dns_ip" == "$local_ip" ]]; then
        match="$dns_ip"
        break 2
      fi
    done
  done
  if [[ -z "$match" ]]; then
    die "A-запись $domain ($(IFS=', '; echo "${dns_ips[*]}")) не совпадает ни с одним IPv4 ноды ($(IFS=', '; echo "${server_ips[*]}")). Если IP выдан провайдером через 1:1 NAT, задайте SELFSTEAL_PUBLIC_IP вручную."
  fi
  echo "DNS $domain: $match — один из IPv4 ноды, проверка пройдена"
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

write_formats_site() {
  local variant
  variant=$(( $(printf '%s' "$SITE_DOMAIN" | cksum | awk '{print $1}') % 6 ))
  (umask 022; SITE_DIR="$1" SITE_DOMAIN="$SITE_DOMAIN" SITE_VARIANT="$variant" python3 - <<'PY'
from pathlib import Path
from html import escape
import json
import os

root = Path(os.environ["SITE_DIR"])
domain = os.environ["SITE_DOMAIN"]
variant = int(os.environ["SITE_VARIANT"])
palettes = [
    ("#255f69", "#eef3f3", "#183339", "#58717a"),
    ("#3d5c89", "#eef1f7", "#1f3048", "#64748c"),
    ("#655c35", "#f3f2e9", "#393527", "#7b7661"),
    ("#8a5148", "#f6f0ed", "#402d2a", "#806962"),
    ("#2a6b60", "#edf4f0", "#1e3a32", "#5c7b70"),
    ("#675983", "#f2f0f6", "#322e45", "#777088"),
]
accent, background, ink, muted = palettes[variant]
headlines = [
    "Разобраться с файлом проще, чем кажется.",
    "Понятные форматы для обычных задач.",
    "Открывайте, проверяйте, сохраняйте.",
    "Что внутри файла — без догадок.",
    "Файлы без лишней сложности.",
    "Когда формат перестаёт быть загадкой.",
]
featured = ["json", "csv", "markdown", "pdf", "txt", "zip"][variant]
root.mkdir(parents=True, exist_ok=True)
(root / "assets").mkdir(exist_ok=True)

css = r'''
:root{color-scheme:light;--accent:ACCENT;--bg:BACKGROUND;--ink:INK;--muted:MUTED;--line:#d7dcd9;--paper:#fff}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{margin:0;background:var(--bg);color:var(--ink);font-family:"Segoe UI",Arial,sans-serif;-webkit-font-smoothing:antialiased}
a{color:inherit}button,input,textarea{font:inherit}button{cursor:pointer}
.site{max-width:1200px;margin:auto;padding:0 38px}
.skip{position:absolute;left:-9999px;top:10px;padding:10px;background:#fff;z-index:100}.skip:focus{left:10px}
.topbar{min-height:85px;display:flex;align-items:center;justify-content:space-between;gap:26px;border-bottom:1px solid var(--line)}
.brand{font-weight:800;font-size:24px;letter-spacing:-.07em;text-decoration:none;white-space:nowrap}
.brand i{font-style:normal;color:var(--accent)}
.nav{display:flex;gap:29px;align-items:center;font-size:14px;font-weight:650}
.nav a{text-decoration:none;color:var(--muted);white-space:nowrap}.nav a:hover,.nav a[aria-current=page]{color:var(--ink)}.nav a[aria-current=page]{box-shadow:0 2px var(--accent)}
.hero{padding:82px 0 78px;display:grid;grid-template-columns:1.08fr .92fr;gap:7%;align-items:center}
.eyebrow{display:block;margin-bottom:20px;font-size:12px;font-weight:800;letter-spacing:.14em;text-transform:uppercase;color:var(--accent)}
h1{font-size:clamp(46px,6.2vw,82px);line-height:1.05;letter-spacing:-.067em;font-weight:750;margin:0 0 24px}
h2{font-size:clamp(29px,3.5vw,44px);line-height:1.14;letter-spacing:-.048em;margin:0 0 18px}
h3{font-size:21px;line-height:1.27;letter-spacing:-.025em;margin:0 0 11px}
p{line-height:1.66;margin:0 0 18px}.hero p,.intro p{font-size:18px;color:var(--muted);max-width:620px}
.actions{display:flex;gap:11px;flex-wrap:wrap;margin-top:30px}
.btn{display:inline-flex;align-items:center;justify-content:center;min-height:46px;padding:0 18px;border:1px solid var(--accent);border-radius:9px;background:var(--accent);color:#fff;font-size:14px;font-weight:700;text-decoration:none}
.btn.alt{background:transparent;border-color:#bfcac5;color:var(--ink)}.btn:hover{filter:brightness(.95)}
.sample{background:var(--ink);color:#fff;border-radius:20px;padding:28px;min-height:390px;box-shadow:0 22px 50px rgba(31,42,38,.08)}
.sample-top{display:flex;align-items:center;justify-content:space-between;padding-bottom:18px;border-bottom:1px solid rgba(255,255,255,.2);font-size:12px;color:#c5d2cd}
.sample-dots{display:flex;gap:6px}.sample-dots i{width:8px;height:8px;border-radius:50%;background:#8da89e}
.sample pre{white-space:pre-wrap;word-break:break-word;line-height:1.7;font-size:15px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;margin:25px 0;color:#e1eee9}
.sample-foot{margin-top:25px;padding-top:17px;border-top:1px solid rgba(255,255,255,.2);font-size:13px;color:#c5d2cd}
.section{padding:67px 0;border-top:1px solid var(--line)}
.section-head{display:flex;justify-content:space-between;gap:32px;align-items:end;margin-bottom:27px}.section-head p{max-width:400px;color:var(--muted)}
.cards{display:grid;grid-template-columns:repeat(2,1fr);gap:16px}
.card{background:#fff;border:1px solid var(--line);border-radius:14px;padding:27px;text-decoration:none;display:flex;flex-direction:column;min-height:218px;transition:border-color .15s,transform .15s}
.card:hover{border-color:var(--accent);transform:translateY(-2px)}.card small{color:var(--accent);font-weight:800;letter-spacing:.1em;margin-bottom:27px}.card p{font-size:14px;color:var(--muted);margin:0}.card span{color:var(--accent);font-size:14px;font-weight:700;margin-top:auto;padding-top:20px}
.links{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}.links a{background:#fff;border:1px solid var(--line);border-radius:11px;padding:22px;text-decoration:none}.links a:hover{border-color:var(--accent)}.links strong{display:block;font-size:19px;margin-bottom:7px}.links span{display:block;font-size:14px;line-height:1.5;color:var(--muted)}
.band{display:grid;grid-template-columns:1fr auto;gap:20px;align-items:center;background:var(--ink);color:#fff;border-radius:18px;padding:36px}.band p{color:#d0dcd6;margin:0}.band .btn{background:#fff;border-color:#fff;color:var(--ink)}
.intro{max-width:790px;padding:64px 0 43px}.intro h1{font-size:clamp(42px,5.6vw,68px)}.crumbs{font-size:13px;color:var(--muted);margin-bottom:25px}.crumbs a{text-decoration:none}.crumbs a:hover{text-decoration:underline}
.tool-layout{display:grid;grid-template-columns:1fr .85fr;gap:17px;padding-bottom:65px}.panel{background:#fff;border:1px solid var(--line);border-radius:15px;padding:28px}.panel.dark{background:var(--ink);color:#fff;border-color:var(--ink)}
label{display:block;font-size:14px;font-weight:700;margin-bottom:10px}
textarea,input[type=text]{width:100%;border:1px solid #bbc9c2;border-radius:9px;background:#fff;color:#172f29;padding:13px;font-size:15px}
textarea{min-height:270px;resize:vertical;line-height:1.5}.shortarea{min-height:175px}
textarea:focus-visible,input:focus-visible,button:focus-visible,a:focus-visible{outline:3px solid var(--accent);outline-offset:3px}
.feedback{min-height:24px;margin:14px 0 0;font-size:14px;color:var(--muted)}.feedback.error{color:#b23e39}
.stat-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:12px}.stat{padding:18px;border-radius:10px;background:#f0f5f2}.stat strong{display:block;font-size:32px;letter-spacing:-.05em}.stat span{color:var(--muted);font-size:13px}
.panel pre{white-space:pre-wrap;word-break:break-word;font:14px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;margin:0}
.output{min-height:110px;padding:17px;background:#f0f4f2;border-radius:9px;overflow:auto;word-break:break-word}
.table-scroll{overflow:auto;max-height:520px}.data-table{border-collapse:collapse;width:100%;font-size:14px}.data-table th,.data-table td{padding:10px 12px;border-bottom:1px solid var(--line);text-align:left;min-width:90px}.data-table th{background:#e8f0eb;position:sticky;top:0}
.prose{max-width:780px;padding-bottom:78px}.prose h2{font-size:31px;margin:48px 0 15px}.prose h3{margin:28px 0 12px}.prose p,.prose li{font-size:17px;line-height:1.72;color:#405c53}.prose ul,.prose ol{padding-left:23px}.prose li{margin:9px 0}
.prose aside{background:#fff;border-left:4px solid var(--accent);padding:22px 25px;margin:30px 0}.prose aside p{margin:0}
.inline-code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em;background:#e5ebe7;border-radius:4px;padding:2px 5px}
.format-facts{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;padding:0 0 55px}.format-facts div{border-top:2px solid var(--accent);padding-top:16px}.format-facts strong{display:block;margin-bottom:8px}.format-facts span{font-size:14px;color:var(--muted);line-height:1.5}
.related{padding:35px 0 70px;border-top:1px solid var(--line)}
.footer{display:flex;justify-content:space-between;gap:25px;border-top:1px solid var(--line);padding:30px 0 37px;color:var(--muted);font-size:13px}.footer-links{display:flex;gap:17px;flex-wrap:wrap}.footer a{text-decoration:none}.footer a:hover{text-decoration:underline}
@media(max-width:850px){.site{padding:0 22px}.topbar{align-items:flex-start;flex-direction:column;justify-content:center;padding:20px 0;gap:16px}.nav{max-width:100%;overflow:auto;padding-bottom:5px}.hero{grid-template-columns:1fr;gap:31px;padding:60px 0}.sample{min-height:0}.tool-layout{grid-template-columns:1fr}.section-head{display:block}.links{grid-template-columns:repeat(2,1fr)}}
@media(max-width:560px){.site{padding:0 18px}.nav{gap:19px;font-size:13px}.hero h1{font-size:48px}.hero p,.intro p{font-size:16px}.intro{padding:47px 0 30px}.cards,.links,.format-facts{grid-template-columns:1fr}.card{min-height:175px}.band{grid-template-columns:1fr}.panel{padding:22px}.footer{flex-direction:column}.sample pre{font-size:13px}.stat strong{font-size:27px}}
'''
for key,value in {"ACCENT":accent,"BACKGROUND":background,"INK":ink,"MUTED":muted}.items():
    css = css.replace(key,value)
(root / "assets/site.css").write_text(css.strip()+"\n")

js = r'''
"use strict";
const byId=id=>document.getElementById(id);
const setStatus=(id,message,error=false)=>{const el=byId(id);el.textContent=message;el.classList.toggle("error",error);};
const textInput=byId("text-input");
if(textInput){const update=()=>{const value=textInput.value;byId("chars").textContent=String(Array.from(value).length);byId("words").textContent=String((value.trim().match(/\S+/g)||[]).length);byId("lines").textContent=String(value?value.split(/\r\n|\r|\n/).length:0);byId("bytes").textContent=String(new TextEncoder().encode(value).length);};textInput.addEventListener("input",update);byId("clear-text").addEventListener("click",()=>{textInput.value="";update();textInput.focus();});update();}
const jsonInput=byId("json-input");
if(jsonInput){const output=byId("json-output");byId("format-json").addEventListener("click",()=>{try{const result=JSON.stringify(JSON.parse(jsonInput.value),null,2);output.textContent=result;setStatus("json-status","Корректный JSON. Форматирование готово.");}catch(error){output.textContent="";setStatus("json-status","Ошибка JSON: "+error.message,true);}});byId("copy-json").addEventListener("click",async()=>{if(!output.textContent){setStatus("json-status","Сначала проверьте JSON.",true);return;}try{await navigator.clipboard.writeText(output.textContent);setStatus("json-status","Результат скопирован.");}catch{setStatus("json-status","Копирование недоступно в этом браузере.",true);}});}
function parseCsv(source){const rows=[];let row=[],cell="",quoted=false,closed=false;for(let i=0;i<source.length;i++){const c=source[i];if(quoted){if(c==='"'&&source[i+1]==='"'){cell+='"';i++;}else if(c==='"'){quoted=false;closed=true;}else{cell+=c;}}else if(c==='"'){if(cell||closed)throw Error("Кавычка внутри поля");quoted=true;}else if(c===","){row.push(cell);cell="";closed=false;}else if(c==="\n"||c==="\r"){if(c==="\r"&&source[i+1]==="\n")i++;row.push(cell);rows.push(row);row=[];cell="";closed=false;}else{if(closed&&c!==" ")throw Error("Текст после закрывающей кавычки");cell+=c;}}if(quoted)throw Error("Не закрыта кавычка");if(cell||row.length||closed){row.push(cell);rows.push(row);}return rows;}
const csvInput=byId("csv-input");
if(csvInput){byId("show-csv").addEventListener("click",()=>{const area=byId("csv-table");area.replaceChildren();try{const rows=parseCsv(csvInput.value);if(!rows.length)throw Error("Вставьте CSV-таблицу");if(rows.length>201||rows.some(row=>row.length>30))throw Error("Для просмотра доступны первые 200 строк и до 30 столбцов");const width=rows[0].length;if(rows.some(row=>row.length!==width))throw Error("В строках разное число столбцов");const table=document.createElement("table");table.className="data-table";for(let i=0;i<rows.length;i++){const tr=document.createElement("tr");for(const cell of rows[i]){const el=document.createElement(i===0?"th":"td");el.textContent=cell;tr.append(el);}table.append(tr);}area.append(table);setStatus("csv-status","Показано строк данных: "+Math.max(0,rows.length-1)+".");}catch(error){setStatus("csv-status","Не удалось прочитать CSV: "+error.message,true);}});}
const hashInput=byId("hash-input");
if(hashInput){byId("hash-button").addEventListener("click",async()=>{const file=hashInput.files&&hashInput.files[0];if(!file){setStatus("hash-status","Выберите файл.",true);return;}if(file.size>50*1024*1024){setStatus("hash-status","Выберите файл до 50 МБ.",true);return;}try{const digest=await crypto.subtle.digest("SHA-256",await file.arrayBuffer());const value=Array.from(new Uint8Array(digest),x=>x.toString(16).padStart(2,"0")).join("");byId("hash-result").textContent=value;setStatus("hash-status","Готово: "+file.name+" · "+file.size+" байт.");}catch{setStatus("hash-status","Не удалось вычислить SHA-256 в этом браузере.",true);}});}
'''
(root / "assets/site.js").write_text(js.strip()+"\n")

def page(path,title,description,body,active=""):
    nav=lambda key: ' aria-current="page"' if key==active else ""
    shell=f'''<a class="skip" href="#main">К содержимому</a><div class="site"><header class="topbar"><a class="brand" href="/">форматы<i>.</i></a><nav class="nav" aria-label="Основная навигация"><a href="/tools/"{nav("tools")}>Инструменты</a><a href="/formats/"{nav("formats")}>Форматы</a><a href="/guides/"{nav("guides")}>Статьи</a><a href="/about/"{nav("about")}>О проекте</a></nav></header><main id="main">{body}</main><footer class="footer"><span>Форматы · Справочник и инструменты для работы с файлами</span><div class="footer-links"><a href="/privacy/">Конфиденциальность</a><a href="/about/">О проекте</a><span>{escape(domain)}</span></div></footer></div>'''
    html=f'''<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="theme-color" content="{background}"><meta name="description" content="{escape(description,quote=True)}"><link rel="icon" href="/assets/favicon.svg" type="image/svg+xml"><link rel="manifest" href="/site.webmanifest"><link rel="stylesheet" href="/assets/site.css"><title>{escape(title)} — Форматы</title></head><body>{shell}<script defer src="/assets/site.js"></script></body></html>'''
    target=root/path
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text(html+"\n")

def intro(section,title,summary):
    return f'<div class="intro"><div class="crumbs"><a href="/">Главная</a> / {escape(section)}</div><span class="eyebrow">{escape(section)}</span><h1>{escape(title)}</h1><p>{escape(summary)}</p></div>'

tools=[
    ("text","Счётчик текста","Посчитать знаки, слова, строки и размер текста в UTF-8."),
    ("json","Проверка JSON","Найти ошибку и привести данные к читаемому виду."),
    ("csv","Просмотр CSV","Разобрать таблицу с учётом кавычек и переносов строк."),
    ("sha256","SHA-256 файла","Получить контрольную сумму прямо в браузере."),
]
formats=[
    ("json","JSON","Структурированные данные и настройки."),
    ("csv","CSV","Таблицы в обычном текстовом файле."),
    ("markdown","Markdown","Разметка для заметок и документации."),
    ("pdf","PDF","Документы с сохраняемой вёрсткой."),
    ("txt","TXT","Простой текст без оформления."),
    ("zip","ZIP","Архив из нескольких файлов."),
]
guides=[
    ("choose-format","Как выбрать формат для задачи","Таблица, документ, заметка или обмен данными: с чего начать."),
    ("encoding","Почему текст открывается кракозябрами","Кодировки, UTF-8 и что проверить перед сохранением."),
    ("csv-rules","CSV без сломанных столбцов","Разделители, кавычки и переносы строк в таблицах."),
    ("verify-file","Как проверить файл по SHA-256","Когда полезна контрольная сумма и как сравнить два результата."),
    ("safe-sharing","Подготовка файла к отправке","Имя, формат, размер и личные данные перед отправкой."),
]
tool_cards=''.join(f'<a class="card" href="/tools/{slug}/"><small>ИНСТРУМЕНТ / 0{i}</small><h3>{title}</h3><p>{desc}</p><span>Открыть →</span></a>' for i,(slug,title,desc) in enumerate(tools,1))
format_links=''.join(f'<a href="/formats/{slug}/"><strong>.{slug}</strong><span>{desc}</span></a>' for slug,title,desc in formats)
sample='''<div class="sample"><div class="sample-top"><span>пример / данные.json</span><span class="sample-dots"><i></i><i></i><i></i></span></div><pre>{
  "проект": "каталог",
  "файлы": [
    "описание.md",
    "таблица.csv"
  ],
  "версия": 2
}</pre><div class="sample-foot">Текст, таблицы и документы — у каждого файла своя задача.</div></div>'''
home=f'''<section class="hero"><div><span class="eyebrow">Справочник по цифровым файлам</span><h1>{headlines[variant]}</h1><p>Короткие объяснения форматов, рабочие инструменты и инструкции для повседневных задач. Всё можно открыть без регистрации.</p><div class="actions"><a class="btn" href="/tools/">Выбрать инструмент</a><a class="btn alt" href="/formats/">Изучить форматы</a></div></div>{sample}</section><section class="section"><div class="section-head"><div><span class="eyebrow">Практика</span><h2>Сначала решите задачу.</h2></div><p>Проверка данных и расчёты выполняются в браузере, без загрузки содержимого на наш сервер.</p></div><div class="cards">{tool_cards}</div></section><section class="section"><div class="section-head"><div><span class="eyebrow">Справочник</span><h2>Какой формат перед вами?</h2></div><p>Расширение помогает понять, чем открыть файл и какие свойства важно сохранить.</p></div><div class="links">{format_links}</div></section><section class="section"><div class="band"><div><span class="eyebrow" style="color:#d4e3dd">Начните с основ</span><h2>Формат подбирают под задачу.</h2><p>Посмотрите сравнение распространённых вариантов и выберите подходящий.</p></div><a class="btn" href="/guides/choose-format/">Читать статью</a></div><p style="margin-top:21px"><a href="/formats/{featured}/">Подробнее о .{featured} →</a></p></section>'''
page("index.html","Файлы и форматы без лишней сложности","Справочник по форматам файлов и браузерные инструменты для текста, JSON, CSV и SHA-256.",home)
page("tools/index.html","Инструменты для файлов","Браузерные инструменты для текста, JSON, CSV и проверки SHA-256.",intro("Инструменты","Полезное для работы с файлами","Четыре инструмента для типичных задач. Введённый текст и выбранные файлы обрабатываются на вашем устройстве.")+f'<div class="cards" style="padding-bottom:75px">{tool_cards}</div>',"tools")
page("tools/text/index.html","Счётчик текста","Подсчёт слов, символов, строк и байтов UTF-8 в браузере.",intro("Инструменты","Счётчик текста","Вставьте текст и сразу увидите количество знаков, слов, строк и байтов в кодировке UTF-8.")+'''<section class="tool-layout"><div class="panel"><label for="text-input">Ваш текст</label><textarea id="text-input" placeholder="Напишите или вставьте текст"></textarea><div class="actions"><button class="btn alt" id="clear-text" type="button">Очистить</button></div></div><div class="panel"><h3>Результат</h3><div class="stat-grid"><div class="stat"><strong id="chars">0</strong><span>знаков</span></div><div class="stat"><strong id="words">0</strong><span>слов</span></div><div class="stat"><strong id="lines">0</strong><span>строк</span></div><div class="stat"><strong id="bytes">0</strong><span>байтов UTF-8</span></div></div><p class="feedback">Перенос строки считается частью текста.</p></div></section>''',"tools")
page("tools/json/index.html","Проверка и форматирование JSON","Проверьте синтаксис JSON и приведите данные к читаемому виду.",intro("Инструменты","Проверка JSON","Вставьте JSON: инструмент найдёт синтаксическую ошибку или выровняет отступы для чтения.")+'''<section class="tool-layout"><div class="panel"><label for="json-input">Исходные данные</label><textarea id="json-input" spellcheck="false" placeholder='{"название":"пример","версия":2}'></textarea><div class="actions"><button class="btn" id="format-json" type="button">Проверить и оформить</button><button class="btn alt" id="copy-json" type="button">Копировать результат</button></div><p class="feedback" id="json-status" role="status" aria-live="polite"></p></div><div class="panel"><h3>Результат</h3><pre class="output" id="json-output"></pre><p class="feedback">JSON поддерживает строки, числа, массивы, объекты и логические значения.</p></div></section>''',"tools")
page("tools/csv/index.html","Просмотр CSV","Посмотрите содержимое CSV-таблицы с кавычками и переносами строк.",intro("Инструменты","Просмотр CSV","Вставьте CSV с разделителем-запятой. Поля в кавычках, запятые внутри ячеек и переносы строк будут разобраны как таблица.")+'''<section class="tool-layout"><div class="panel"><label for="csv-input">Содержимое CSV</label><textarea id="csv-input" spellcheck="false" placeholder="имя,количество&#10;Книга,3&#10;Блокнот,5"></textarea><div class="actions"><button class="btn" id="show-csv" type="button">Показать таблицу</button></div><p class="feedback" id="csv-status" role="status" aria-live="polite"></p></div><div class="panel"><h3>Таблица</h3><div class="table-scroll" id="csv-table"><p class="feedback">Результат появится после разбора CSV.</p></div></div></section>''',"tools")
page("tools/sha256/index.html","SHA-256 файла","Вычислите контрольную сумму файла прямо в браузере.",intro("Инструменты","SHA-256 файла","Выберите файл до 50 МБ. Браузер прочитает его локально и покажет контрольную сумму.")+'''<section class="tool-layout"><div class="panel"><label for="hash-input">Файл для проверки</label><input id="hash-input" type="file"><div class="actions"><button class="btn" id="hash-button" type="button">Вычислить SHA-256</button></div><p class="feedback" id="hash-status" role="status" aria-live="polite"></p></div><div class="panel"><h3>Контрольная сумма</h3><pre class="output" id="hash-result">Результат появится здесь.</pre><p class="feedback">Сравнивайте всю строку целиком с суммой из надёжного источника.</p></div></section>''',"tools")
page("formats/index.html","Справочник форматов","Что хранят JSON, CSV, Markdown, PDF, TXT и ZIP и когда их использовать.",intro("Форматы","Шесть распространённых форматов","Откройте описание формата, чтобы понять его назначение, ограничения и подходящий инструмент.")+f'<div class="links" style="padding-bottom:75px">{format_links}</div>',"formats")
format_details={
"json":("Данные в виде объектов и списков","JSON удобен для передачи структурированных данных между программами. Он хранит текст, числа, логические значения, массивы и объекты.","Текстовый формат","Настройки, API, обмен данными","Проверка JSON",'''<h2>Как устроен JSON</h2><p>Объект заключают в фигурные скобки, массив — в квадратные. Названия полей и строки пишут в двойных кавычках. Комментарии и завершающие запятые в обычном JSON недопустимы.</p><h2>Когда подходит</h2><p>Используйте JSON, когда важно сохранить вложенную структуру: например, у записи есть автор, список тегов и параметры. Для простой таблицы CSV может быть удобнее.</p><aside><p>Если файл не открывается, сначала проверьте кавычки, запятые и кодировку UTF-8.</p></aside>''',"/tools/json/"),
"csv":("Строки и столбцы в текстовом файле","CSV хранит табличные данные. Обычно первая строка содержит названия столбцов, а остальные — значения.","Текстовый формат","Экспорт таблиц, обмен списками","Просмотр CSV",'''<h2>Почему таблица может сдвинуться</h2><p>Запятая отделяет поля. Если сама ячейка содержит запятую или перенос строки, её заключают в двойные кавычки. Кавычку внутри ячейки записывают дважды.</p><h2>Что проверить при импорте</h2><p>Уточните разделитель и кодировку. Некоторые программы сохраняют CSV с точкой с запятой вместо запятой. Наш просмотрщик рассчитан на разделитель-запятую.</p><aside><p>CSV не хранит формулы, оформление и несколько листов книги.</p></aside>''',"/tools/csv/"),
"markdown":("Заметки с простой разметкой","Markdown — обычный текст с короткими знаками для заголовков, списков, ссылок и выделений.","Текстовый формат","Документация, README, заметки","Счётчик текста",'''<h2>Чем удобен Markdown</h2><p>Файл можно читать даже без специального редактора. Знак решётки перед строкой обозначает заголовок, звёздочки часто используют для выделения, а дефис — для пункта списка.</p><h2>Где возможны различия</h2><p>Программы поддерживают разные расширения Markdown. Таблицы, примечания и дополнительные элементы могут выглядеть по-разному в разных редакторах.</p><aside><p>Если важен одинаковый вид документа на каждом устройстве, подготовьте PDF.</p></aside>''',"/tools/text/"),
"pdf":("Документ с предсказуемым видом","PDF предназначен для передачи готового документа с сохранением расположения текста и изображений.","Документ","Инструкции, договоры, печать","SHA-256 файла",'''<h2>Когда подходит PDF</h2><p>Используйте PDF, когда получатель должен видеть документ примерно в том же виде, что и вы. Для совместного редактирования исходный текстовый файл часто удобнее.</p><h2>Перед отправкой</h2><p>Проверьте читаемость на телефоне, размер файла и наличие лишних страниц. Скан в PDF может выглядеть как текст, но при этом содержать только изображения страниц.</p><aside><p>Не считайте PDF автоматически безопасным: открывайте вложения из неизвестных источников осторожно.</p></aside>''',"/tools/sha256/"),
"txt":("Простой текст без оформления","TXT содержит текстовые символы без шрифтов, таблиц и сложной вёрстки.","Текстовый формат","Заметки, журналы, инструкции","Счётчик текста",'''<h2>Преимущество простого текста</h2><p>TXT открывается почти везде и легко переносится между программами. Формат подходит для заметок, логов и коротких инструкций, где оформление не важно.</p><h2>Важна кодировка</h2><p>Расширение .txt не говорит, в какой кодировке записан файл. Если вместо букв видны неправильные символы, попробуйте открыть его как UTF-8 или уточнить исходную кодировку.</p><aside><p>Для структурированных данных лучше выбрать JSON или CSV.</p></aside>''',"/tools/text/"),
"zip":("Несколько файлов в одном архиве","ZIP объединяет файлы и папки в один архив; при подходящих данных он также уменьшает размер.","Архив","Передача наборов файлов, резервные копии","SHA-256 файла",'''<h2>Что делает архив</h2><p>ZIP хранит имена файлов и структуру папок. Он удобен, когда нужно отправить несколько элементов одним вложением или сохранить структуру каталога.</p><h2>Чего ZIP не гарантирует</h2><p>Сжатие может почти не уменьшить фотографии, видео и уже сжатые документы. Архив сам по себе не подтверждает происхождение файлов и не заменяет резервную копию в другом месте.</p><aside><p>После загрузки архива можно сравнить его SHA-256 с опубликованной контрольной суммой.</p></aside>''',"/tools/sha256/"),
}
for slug,title,desc in formats:
    subtitle,summary,kind,use,tool,article,link=format_details[slug]
    body=intro("Форматы",title,summary)+f'''<div class="format-facts"><div><strong>Тип</strong><span>{kind}</span></div><div><strong>Обычно используют</strong><span>{use}</span></div><div><strong>Связанный инструмент</strong><span><a href="{link}">{tool}</a></span></div></div><article class="prose">{article}<p><a href="/formats/">← Все форматы</a></p></article>'''
    page(f"formats/{slug}/index.html",f"Формат {title}",summary,body,"formats")
guide_links=''.join(f'<a href="/guides/{slug}/"><strong>{title}</strong><span>{summary}</span></a>' for slug,title,summary in guides)
page("guides/index.html","Статьи о файлах","Практические объяснения о форматах, кодировках, CSV, SHA-256 и отправке файлов.",intro("Статьи","Пять коротких объяснений","Разберитесь с форматом и подготовьте файл к открытию, передаче или проверке.")+f'<div class="links" style="padding-bottom:75px">{guide_links}</div>',"guides")
guide_articles={
"choose-format":'''<h2>Данные или готовый документ?</h2><p>Для списка строк и столбцов подойдёт CSV. Для вложенных данных, которыми обмениваются программы, удобнее JSON. Если важен внешний вид готового документа, используйте PDF.</p><h2>Нужно будет редактировать?</h2><p>Простой текст и Markdown сохраняют содержимое доступным для большинства редакторов. PDF удобен для чтения и печати, но править исходный материал в нём обычно сложнее.</p><h2>Нужно передать несколько файлов?</h2><p>ZIP соберёт их в один архив и сохранит папки. После создания проверьте, что внутри нет лишних файлов и личных данных.</p><aside><p>Расширение помогает выбрать программу, но окончательно назначение файла определяет его содержимое.</p></aside>''',
"encoding":'''<h2>Что такое кодировка</h2><p>Кодировка связывает символы с байтами файла. Если программа читает файл не в той кодировке, вместо привычных букв могут появиться неправильные символы.</p><h2>С чего начать</h2><p>Проверьте, в какой кодировке файл был сохранён, и попробуйте открыть его как UTF-8. Не сохраняйте повреждённый вид поверх исходного файла, пока не убедитесь, что текст отображается правильно.</p><h2>При обмене файлами</h2><p>Для новых текстовых файлов часто подходит UTF-8. Если система-получатель ожидает другую кодировку, укажите её при экспорте и сообщите получателю.</p><aside><p>Смена расширения .txt на .csv не меняет кодировку и не исправляет содержимое.</p></aside>''',
"csv-rules":'''<h2>Одна строка — одна запись</h2><p>Чаще всего первая строка CSV содержит заголовки столбцов. Следующие строки содержат значения в том же порядке. Разное число столбцов обычно означает ошибку в данных или неверный разделитель.</p><h2>Кавычки защищают ячейку</h2><p>Если значение содержит запятую, перенос строки или кавычку, заключите поле в двойные кавычки. Внутреннюю двойную кавычку повторите дважды.</p><h2>Разделитель может отличаться</h2><p>Не все программы используют запятую: некоторые экспортируют таблицы с точкой с запятой. Перед импортом проверьте настройки экспорта и выбранный разделитель.</p><aside><p>Просмотрщик на этом сайте принимает CSV с запятой в качестве разделителя.</p></aside>''',
"verify-file":'''<h2>Что показывает SHA-256</h2><p>SHA-256 превращает содержимое файла в строку фиксированной длины. Даже небольшое изменение обычно приводит к другой строке. Поэтому сумму удобно использовать для проверки целостности загрузки.</p><h2>Как сравнивать</h2><p>Получите контрольную сумму файла и сравните её целиком с суммой, опубликованной надёжным источником. Совпадение подтверждает, что у вас те же байты, но не доказывает добросовестность самого источника.</p><h2>Если суммы не совпали</h2><p>Сначала проверьте, что сравниваете один и тот же файл и алгоритм SHA-256. Затем скачайте файл заново из исходного источника.</p><aside><p>Наш инструмент вычисляет сумму в браузере и не отправляет выбранный файл на сервер.</p></aside>''',
"safe-sharing":'''<h2>Проверьте имя и расширение</h2><p>Название должно объяснять содержимое без необходимости открывать файл. Убедитесь, что расширение соответствует формату, в котором он действительно сохранён.</p><h2>Посмотрите внутрь</h2><p>Перед отправкой проверьте лишние страницы, скрытые столбцы, комментарии и личные данные. Если отправляете ZIP, откройте архив и проверьте список вложений.</p><h2>Учитывайте получателя</h2><p>Для просмотра готового документа часто подходит PDF. Для редактирования может потребоваться исходный файл. Уточните, сможет ли получатель открыть выбранный формат.</p><aside><p>Если файл важный, сохраните исходную копию перед изменением или конвертацией.</p></aside>'''
}
for slug,title,summary in guides:
    body=intro("Статьи",title,summary)+f'<article class="prose">{guide_articles[slug]}<p><a href="/guides/">← Все статьи</a></p></article>'
    page(f"guides/{slug}/index.html",title,summary,body,"guides")
page("about/index.html","О проекте","Зачем существует сайт «Форматы» и как работают его инструменты.",intro("О проекте","Понятная справка вместо догадок","«Форматы» — небольшой справочник и набор инструментов для повседневной работы с цифровыми файлами.")+'''<article class="prose"><h2>Для чего он нужен</h2><p>Сайт помогает разобраться, что хранит распространённый формат, чем открыть файл и как проверить данные перед отправкой. Статьи написаны для обычных задач, без необходимости изучать спецификации целиком.</p><h2>Как работают инструменты</h2><p>Подсчёт текста, разбор JSON и CSV и вычисление SHA-256 выполняются в вашем браузере. Сайт не требует аккаунта. Для важных файлов сохраняйте исходную копию и сверяйте результат с надёжным источником.</p><p><a href="/tools/">Перейти к инструментам →</a></p></article>''',"about")
page("privacy/index.html","Конфиденциальность","Как сайт «Форматы» обрабатывает введённые данные и файлы.",intro("Конфиденциальность","Ваши файлы остаются у вас","Инструменты выполняют вычисления на устройстве, с которого вы открыли сайт.")+'''<article class="prose"><h2>Введённые данные</h2><p>Текст, JSON и CSV обрабатываются JavaScript-кодом в браузере. При вычислении SHA-256 выбранный файл читается браузером локально. Содержимое не передаётся в приложение на сервере.</p><h2>Доставка страниц</h2><p>Веб-сервер может записывать технические сведения о запросе, например IP-адрес и путь страницы. Срок хранения таких журналов зависит от настройки сервера.</p><h2>Сторонние ресурсы</h2><p>Шрифты, стили и скрипты загружаются с этого же домена. В этих страницах нет встроенной сторонней аналитики или рекламы.</p></article>''')
page("404.html","Страница не найдена","Запрошенная страница справочника не найдена.",intro("404","Такой страницы нет","Проверьте адрес или вернитесь к справочнику.")+'<div class="actions" style="padding-bottom:80px"><a class="btn" href="/">На главную</a><a class="btn alt" href="/formats/">Открыть форматы</a></div>')
(root/"assets/favicon.svg").write_text(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="{ink}"/><path d="M19 16h19l8 8v24H19z" fill="none" stroke="{background}" stroke-width="4" stroke-linejoin="round"/><path d="M38 16v10h8M25 35h14M25 42h11" fill="none" stroke="{accent}" stroke-width="4" stroke-linecap="round"/></svg>\n')
(root/"robots.txt").write_text("User-agent: *\nAllow: /\nSitemap: https://"+domain+"/sitemap.xml\n")
paths=["/","/tools/"]+["/tools/"+s+"/" for s,_,_ in tools]+["/formats/"]+["/formats/"+s+"/" for s,_,_ in formats]+["/guides/"]+["/guides/"+s+"/" for s,_,_ in guides]+["/about/","/privacy/"]
(root/"sitemap.xml").write_text('<?xml version="1.0" encoding="utf-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'+''.join('<url><loc>https://'+domain+p+'</loc></url>' for p in paths)+'</urlset>\n')
(root/"site.webmanifest").write_text(json.dumps({"name":"Форматы","short_name":"Форматы","start_url":"/","display":"browser","background_color":background,"theme_color":background,"icons":[{"src":"/assets/favicon.svg","sizes":"any","type":"image/svg+xml"}]},ensure_ascii=False)+"\n")
print(f"Форматы: создано {len(list(root.rglob('*.html')))} страниц для {domain}")
PY
  )
}

write_theme_site() {
  (umask 022; SITE_DIR="$1" SITE_DOMAIN="$SITE_DOMAIN" SITE_THEME="$SITE_THEME" NODE_IPV4="$NODE_IPV4" NODE_IPV6="$NODE_IPV6" python3 - <<'PY'
from pathlib import Path
from html import escape
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
import random
import urllib.request

root = Path(os.environ["SITE_DIR"])
domain = os.environ["SITE_DOMAIN"]
theme = os.environ["SITE_THEME"]
node_ipv4 = os.environ.get("NODE_IPV4", "")
node_ipv6 = os.environ.get("NODE_IPV6", "")

seed = int(hashlib.sha256(domain.encode()).hexdigest()[:12], 16)
rng = random.Random(seed)
now = datetime.now(timezone.utc).replace(microsecond=0)
root.mkdir(parents=True, exist_ok=True)

MB = 1024 * 1024
GB = 1024 * MB

cities = {
    "de": ("Frankfurt am Main", "Germany", "FRA", ["DE-CIX Frankfurt", "KleyReX"], "50.11°N 8.68°E"),
    "nl": ("Amsterdam", "Netherlands", "AMS", ["AMS-IX", "NL-ix"], "52.37°N 4.90°E"),
    "fi": ("Helsinki", "Finland", "HEL", ["FICIX", "Equinix Helsinki"], "60.17°N 24.94°E"),
    "pl": ("Warsaw", "Poland", "WAW", ["PLIX", "EPIX Warszawa"], "52.23°N 21.01°E"),
    "se": ("Stockholm", "Sweden", "STO", ["Netnod Stockholm", "STHIX"], "59.33°N 18.07°E"),
    "ee": ("Tallinn", "Estonia", "TLL", ["TLLIX", "RixIX"], "59.44°N 24.75°E"),
    "lv": ("Riga", "Latvia", "RIX", ["LIX", "SMILE-LV"], "56.95°N 24.11°E"),
    "lt": ("Vilnius", "Lithuania", "VNO", ["LIXP", "BALT-IX"], "54.69°N 25.28°E"),
    "us": ("New York", "United States", "NYC", ["NYIIX", "DE-CIX New York"], "40.71°N 74.01°W"),
    "gb": ("London", "United Kingdom", "LON", ["LINX LON1", "LONAP"], "51.51°N 0.13°W"),
    "uk": ("London", "United Kingdom", "LON", ["LINX LON1", "LONAP"], "51.51°N 0.13°W"),
    "fr": ("Paris", "France", "PAR", ["France-IX Paris", "Equinix Paris"], "48.86°N 2.35°E"),
    "at": ("Vienna", "Austria", "VIE", ["VIX", "DE-CIX Vienna"], "48.21°N 16.37°E"),
    "ch": ("Zurich", "Switzerland", "ZRH", ["SwissIX", "CHIX-CH"], "47.37°N 8.54°E"),
    "cz": ("Prague", "Czechia", "PRG", ["NIX.CZ", "Peering.cz"], "50.08°N 14.44°E"),
    "tr": ("Istanbul", "Turkey", "IST", ["DE-CIX Istanbul", "IST-IX"], "41.01°N 28.98°E"),
    "kz": ("Almaty", "Kazakhstan", "ALA", ["KazNIX", "IX.KZ"], "43.24°N 76.89°E"),
    "hk": ("Hong Kong", "Hong Kong", "HKG", ["HKIX", "Equinix Hong Kong"], "22.32°N 114.17°E"),
    "jp": ("Tokyo", "Japan", "TYO", ["JPIX Tokyo", "BBIX Tokyo"], "35.68°N 139.69°E"),
    "sg": ("Singapore", "Singapore", "SIN", ["SGIX", "Equinix Singapore"], "1.35°N 103.82°E"),
    "ru": ("Moscow", "Russia", "MOW", ["MSK-IX", "DATAIX"], "55.75°N 37.62°E"),
}
prefix = "".join(ch for ch in domain.split(".")[0] if ch.isalpha())[:2]
city, country, iata, exchanges, coords = cities.get(prefix, cities["de"])


def coord_text(lat, lon):
    return f"{abs(lat):.2f}°{'N' if lat >= 0 else 'S'} {abs(lon):.2f}°{'E' if lon >= 0 else 'W'}"


def real_geo(ip):
    if not ip:
        return None
    try:
        with urllib.request.urlopen(f"http://ip-api.com/json/{ip}?fields=status,country,countryCode,city,lat,lon", timeout=8) as response:
            data = json.load(response)
        if data.get("status") == "success" and data.get("city"):
            return data["city"], data["country"], data["countryCode"].lower(), float(data["lat"]), float(data["lon"])
    except Exception:
        pass
    try:
        with urllib.request.urlopen(f"https://ipinfo.io/{ip}/json", timeout=8) as response:
            data = json.load(response)
        lat, lon = (float(x) for x in data["loc"].split(","))
        code = data["country"].lower()
        return data["city"], cities.get(code, (None, data["country"]))[1], code, lat, lon
    except Exception:
        return None


airports = {"nuremberg": "NUE", "falkenstein": "FSN", "gravelines": "GRV", "roubaix": "RBX", "strasbourg": "SXB", "dronten": "DRO", "meppel": "MEP", "naaldwijk": "NLD",
            "düsseldorf": "DUS", "berlin": "BER", "munich": "MUC", "hamburg": "HAM", "limburg": "LIM", "espoo": "ESP", "kerava": "KER", "tuusula": "TUU",
            "riga": "RIX", "moscow": "MOW", "saint petersburg": "LED", "st petersburg": "LED", "new york": "NYC", "london": "LON", "tallinn": "TLL", "vilnius": "VNO", "stockholm": "STO", "warsaw": "WAW", "amsterdam": "AMS", "helsinki": "HEL", "frankfurt am main": "FRA"}
geo = None if os.environ.get("SITE_GEO") == "off" else real_geo(node_ipv4)
if geo:
    g_city, g_country, g_code, g_lat, g_lon = geo
    known = cities.get(g_code)
    exchanges = known[3] if known else []
    iata = airports.get(g_city.lower(), (known[2] if known and known[0] == g_city else "".join(c for c in g_city.upper() if c.isalpha())[:3]))
    city, country, coords = g_city, g_country, coord_text(g_lat, g_lon)
site_no = rng.randint(1, 4)
providers = ["Hallberg Networks", "Ostkreuz Hosting", "Lindqvist Datacenter", "Morava Net", "Saltmarsh Hosting", "Brenner IT"]
provider = rng.choice(providers)

pop = f"{iata}{site_no}"

LATIN = "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
CYRILLIC = "U+0301,U+0400-045F,U+0490-0491,U+04B0-04B1,U+2116"


def write(path, text):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)


def fonts(faces):
    css = ""
    for family, font_id, weight, style, subsets in faces:
        for subset in subsets:
            name = f"{font_id}-{subset}-{weight}-{style}.woff2"
            target = root / "assets" / "fonts" / name
            if not target.exists():
                url = f"https://cdn.jsdelivr.net/fontsource/fonts/{font_id}@latest/{subset}-{weight}-{style}.woff2"
                try:
                    with urllib.request.urlopen(url, timeout=15) as response:
                        data = response.read()
                    if len(data) < 2000 or data[:4] != b"wOF2":
                        continue
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                except Exception:
                    continue
            css += (
                f"@font-face{{font-family:'{family}';font-style:{style};font-weight:{weight};font-display:swap;"
                f"src:url(/assets/fonts/{name}) format('woff2');unicode-range:{LATIN if subset == 'latin' else CYRILLIC}}}"
            )
    return css


def human(size, ru=False):
    for unit, step in ((("ГБ" if ru else "GB"), GB), (("МБ" if ru else "MB"), MB)):
        if size >= step:
            value = size / step
            text = f"{value:.1f} {unit}" if value < 10 else f"{value:.0f} {unit}"
            return text.replace(".", ",") if ru else text
    return f"{size // 1024} KB"


sparse_ok = None


def blob(path, size, when):
    global sparse_ok
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    with open(target, "wb") as handle:
        handle.truncate(size)
    if sparse_ok is None:
        sparse_ok = os.stat(target).st_blocks * 512 < 4 * MB
        if not sparse_ok:
            target.unlink()
            raise SystemExit(3)
    stamp = when.timestamp()
    os.utime(target, (stamp, stamp))
    return size


def sha(text):
    return hashlib.sha256((domain + text).encode()).hexdigest()


def page(path, title, css, body, lang="en", head=""):
    write(path, (
        f'<!doctype html><html lang="{lang}"><head><meta charset="utf-8">'
        f'<meta name="viewport" content="width=device-width, initial-scale=1">'
        f'<title>{escape(title)}</title><link rel="icon" href="/favicon.svg" type="image/svg+xml">'
        f'<style>{css}</style>{head}</head><body>{body}</body></html>\n'
    ))


def common_files(paths, hidden):
    write("robots.txt", "User-agent: *\n" + "".join(f"Disallow: {h}\n" for h in hidden))
    write("sitemap.xml", '<?xml version="1.0" encoding="utf-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + "".join(f"<url><loc>https://{domain}{p}</loc></url>" for p in paths) + "</urlset>\n")


SPEED_JS = r"""
(function(){
var el=function(id){return document.getElementById(id)};
var button=el('start'),phase=el('phase'),big=el('big'),unit=el('unit'),canvas=el('graph');
var DURATION=9000,samples=[];
function mbps(bytes,start){var s=(performance.now()-start)/1000;return s>0?bytes*8/s/1e6:0}
function fmt(v){return v>=100?v.toFixed(0):v>=10?v.toFixed(1):v.toFixed(2)}
function set(id,v){el(id).textContent=v==null?'—':fmt(v)}
function rand(n){var b=new Uint8Array(n);for(var i=0;i<n;i+=65536){crypto.getRandomValues(b.subarray(i,Math.min(i+65536,n)))}return b}
function draw(){
  var r=window.devicePixelRatio||1,w=canvas.clientWidth,h=canvas.clientHeight;
  if(canvas.width!==Math.round(w*r)){canvas.width=Math.round(w*r);canvas.height=Math.round(h*r)}
  var c=canvas.getContext('2d');c.setTransform(r,0,0,r,0,0);c.clearRect(0,0,w,h);
  var top=1;samples.forEach(function(s){top=Math.max(top,s.v)});top*=1.15;
  ['down','up'].forEach(function(kind){
    var pts=samples.filter(function(s){return s.k===kind});if(pts.length<2){return}
    c.beginPath();pts.forEach(function(s,i){var x=s.t/DURATION*w,y=h-s.v/top*(h-6)-3;if(i){c.lineTo(x,y)}else{c.moveTo(x,y)}});
    c.strokeStyle=kind==='down'?'#c4f236':'#f3a33a';c.lineWidth=2;c.stroke();
  });
}
function live(kind,v,t){big.textContent=fmt(v);samples.push({k:kind,v:v,t:t});draw()}
async function latency(){
  var t=[];
  for(var i=0;i<12;i++){var s=performance.now();await fetch('/speedtest/empty?n='+Math.random(),{cache:'no-store'});t.push(performance.now()-s);big.textContent=fmt(t[t.length-1])}
  t=t.slice(2);var j=0;for(var k=1;k<t.length;k++){j+=Math.abs(t[k]-t[k-1])}
  return {ping:Math.min.apply(null,t),jitter:j/(t.length-1)};
}
async function download(){
  var ctrl=new AbortController(),bytes=0,start=performance.now();
  var timer=setInterval(function(){live('down',mbps(bytes,start),performance.now()-start)},150);
  var one=async function(){
    while(performance.now()-start<DURATION){
      try{
        var r=await fetch('/speedtest/garbage.bin?n='+Math.random(),{cache:'no-store',signal:ctrl.signal});
        var reader=r.body.getReader();
        for(;;){var part=await reader.read();if(part.done){break}bytes+=part.value.length;if(performance.now()-start>=DURATION){ctrl.abort();break}}
      }catch(e){break}
    }
  };
  await Promise.all([one(),one(),one(),one()]);
  clearInterval(timer);
  return mbps(bytes,start);
}
function upload(){
  return new Promise(function(resolve){
    var body=new Blob([rand(8*1024*1024)]),sent=0,start=performance.now(),active=0,done=false,list=[];
    var timer=setInterval(function(){live('up',mbps(sent,start),performance.now()-start)},150);
    var finish=function(){if(done){return}done=true;clearInterval(timer);clearTimeout(stop);list.forEach(function(x){try{x.abort()}catch(e){}});resolve(mbps(sent,start))};
    var stop=setTimeout(finish,DURATION+600);
    var one=function(){
      if(done){return}
      if(performance.now()-start>=DURATION){if(active===0){finish()}return}
      var x=new XMLHttpRequest(),last=0;active++;list.push(x);
      x.upload.onprogress=function(e){sent+=e.loaded-last;last=e.loaded};
      x.onloadend=function(){active--;one()};
      x.open('POST','/speedtest/upload?n='+Math.random());x.send(body);
    };
    one();one();one();
  });
}
function history(add){
  var list=[];try{list=JSON.parse(localStorage.getItem('speedtest')||'[]')}catch(e){}
  if(add){list.unshift(add);list=list.slice(0,6);try{localStorage.setItem('speedtest',JSON.stringify(list))}catch(e){}}
  el('history').innerHTML=list.map(function(r){var d=new Date(r.at);return '<tr><td>'+d.toLocaleDateString()+' '+d.toLocaleTimeString().slice(0,5)+'</td><td class="d">'+fmt(r.down)+'</td><td class="u">'+fmt(r.up)+'</td><td>'+fmt(r.ping)+'</td></tr>'}).join('')||'<tr><td colspan="4">—</td></tr>';
}
async function run(){
  if(button.disabled){return}
  button.disabled=true;samples=[];draw();['ping','jitter','down','up'].forEach(function(id){set(id,null)});
  try{
    phase.textContent='latency';unit.textContent='ms';var l=await latency();set('ping',l.ping);set('jitter',l.jitter);
    phase.textContent='download';unit.textContent='Mbit/s';var d=await download();set('down',d);
    phase.textContent='upload';var u=await upload();set('up',u);
    phase.textContent='result';big.textContent=fmt(d);
    history({at:Date.now(),down:d,up:u,ping:l.ping});
  }catch(e){phase.textContent='stopped: '+e.message}
  button.disabled=false;button.firstChild.textContent='Run again ';
}
button.addEventListener('click',run);
document.addEventListener('keydown',function(e){if(e.code==='Space'&&document.activeElement===document.body){e.preventDefault();run()}});
window.addEventListener('resize',draw);
history();draw();
})();
"""


def mark_svg(color):
    return f'<svg width="22" height="22" viewBox="0 0 22 22" aria-hidden="true"><rect x="1" y="1" width="13" height="13" fill="{color}"/><rect x="8" y="8" width="13" height="13" fill="none" stroke="{color}" stroke-width="2"/></svg>'


def speedtest_page(path, nav_links, active):
    blob("speedtest/garbage.bin", 2 * GB, now - timedelta(days=rng.randint(30, 300)))
    face = fonts([("Chivo", "chivo", 400, "normal", ["latin"]), ("Chivo", "chivo", 700, "normal", ["latin"]), ("Chivo Mono", "chivo-mono", 500, "normal", ["latin"])])
    css = face + (
        ":root{--bg:#0b0d0a;--ink:#e8ede1;--dim:#7d8677;--line:#20251d;--down:#c4f236;--up:#f3a33a}"
        "*{box-sizing:border-box}html{background:var(--bg)}body{margin:0;min-height:100vh;color:var(--ink);font:15px/1.5 Chivo,'Helvetica Neue',Arial,sans-serif;"
        "background-image:linear-gradient(var(--line) 1px,transparent 1px),linear-gradient(90deg,var(--line) 1px,transparent 1px);background-size:40px 40px;background-position:-1px -1px}"
        "a{color:var(--ink)}.wrap{max-width:1080px;margin:auto;padding:0 28px}"
        "header{display:flex;align-items:center;gap:12px;height:68px;border-bottom:1px solid var(--line)}header b{font-weight:700;letter-spacing:.01em}header nav{margin-left:auto;display:flex;gap:22px}"
        "header nav a{color:var(--dim);text-decoration:none;font-size:14px}header nav a:hover,header nav a.on{color:var(--ink)}"
        ".stage{display:grid;grid-template-columns:1fr 300px;margin-top:44px;border:1px solid var(--line);background:rgba(11,13,10,.86)}"
        ".read{padding:30px 34px 0;border-right:1px solid var(--line);min-width:0}.phase{font:500 12px 'Chivo Mono',ui-monospace,monospace;letter-spacing:.18em;text-transform:uppercase;color:var(--dim)}"
        ".phase:before{content:'';display:inline-block;width:7px;height:7px;background:var(--down);margin-right:10px;vertical-align:1px}"
        ".big{font:500 clamp(70px,13vw,148px)/1 'Chivo Mono',ui-monospace,monospace;letter-spacing:-.04em;margin:18px 0 0;font-variant-numeric:tabular-nums}"
        ".unit{font:500 15px 'Chivo Mono',monospace;color:var(--dim);margin:6px 0 26px}canvas{display:block;width:100%;height:150px;border-top:1px solid var(--line)}"
        ".side{display:flex;flex-direction:column}.stat{padding:20px 24px;border-bottom:1px solid var(--line)}.stat span{font-size:12px;color:var(--dim);letter-spacing:.06em;text-transform:uppercase}"
        ".stat strong{display:block;font:500 30px/1.15 'Chivo Mono',monospace;margin-top:4px;font-variant-numeric:tabular-nums}.stat.d strong{color:var(--down)}.stat.u strong{color:var(--up)}"
        "button{margin-top:auto;border:0;background:var(--ink);color:#0b0d0a;font:700 16px Chivo,Arial,sans-serif;padding:22px 24px;text-align:left;cursor:pointer;display:flex;justify-content:space-between;align-items:center}"
        "button kbd{font:500 12px 'Chivo Mono',monospace;border:1px solid #0b0d0a55;padding:1px 6px}button:disabled{background:#3a4035;color:#9aa293;cursor:default}"
        ".meta{display:flex;flex-wrap:wrap;gap:28px;padding:18px 0 0;color:var(--dim);font-size:13px}.meta b{color:var(--ink);font-weight:400}"
        "h2{font-size:13px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:var(--dim);margin:52px 0 10px}"
        "table{width:100%;border-collapse:collapse;font:14px 'Chivo Mono',monospace}td,th{padding:9px 0;border-bottom:1px solid var(--line);text-align:left}th{color:var(--dim);font-weight:500}"
        "td.d{color:var(--down)}td.u{color:var(--up)}footer{padding:60px 0 34px;color:var(--dim);font-size:13px}"
        "@media(max-width:800px){.stage{grid-template-columns:1fr}.read{border-right:0}.side{display:grid;grid-template-columns:1fr 1fr}.side button{grid-column:1/-1}}"
    )
    links = "".join(f'<a href="{href}"{" class=on" if label == active else ""}>{label}</a>' for label, href in nav_links)
    body = (
        f'<div class="wrap"><header>{mark_svg("#e8ede1")}<b>{escape(provider)}</b><nav>{links}</nav></header>'
        '<div class="stage"><div class="read"><div class="phase" id="phase">ready</div><div class="big" id="big">0.00</div><div class="unit" id="unit">Mbit/s</div><canvas id="graph"></canvas></div>'
        '<div class="side"><div class="stat"><span>Ping</span><strong id="ping">—</strong></div><div class="stat"><span>Jitter</span><strong id="jitter">—</strong></div>'
        '<div class="stat d"><span>Download</span><strong id="down">—</strong></div><div class="stat u"><span>Upload</span><strong id="up">—</strong></div>'
        '<button id="start" type="button">Start test <kbd>space</kbd></button></div></div>'
        f'<div class="meta"><span>Server <b>{escape(city)} · {pop}</b></span><span>Uplink <b>{rng.choice(["10G", "2×10G", "25G"])}</b></span><span>Location <b>{coords}</b></span></div>'
        '<h2>This browser</h2><table><thead><tr><th>Time</th><th>Down</th><th>Up</th><th>Ping</th></tr></thead><tbody id="history"></tbody></table>'
        f'<footer>4 download and 3 upload streams, 9 s each. Results stay in this browser. © {now.year} {escape(provider)}</footer></div>'
        f"<script>{SPEED_JS}</script>"
    )
    page(path, f"Speed test · {provider} {pop}", css, body)


def build_speedtest():
    speedtest_page("index.html", [("Speed test", "/"), ("Test files", "/files/")], "Speed test")
    when = now - timedelta(days=rng.randint(90, 400))
    for name, size in [("100MB.test", 100 * MB), ("1GB.test", GB), ("10GB.test", 10 * GB)]:
        blob(f"files/{name}", size, when)
    page("404.html", "Not found", "body{background:#0b0d0a;color:#e8ede1;font:15px Arial,sans-serif;margin:48px}a{color:#c4f236}", '<p>404 — <a href="/">speed test</a></p>')
    write("favicon.svg", '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" fill="#0b0d0a"/><path d="M5 23 L12 15 L17 19 L27 8" fill="none" stroke="#c4f236" stroke-width="3"/></svg>\n')
    common_files(["/"], ["/files/", "/speedtest/"])


def build_lg():
    face = fonts([("IBM Plex Sans", "ibm-plex-sans", 400, "normal", ["latin"]), ("IBM Plex Sans", "ibm-plex-sans", 600, "normal", ["latin"]), ("IBM Plex Mono", "ibm-plex-mono", 400, "normal", ["latin"])])
    brand = rng.choice(["#0e5c5a", "#7a3b12", "#24407a", "#4b5b16"])
    uplink = rng.choice(["2 × 10 Gbit/s", "10 Gbit/s", "2 × 25 Gbit/s"])
    asn = rng.randint(197000, 214999)
    transit = rng.sample(["Cogent", "Arelion", "GTT", "Lumen", "NTT", "Telia Carrier", "Core-Backbone", "RETN"], 3)
    rack = f"{rng.randint(2, 9)}{rng.choice('ABCD')}.{rng.randint(10, 40)}"
    files = [("100MB.test", 100 * MB), ("1GB.test", GB), ("10GB.test", 10 * GB)]
    when = now - timedelta(days=rng.randint(90, 400))
    for name, size in files:
        blob(f"files/{name}", size, when)
    css = face + (
        f":root{{--paper:#f3f1ec;--ink:#1b1e22;--dim:#676b70;--line:#d9d5cb;--brand:{brand}}}"
        "*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.55 'IBM Plex Sans','Helvetica Neue',Arial,sans-serif}"
        "a{color:var(--brand)}.wrap{max-width:1040px;margin:auto;padding:0 28px}.mono{font-family:'IBM Plex Mono',Menlo,monospace}"
        "header{display:flex;align-items:center;gap:12px;padding:22px 0;border-bottom:2px solid var(--ink)}header b{font-weight:600;font-size:17px}"
        "header nav{margin-left:auto;display:flex;gap:24px;font-size:14px}header nav a{color:var(--ink);text-decoration:none}header nav a.on{border-bottom:2px solid var(--brand)}"
        ".hero{display:grid;grid-template-columns:auto 1fr;gap:40px;align-items:end;padding:56px 0 34px;border-bottom:1px solid var(--line)}"
        ".code{font:600 92px/0.9 'IBM Plex Mono',Menlo,monospace;letter-spacing:-.04em;color:var(--brand)}"
        ".hero h1{font-size:28px;font-weight:600;margin:0}.hero p{margin:6px 0 0;color:var(--dim)}"
        ".facts{display:grid;grid-template-columns:repeat(4,1fr);border-bottom:1px solid var(--line)}.facts div{padding:18px 18px 18px 0}.facts span{display:block;font-size:12px;color:var(--dim);text-transform:uppercase;letter-spacing:.08em}"
        ".facts strong{display:block;font:400 16px 'IBM Plex Mono',monospace;margin-top:4px}"
        ".cols{display:grid;grid-template-columns:1.1fr .9fr;gap:48px;padding:34px 0}h2{font-size:13px;text-transform:uppercase;letter-spacing:.1em;margin:0 0 12px}"
        "table{width:100%;border-collapse:collapse}td{padding:9px 0;border-bottom:1px solid var(--line)}td:last-child{text-align:right;color:var(--dim)}"
        ".files a{display:flex;justify-content:space-between;padding:12px 0;border-bottom:1px solid var(--line);text-decoration:none;color:var(--ink)}.files a:hover b{color:var(--brand)}.files em{font-style:normal;color:var(--dim)}"
        ".term{background:var(--ink);color:#d7dbd2;padding:22px 24px;margin:6px 0 40px}.term form{display:flex;gap:10px;flex-wrap:wrap}"
        ".term select,.term input,.term button{font:14px 'IBM Plex Mono',monospace;background:#2a2e33;color:#eef0ea;border:1px solid #3b4046;padding:9px 11px}.term input{flex:1;min-width:200px}"
        ".term button{background:var(--brand);border-color:var(--brand);cursor:pointer}.term pre{margin:16px 0 0;font:13px/1.6 'IBM Plex Mono',monospace;color:#aab1a6;white-space:pre-wrap}"
        "footer{border-top:1px solid var(--line);padding:22px 0 36px;font-size:13px;color:var(--dim);display:flex;justify-content:space-between;flex-wrap:wrap;gap:12px}"
        "@media(max-width:780px){.hero,.cols{grid-template-columns:1fr}.code{font-size:64px}.facts{grid-template-columns:1fr 1fr}}"
    )

    def header(on):
        return (f'<header>{mark_svg(brand)}<b>{escape(provider)}</b><nav>'
                f'<a href="/"{" class=on" if on == "lg" else ""}>Looking glass</a><a href="/speedtest/">Speed test</a></nav></header>')

    facts = [("Facility", f"{pop} / rack {rack}"), ("Uplink", uplink), ("ASN", f"AS{asn}"), ("Test IPv4", node_ipv4 or "—")]
    peering = "".join(f"<tr><td>{x}</td><td>peering</td></tr>" for x in exchanges) + "".join(f"<tr><td>{x}</td><td>transit</td></tr>" for x in transit)
    filelist = "".join(f'<a href="/files/{n}"><b>{n.replace(".test", "")} test file</b><em class="mono">{human(s)}</em></a>' for n, s in files)
    ipv6 = f'<p class="mono" style="color:var(--dim);font-size:13px">IPv6 {escape(node_ipv6)}</p>' if node_ipv6 else ""
    body = (
        f'<div class="wrap">{header("lg")}<section class="hero"><div class="code">{pop}</div><div><h1>{escape(city)}, {escape(country)}</h1><p class="mono">{coords}</p></div></section>'
        '<section class="facts">' + "".join(f"<div><span>{k}</span><strong>{escape(v)}</strong></div>" for k, v in facts) + "</section>"
        f'<section class="cols"><div><h2>Upstreams</h2><table>{peering}</table></div><div class="files"><h2>Test files</h2>{filelist}'
        f'<p style="color:var(--dim);font-size:13px;margin-top:14px">Same uplink as customer servers. <span class="mono">curl -o /dev/null https://{escape(domain)}/files/1GB.test</span></p>{ipv6}</div></section>'
        '<section class="term"><form id="lg"><select><option>ping</option><option>traceroute</option><option>mtr</option><option>show route</option></select>'
        '<input placeholder="destination" autocomplete="off"><button>run</button></form><pre id="out"></pre></section>'
        f'<footer><span>© {2013 + rng.randint(0, 8)}–{now.year} {escape(provider)}</span><span>NOC / abuse: noc@{escape(domain)}</span></footer></div>'
        "<script>document.getElementById('lg').addEventListener('submit',function(e){e.preventDefault();"
        "document.getElementById('out').textContent='% queries from unregistered networks are rate limited\\n% retry later or run the tool from your client area';});</script>"
    )
    page("index.html", f"{pop} looking glass — {provider}", css, body)
    speedtest_page("speedtest/index.html", [("Looking glass", "/"), ("Speed test", "/speedtest/")], "Speed test")
    page("404.html", "Not found", css, f'<div class="wrap">{header("")}<section class="hero"><div class="code">404</div><div><h1>Not found</h1><p><a href="/">Back to {pop}</a></p></div></section></div>')
    write("favicon.svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 22 22"><rect width="22" height="22" fill="#f3f1ec"/><rect x="1" y="1" width="13" height="13" fill="{brand}"/><rect x="8" y="8" width="13" height="13" fill="none" stroke="{brand}" stroke-width="2"/></svg>\n')
    common_files(["/", "/speedtest/"], ["/files/", "/speedtest/garbage.bin"])


def build_mirror():
    org = rng.choice(["nordhavn", "vestbro", "altstadt", "kalev", "saarland", "varde"])
    distros = [
        ("debian-cd", "Debian CD/DVD images", [("13.2.0/amd64/iso-cd/debian-13.2.0-amd64-netinst.iso", 754 * MB), ("13.2.0/amd64/iso-dvd/debian-13.2.0-amd64-DVD-1.iso", int(3.9 * GB)), ("13.2.0/arm64/iso-cd/debian-13.2.0-arm64-netinst.iso", 612 * MB)]),
        ("ubuntu-releases", "Ubuntu releases", [("26.04/ubuntu-26.04-live-server-amd64.iso", int(3.1 * GB)), ("26.04/ubuntu-26.04-desktop-amd64.iso", int(6.2 * GB)), ("24.04.3/ubuntu-24.04.3-live-server-amd64.iso", int(3.0 * GB))]),
        ("alpine", "Alpine Linux", [("v3.22/releases/x86_64/alpine-standard-3.22.2-x86_64.iso", 268 * MB), ("v3.22/releases/x86_64/alpine-virt-3.22.2-x86_64.iso", 66 * MB), ("v3.22/releases/aarch64/alpine-standard-3.22.2-aarch64.iso", 342 * MB)]),
        ("archlinux", "Arch Linux", [("iso/2026.11.01/archlinux-2026.11.01-x86_64.iso", 1288 * MB), ("iso/2026.10.01/archlinux-2026.10.01-x86_64.iso", 1271 * MB)]),
        ("rocky", "Rocky Linux", [("10.1/isos/x86_64/Rocky-10.1-x86_64-minimal.iso", int(1.9 * GB)), ("10.1/isos/x86_64/Rocky-10.1-x86_64-boot.iso", 1014 * MB)]),
        ("openwrt", "OpenWrt", [("releases/24.10.4/targets/x86/64/openwrt-24.10.4-x86-64-generic-ext4-combined-efi.img.gz", 13 * MB), ("releases/24.10.4/targets/ramips/mt7621/openwrt-24.10.4-ramips-mt7621-xiaomi_mi-router-4a-gigabit-squashfs-sysupgrade.bin", 7 * MB)]),
    ]
    lines = []
    total = 0
    for slug, title, files in distros:
        synced = now - timedelta(hours=rng.randint(1, 9), minutes=rng.randint(0, 59))
        folders = {}
        for rel, length in files:
            when = now - timedelta(days=rng.randint(3, 120), hours=rng.randint(0, 23))
            total += blob(f"pub/{slug}/{rel}", length, when)
            folder, name = rel.rsplit("/", 1)
            folders.setdefault(folder, []).append(name)
        for folder, names in folders.items():
            write(f"pub/{slug}/{folder}/SHA256SUMS", "".join(f"{sha(n)}  {n}\n" for n in names))
        lines.append(f'<tr><td><a href="/pub/{slug}/">{slug}/</a></td><td>{escape(title)}</td><td>{synced:%Y-%m-%d %H:%M}</td><td class="ok">ok</td></tr>')
    css = (
        "body{margin:0;background:#fffff8;color:#111;font:14px/1.55 'DejaVu Sans Mono',Menlo,Consolas,monospace}main{max-width:900px;margin:0 auto;padding:28px 20px 60px}"
        "pre.banner{margin:0 0 18px;color:#444;font-size:13px;line-height:1.3}a{color:#00e}a:visited{color:#551a8b}"
        "h2{font-size:14px;margin:30px 0 6px;text-transform:uppercase}table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:3px 18px 3px 0;white-space:nowrap}"
        "th{border-bottom:1px solid #999}.ok{color:#080}p{margin:0 0 10px;max-width:72ch}hr{border:0;border-top:1px dashed #999;margin:28px 0 10px}small{color:#666}"
        "@media(max-width:640px){td:nth-child(2){display:none}}"
    )
    banner = f"{org}-mirror :: {domain}\n{city}, {country}  ·  {len(distros)} projects  ·  {human(total)} on local disk"
    body = (
        f'<main><pre class="banner">{escape(banner)}</pre>'
        f"<p>Public mirror of free software release media, run by members of the {escape(org.capitalize())} hackerspace. Synced from upstream every 6 hours.</p>"
        f'<h2>Projects</h2><table><tr><th>path</th><th>project</th><th>last sync (UTC)</th><th>state</th></tr>{"".join(lines)}</table>'
        "<h2>Notes</h2><p>Everything is under <a href=\"/pub/\">/pub/</a>. Check downloads against SHA256SUMS in each folder. "
        f"No public rsync, sorry — write if you want to sync from us.</p><p>Problems: mirror@{escape(domain)}. Include the URL and the time.</p>"
        f"<hr><small>generated {now:%Y-%m-%d %H:%M} UTC</small></main>"
    )
    page("index.html", f"{org}-mirror", css, body)
    page("404.html", "404 Not Found", css, '<main><pre class="banner">404 not found</pre><p>Not on this mirror. Start at <a href="/pub/">/pub/</a>.</p></main>')
    write("favicon.svg", '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" fill="#111"/><text x="8" y="12" font-family="monospace" font-size="11" text-anchor="middle" fill="#fffff8">m</text></svg>\n')
    common_files(["/"], [])


def build_nightly():
    projects = [("Tessellate", "An offline renderer for map tiles."), ("Fernwood", "A level editor for open-source game engines."), ("Calder", "Bakes lighting for 3D scenes without a GPU."), ("Larkspur", "Indexes a photo library you host yourself."), ("Quillmark", "A desktop editor for long markup documents."), ("Driftnet", "Reads packet captures faster than you can scroll.")]
    name, tagline = rng.choice(projects)
    lower = name.lower()
    accent = rng.choice(["#d9480f", "#1864ab", "#2b8a3e", "#862e9c", "#c2255c"])
    face = fonts([("Schibsted Grotesk", "schibsted-grotesk", 400, "normal", ["latin"]), ("Schibsted Grotesk", "schibsted-grotesk", 700, "normal", ["latin"]), ("DM Mono", "dm-mono", 400, "normal", ["latin"])])
    major, minor = rng.randint(0, 3), rng.randint(5, 19)
    release = f"{major}.{minor}.{rng.randint(0, 4)}"
    rel_day = now - timedelta(days=rng.randint(12, 40))
    platforms = [("linux", "Linux", f"{lower}-{release}-linux-x86_64.tar.zst", rng.randint(150, 220) * MB),
                 ("windows", "Windows", f"{lower}-{release}-windows-x64.zip", rng.randint(180, 240) * MB),
                 ("macos", "macOS", f"{lower}-{release}-macos-universal.dmg", rng.randint(200, 290) * MB)]
    for _, _, fname, size in platforms:
        blob(f"releases/{release}/{fname}", size, rel_day)
    write(f"releases/{release}/SHA256SUMS", "".join(f"{sha(f)}  {f}\n" for _, _, f, _ in platforms))
    suffix = {"linux": ("linux-x86_64", "tar.zst", 150, 230), "windows": ("windows-x64", "zip", 180, 260), "macos": ("macos-universal", "dmg", 220, 310)}
    builds = []
    for i in range(6):
        day = (now - timedelta(days=i)).replace(hour=2, minute=rng.randint(0, 50), second=0)
        arts = []
        if i < 3:
            for key, (tail, ext, low, high) in suffix.items():
                fname = f"{lower}-{major}.{minor + 1}-nightly-{day:%Y%m%d}-{tail}.{ext}"
                arts.append((key, fname, blob(f"nightly/{day:%Y-%m-%d}/{fname}", rng.randint(low, high) * MB, day)))
            write(f"nightly/{day:%Y-%m-%d}/SHA256SUMS", "".join(f"{sha(f)}  {f}\n" for _, f, _ in arts))
        builds.append((day, sha(f"c{i}")[:9], arts))
    css = face + (
        f":root{{--accent:{accent};--ink:#111214;--dim:#5f6368;--line:#e4e4e1}}"
        "*{box-sizing:border-box}body{margin:0;background:#fff;color:var(--ink);font:16px/1.6 'Schibsted Grotesk','Helvetica Neue',Arial,sans-serif}"
        "a{color:var(--accent)}.wrap{max-width:960px;margin:auto;padding:0 26px}code,.mono{font-family:'DM Mono',Menlo,monospace;font-size:14px}"
        "nav{display:flex;align-items:center;gap:26px;height:70px}nav .logo{font-weight:700;font-size:20px;letter-spacing:-.02em;margin-right:auto;color:var(--ink);text-decoration:none}"
        "nav .logo i{display:inline-block;width:10px;height:10px;background:var(--accent);margin-right:8px}nav a{color:var(--dim);text-decoration:none;font-size:15px}nav a.on{color:var(--ink)}"
        ".hero{padding:70px 0 40px}.hero h1{font-size:clamp(48px,8vw,92px);line-height:.95;letter-spacing:-.045em;margin:0}.hero p{font-size:21px;color:var(--dim);margin:18px 0 0;max-width:30ch}"
        ".get{border:1.5px solid var(--ink);margin:10px 0 24px}.tabs{display:flex;border-bottom:1.5px solid var(--ink)}"
        ".tabs button{flex:1;font:inherit;font-weight:700;background:#fff;border:0;border-right:1.5px solid var(--ink);padding:14px;cursor:pointer;color:var(--dim)}.tabs button:last-child{border-right:0}"
        ".tabs button.on{background:var(--ink);color:#fff}.pane{display:none;padding:26px 24px;align-items:center;gap:24px;flex-wrap:wrap}.pane.on{display:flex}"
        ".pane a.dl{background:var(--accent);color:#fff;text-decoration:none;font-weight:700;padding:14px 22px}.pane .mono{color:var(--dim);overflow-wrap:anywhere}"
        "h2{font-size:28px;letter-spacing:-.02em;margin:56px 0 14px}table{width:100%;border-collapse:collapse;font-size:15px}td,th{text-align:left;padding:11px 12px 11px 0;border-top:1px solid var(--line)}th{font-weight:400;color:var(--dim)}"
        "pre{background:#f5f5f2;padding:18px 20px;overflow:auto;font:14px/1.6 'DM Mono',Menlo,monospace}ul{padding-left:18px}li{margin:4px 0}"
        "footer{margin-top:70px;padding:26px 0 40px;border-top:1px solid var(--line);color:var(--dim);font-size:14px}"
    )

    def nav(on):
        item = lambda key, href, label: f'<a href="{href}"{" class=on" if on == key else ""}>{label}</a>'
        return f'<div class="wrap"><nav><a class="logo" href="/"><i></i>{name}</a>{item("home", "/", "Download")}{item("nightly", "/nightly/", "Nightly")}{item("log", "/changelog/", "Changelog")}</nav>'

    tabs = "".join(f'<button type="button" data-os="{k}">{label}</button>' for k, label, _, _ in platforms)
    panes = "".join(f'<div class="pane" data-os="{k}"><a class="dl" href="/releases/{release}/{f}">Download for {label}</a><span>{human(s)}</span><span class="mono">sha256 {sha(f)[:16]}…</span></div>' for k, label, f, s in platforms)
    picker = ("<script>(function(){var ua=navigator.userAgent,os=/Windows/.test(ua)?'windows':/Mac/.test(ua)?'macos':'linux';"
              "function pick(k){document.querySelectorAll('[data-os]').forEach(function(x){x.classList.toggle('on',x.dataset.os===k)})}"
              "document.querySelectorAll('.tabs button').forEach(function(b){b.addEventListener('click',function(){pick(b.dataset.os)})});pick(os)})();</script>")
    body = (
        f'{nav("home")}<section class="hero"><h1>{name}<br>{release}</h1><p>{tagline}</p></section>'
        f'<div class="get"><div class="tabs">{tabs}</div>{panes}</div>'
        f'<p style="color:var(--dim)">Released {rel_day.day} {rel_day:%B %Y}. Checksums in <a href="/releases/{release}/SHA256SUMS">SHA256SUMS</a>. Want the newest code? Try a <a href="/nightly/">nightly build</a>.</p>'
        f'<h2>Build it yourself</h2><pre>git clone https://{domain}/git/{lower}.git\ncd {lower}\ncmake -B build -DCMAKE_BUILD_TYPE=Release\ncmake --build build -j</pre>'
        f'<footer>{name} is free software under the GPL-3.0. Bugs and patches: dev@{escape(domain)}</footer></div>{picker}'
    )
    page("index.html", f"{name} — download", css, body)
    rows = ""
    for day, commit, arts in builds:
        files = " · ".join(f'<a href="/nightly/{day:%Y-%m-%d}/{f}">{label}</a> <span style="color:var(--dim)">{human(s)}</span>' for label, f, s in arts) or '<span style="color:var(--dim)">expired</span>'
        rows += f'<tr><td class="mono">{day:%Y-%m-%d %H:%M}</td><td class="mono">{commit}</td><td>{files}</td></tr>'
    page("nightly/index.html", f"{name} nightly builds", css, f'{nav("nightly")}<section class="hero" style="padding-bottom:20px"><h1>Nightly</h1><p>Straight from main, every night at 02:00 UTC. Kept for three days.</p></section><table><tr><th>built (UTC)</th><th>commit</th><th>files</th></tr>{rows}</table><footer>Nightly builds can eat your project files. Back them up.</footer></div>')
    changes = ["Fixed a crash when the cache lives on a network share", "Startup is faster on projects with many small files", "New --threads option on the command line", "Bundled zlib updated to 1.3.1", "The Windows installer no longer asks for admin rights", "Import accepts files with a UTF-8 BOM", "Export uses less memory on large projects", "Dark theme follows the system setting on Linux"]
    rng.shuffle(changes)
    log = "".join(f"<h2>{major}.{minor}.{i}</h2><ul>" + "".join(f"<li>{c}</li>" for c in changes[i * 2:i * 2 + 3]) + "</ul>" for i in range(3, 0, -1))
    page("changelog/index.html", f"{name} changelog", css, f'{nav("log")}<section class="hero" style="padding-bottom:0"><h1>Changelog</h1></section>{log}<footer>Older entries are in the git history.</footer></div>')
    page("404.html", "Not found", css, f'{nav("")}<section class="hero"><h1>404</h1><p>Nightly builds expire after three days. <a href="/nightly/">See current ones</a>.</p></section></div>')
    write("favicon.svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" fill="{accent}"/></svg>\n')
    common_files(["/", "/nightly/", "/changelog/"], ["/releases/", "/nightly/20"])


def build_podcast():
    shows = [("Длинные разговоры", "Беседы с инженерами, исследователями и людьми редких профессий."), ("Вечерний эфир", "Разговоры о городах, книгах и работе."), ("Неспешно", "Подкаст о науке и о том, как она делается."), ("Своими словами", "Интервью с людьми, которые что-то построили сами.")]
    show, about = rng.choice(shows)
    titles = [
        "Звукорежиссёр: почему тишину записывают отдельно",
        "Реставратор книг о клее, который держит триста лет",
        "Картограф: как рисуют карту района, которого ещё нет",
        "Пилот малой авиации о погоде, которую не видно на радаре",
        "Сыровар о терпении и погребе на двенадцать градусов",
        "Архивист: что выбрасывают и почему об этом жалеют",
        "Биолог-полевик о трёх месяцах в палатке",
        "Часовщик о механизме, который собирали двое",
        "Переводчик технической литературы о словах, которых нет в словаре",
        "Метеоролог: почему прогноз на десять дней — это честно",
        "Мостостроитель о том, как мост проверяют перед открытием",
        "Смотритель маяка о работе, которую почти отменили",
    ]
    rng.shuffle(titles)
    deep, warm = rng.choice([("#8c2f1c", "#e9c46a"), ("#1f4e5f", "#e76f51"), ("#3d405b", "#f2cc8f"), ("#2d3a2e", "#e07a5f")])
    face = fonts([("Literata", "literata", 400, "normal", ["latin", "cyrillic"]), ("Literata", "literata", 700, "normal", ["latin", "cyrillic"]), ("Literata", "literata", 400, "italic", ["latin", "cyrillic"])])
    episodes = []
    first = rng.randint(118, 164)
    for i in range(10):
        number = first - i
        day = (now - timedelta(days=7 * i + rng.randint(0, 3))).replace(hour=9, minute=0, second=0)
        minutes = rng.randint(48, 115)
        size = minutes * 60 * 128 * 1000 // 8
        fname = f"audio/{day:%Y}/ep{number:03d}.mp3"
        blob(fname, size, day)
        episodes.append((number, day, minutes, size, fname, titles[i]))
    months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]

    def ru_date(d):
        return f"{d.day} {months[d.month - 1]}"

    css = face + (
        f":root{{--paper:#f4efe6;--ink:#1f1a16;--dim:#7a6f63;--line:#ddd3c4;--deep:{deep};--warm:{warm}}}"
        "*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:18px/1.55 Literata,Georgia,'Times New Roman',serif}"
        "a{color:var(--deep)}.wrap{max-width:860px;margin:auto;padding:0 26px}"
        ".mast{display:grid;grid-template-columns:200px 1fr;gap:34px;align-items:end;padding:64px 0 38px;border-bottom:3px double var(--ink)}"
        ".cover{aspect-ratio:1;background:var(--deep);position:relative;overflow:hidden}"
        ".cover:before{content:'';position:absolute;width:150%;height:150%;left:-60%;top:35%;border-radius:50%;background:var(--warm)}"
        ".cover:after{content:attr(data-n);position:absolute;left:14px;top:8px;color:var(--paper);font:700 22px Literata,serif}"
        ".mast h1{font-size:clamp(40px,6vw,64px);line-height:1;margin:0;letter-spacing:-.02em}.mast p{margin:12px 0 0;font-style:italic;color:var(--dim)}"
        ".mast nav{margin-top:14px;font-size:15px}.lead{padding:34px 0;border-bottom:1px solid var(--line)}"
        ".lead small,.ep small{font-size:14px;color:var(--dim);letter-spacing:.03em}.lead h2{font-size:34px;line-height:1.15;margin:6px 0 10px}"
        ".ep{display:grid;grid-template-columns:90px 1fr auto;gap:18px;align-items:baseline;padding:20px 0;border-bottom:1px solid var(--line)}"
        ".ep b{font-size:34px;color:var(--deep);font-weight:700;line-height:1}.ep h3{font-size:20px;font-weight:400;margin:0}.ep a.get{font-size:15px;white-space:nowrap}"
        "footer{padding:34px 0 50px;font-size:15px;color:var(--dim)}@media(max-width:640px){.mast{grid-template-columns:1fr}.cover{width:140px}.ep{grid-template-columns:60px 1fr}.ep a.get{grid-column:2}}"
    )
    latest = episodes[0]
    rest = "".join(
        f'<div class="ep"><b>{n}</b><div><h3>{escape(t)}</h3><small>{ru_date(d)} · {m} мин</small></div><a class="get" href="/{f}">mp3 · {human(s, ru=True)}</a></div>'
        for n, d, m, s, f, t in episodes[1:]
    )
    body = (
        f'<div class="wrap"><header class="mast"><div class="cover" data-n="{escape(show[0])}"></div><div><h1>{escape(show)}</h1><p>{escape(about)}</p>'
        f'<nav><a href="/feed.xml">RSS</a> · новый выпуск по средам</nav></div></header>'
        f'<section class="lead"><small>Выпуск {latest[0]} · {ru_date(latest[1])} · {latest[2]} мин</small><h2>{escape(latest[5])}</h2><a href="/{latest[4]}">Скачать mp3, {human(latest[3], ru=True)}</a></section>'
        f'{rest}<footer>Выпуски раньше {episodes[-1][0]}-го — по запросу: hello@{escape(domain)}</footer></div>'
    )
    page("index.html", show, css, body, lang="ru", head='<link rel="alternate" type="application/rss+xml" title="RSS" href="/feed.xml">')
    items = "".join(
        f"<item><title>{escape(t)}</title><guid isPermaLink=\"false\">{domain}-ep{n}</guid><pubDate>{d:%a, %d %b %Y %H:%M:%S} +0000</pubDate>"
        f"<enclosure url=\"https://{domain}/{f}\" length=\"{s}\" type=\"audio/mpeg\"/><itunes:duration>{m * 60}</itunes:duration></item>"
        for n, d, m, s, f, t in episodes
    )
    write("feed.xml", f'<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>{escape(show)}</title><link>https://{domain}/</link><language>ru</language><description>{escape(about)}</description>{items}</channel></rss>\n')
    page("404.html", "Не найдено", css, '<div class="wrap"><header class="mast"><div class="cover" data-n="?"></div><div><h1>Такого выпуска нет</h1><p><a href="/">Ко всем выпускам</a></p></div></header></div>', lang="ru")
    write("favicon.svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" fill="{deep}"/><circle cx="6" cy="17" r="11" fill="{warm}"/></svg>\n')
    common_files(["/", "/feed.xml"], ["/audio/"])


def build_lectures():
    clubs = [("Лекторий «Пятница»", "Открытые лекции по средам и пятницам. Записи выкладываем через пару дней после встречи."),
             ("Семинар по вычислительной физике", "Еженедельный семинар для студентов и всех, кому интересно. Записи — для тех, кто не смог прийти."),
             ("Клуб «Хорошие вопросы»", "Лекции учёных и инженеров для тех, кто давно закончил школу. Видео в исходном качестве.")]
    club, about = rng.choice(clubs)
    courses = [
        ("Как устроены компиляторы", ["Лексер и парсер руками", "Промежуточное представление", "Регистры и распределение", "Оптимизации, которые стоит знать"]),
        ("Климат без паники", ["Что меряют метеостанции", "Модели и их ошибки", "Океан как батарейка", "Что мы знаем точно"]),
        ("История инженерных катастроф", ["Мост через Такому", "Рухнувшие крыши", "Ошибки в чертежах", "Как теперь проверяют"]),
        ("Звук и слух", ["Почему мы слышим направление", "Комнаты и эхо", "Цифровой звук без мифов"]),
        ("Картография для любопытных", ["Проекции и обман", "Как рисовали карты до спутников", "Открытые карты сегодня"]),
    ]
    rng.shuffle(courses)
    face = fonts([("Golos Text", "golos-text", 400, "normal", ["latin", "cyrillic"]), ("Golos Text", "golos-text", 600, "normal", ["latin", "cyrillic"])])
    months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]
    accent = rng.choice(["#2f5d50", "#3a4e8c", "#8a3b2a"])
    blocks = ""
    offset = 0
    for title, talks in courses[:4]:
        rows = ""
        for n, talk in enumerate(talks, 1):
            offset += rng.randint(5, 9)
            day = (now - timedelta(days=offset)).replace(hour=19, minute=0, second=0)
            minutes = rng.randint(70, 115)
            size = int(minutes * 60 * rng.uniform(2.6, 4.2) * 1000 * 1000 / 8)
            slug = f"video/{day:%Y-%m}/{hashlib.md5((title + talk).encode()).hexdigest()[:8]}.mp4"
            blob(slug, size, day)
            rows += (f'<tr><td class="n">{n}</td><td>{escape(talk)}</td><td class="d">{day.day} {months[day.month - 1]}</td>'
                     f'<td class="d">{minutes // 60}:{minutes % 60:02d}</td><td><a href="/{slug}">mp4 · {human(size, ru=True)}</a></td></tr>')
        blocks += f'<section><h2>{escape(title)}</h2><table>{rows}</table></section>'
    css = face + (
        f":root{{--ink:#16181a;--dim:#6b6f73;--line:#e1e1dc;--accent:{accent};--bg:#fbfbf8}}"
        "*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.55 'Golos Text','Segoe UI',Arial,sans-serif}"
        ".wrap{max-width:980px;margin:auto;padding:0 28px}a{color:var(--accent)}"
        "header{display:grid;grid-template-columns:1fr 1fr;gap:40px;padding:64px 0 36px;border-bottom:1px solid var(--ink)}"
        "header h1{font-size:clamp(34px,5vw,54px);line-height:1.02;font-weight:600;margin:0;letter-spacing:-.02em}header p{margin:6px 0 0;color:var(--dim)}"
        "section{display:grid;grid-template-columns:260px 1fr;gap:28px;padding:30px 0;border-bottom:1px solid var(--line)}"
        "h2{font-size:21px;font-weight:600;margin:0;line-height:1.25}table{width:100%;border-collapse:collapse;font-size:16px}"
        "td{padding:8px 14px 8px 0;border-bottom:1px solid var(--line);vertical-align:baseline}tr:last-child td{border-bottom:0}"
        "td.n{color:var(--accent);font-weight:600;width:28px}td.d{color:var(--dim);white-space:nowrap;font-size:14px}td a{white-space:nowrap;font-size:14px}"
        "footer{padding:30px 0 50px;color:var(--dim);font-size:14px}@media(max-width:760px){header,section{grid-template-columns:1fr}td.d:first-of-type{display:none}}"
    )
    body = (f'<div class="wrap"><header><h1>{escape(club)}</h1><p>{escape(about)} Файлы большие: на медленном интернете лучше скачивать заранее.</p></header>'
            f'{blocks}<footer>Записи старше полугода убираем в архив, их можно попросить: lectures@{escape(domain)}</footer></div>')
    page("index.html", club, css, body, lang="ru")
    page("404.html", "Не найдено", css, '<div class="wrap"><header><h1>Записи нет</h1><p><a href="/">Все лекции</a></p></header></div>', lang="ru")
    write("favicon.svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" fill="{accent}"/><path d="M6 4l6 4-6 4z" fill="#fbfbf8"/></svg>\n')
    common_files(["/"], ["/video/"])


def build_gameserver():
    names = ["Mossgate", "Ironvale", "Slatecraft", "Pinewick", "Coalbrook", "Driftholm"]
    server = rng.choice(names)
    face = fonts([("Pixelify Sans", "pixelify-sans", 500, "normal", ["latin"]), ("Pixelify Sans", "pixelify-sans", 700, "normal", ["latin"]),
                  ("Atkinson Hyperlegible", "atkinson-hyperlegible", 400, "normal", ["latin"]), ("Atkinson Hyperlegible", "atkinson-hyperlegible", 700, "normal", ["latin"])])
    online = rng.randint(9, 46)
    since = now - timedelta(days=rng.randint(400, 1400))
    packs = [
        ("Server modpack", f"{server.lower()}-modpack-{now:%Y.%m}.zip", rng.randint(380, 720) * MB, "Every mod the server runs, ready to drop into your mods folder."),
        ("HD texture pack", f"{server.lower()}-textures-256x.zip", rng.randint(900, 1600) * MB, "256× textures made by players. Needs a decent GPU."),
        ("World backup", f"{server.lower()}-world-{(now - timedelta(days=rng.randint(2, 9))):%Y%m%d}.tar.zst", rng.randint(3, 9) * GB, "Full map backup, rotated weekly. Explore it in singleplayer."),
        ("Sound pack", f"{server.lower()}-ambient-sounds.zip", rng.randint(120, 260) * MB, "Ambient music and sounds used on spawn."),
    ]
    cards = ""
    for title, fname, size, note in packs:
        blob(f"downloads/{fname}", size, now - timedelta(days=rng.randint(1, 30)))
        cards += f'<a class="card" href="/downloads/{fname}"><b>{title}</b><span>{escape(note)}</span><em>{fname} · {human(size)}</em></a>'
    rules = ["No griefing, no stealing from unlocked chests", "Build at least 200 nodes away from spawn", "Lag machines get removed without warning", "English or Russian in global chat"]
    css = face + (
        ":root{--bg:#1c2117;--panel:#262d1f;--ink:#e9eadb;--dim:#a2a68f;--grass:#7fbf4d;--dirt:#8a6239}"
        "*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.55 'Atkinson Hyperlegible',Verdana,sans-serif}"
        "body:before{content:'';display:block;height:14px;background:repeating-linear-gradient(90deg,var(--grass) 0 14px,#6aa23f 14px 28px);box-shadow:0 14px 0 var(--dirt)}"
        ".wrap{max-width:960px;margin:auto;padding:40px 24px}h1,h2,b{font-family:'Pixelify Sans',monospace}a{color:var(--grass)}"
        "h1{font-size:clamp(44px,8vw,84px);line-height:1;margin:22px 0 10px;letter-spacing:.02em}.status{display:inline-flex;gap:10px;align-items:center;background:var(--panel);padding:8px 14px;font-size:15px}"
        ".status i{width:10px;height:10px;background:var(--grass);display:inline-block;box-shadow:0 0 0 3px #7fbf4d33}"
        ".addr{font:15px monospace;background:#11140e;padding:14px 16px;margin:22px 0 0;display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}"
        "h2{font-size:30px;margin:54px 0 16px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:14px}"
        ".card{display:block;background:var(--panel);padding:20px;text-decoration:none;color:var(--ink);border-bottom:4px solid #11140e}.card:hover{border-bottom-color:var(--grass)}"
        ".card b{display:block;font-size:22px;color:var(--grass)}.card span{display:block;color:var(--dim);margin:4px 0 12px}.card em{font:13px monospace;color:var(--ink)}"
        "ol{padding-left:22px}li{margin:6px 0}footer{margin-top:60px;color:var(--dim);font-size:14px}@media(max-width:700px){.grid{grid-template-columns:1fr}}"
    )
    body = (f'<div class="wrap"><span class="status"><i></i>{online} players online · up {(now - since).days} days</span><h1>{server}</h1>'
            f'<p style="color:var(--dim);max-width:38em">A survival server for Luanti, the open-source voxel game. Small community, weekly world backups, mods that stay out of the way.</p>'
            f'<div class="addr"><span>{escape(domain)} : 30000</span><span>Luanti 5.12+ · survival · PvP off</span></div>'
            f'<h2>Downloads</h2><div class="grid">{cards}</div><h2>Rules</h2><ol>' + "".join(f"<li>{r}</li>" for r in rules) +
            f'</ol><footer>Running since {since:%B %Y}. Questions and ban appeals: admin@{escape(domain)}</footer></div>')
    page("index.html", f"{server} — Luanti server", css, body)
    page("404.html", "Not found", css, f'<div class="wrap"><h1>404</h1><p>This chunk is not generated. <a href="/">Back to spawn</a>.</p></div>')
    write("favicon.svg", '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="6" fill="#7fbf4d"/><rect y="6" width="16" height="10" fill="#8a6239"/></svg>\n')
    common_files(["/"], ["/downloads/"])


{"lectures": build_lectures, "gameserver": build_gameserver, "speedtest": build_speedtest, "lg": build_lg, "mirror": build_mirror, "nightly": build_nightly, "podcast": build_podcast}[theme]()
print(f"Шаблон {theme}: сайт для {domain} готов")
PY
  )
}

pick_theme() {
  local requested="${SELFSTEAL_THEME:-}" stored=""
  [[ -f "$THEME_FILE" ]] && stored="$(cat "$THEME_FILE")"
  if [[ "$requested" == random ]]; then
    requested="${SITE_THEMES[RANDOM % ${#SITE_THEMES[@]}]}"
  fi
  if [[ -n "$requested" ]]; then
    [[ " ${SITE_THEMES[*]} formats " == *" $requested "* ]] || die "Неизвестный SELFSTEAL_THEME=$requested. Есть: ${SITE_THEMES[*]} formats random"
    SITE_THEME="$requested"
  elif [[ -n "$stored" && " ${SITE_THEMES[*]} " == *" $stored "* ]]; then
    SITE_THEME="$stored"
  else
    # один домен — один шаблон: при переустановке сайт не меняется, а у разных нод выходят разные
    SITE_THEME="${SITE_THEMES[$(( $(printf '%s' "$SITE_DOMAIN" | cksum | awk '{print $1}') % ${#SITE_THEMES[@]} ))]}"
  fi
}

write_site() {
  local staged previous status=0
  install -d -m 755 "$REMNA_DIR/selfsteal"
  staged="$(mktemp -d "$REMNA_DIR/selfsteal/.site-next.XXXXXX")"
  chmod 755 "$staged"
  if [[ "$SITE_THEME" != formats ]]; then
    write_theme_site "$staged" || status=$?
    if (( status == 3 )); then
      echo "Файловая система не держит разреженные файлы: большие файлы шаблона заняли бы диск. Беру лёгкий шаблон formats."
      SITE_THEME=formats
      rm -rf "$staged"
      staged="$(mktemp -d "$REMNA_DIR/selfsteal/.site-next.XXXXXX")"
      chmod 755 "$staged"
    elif (( status != 0 )); then
      rm -rf "$staged"
      die "Не удалось собрать сайт (шаблон $SITE_THEME)"
    fi
  fi
  if [[ "$SITE_THEME" == formats ]]; then
    write_formats_site "$staged"
  fi
  previous=""
  if [[ -d "$SITE_DIR" ]]; then
    previous="$REMNA_DIR/selfsteal/site-backup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mv "$SITE_DIR" "$previous"
  fi
  if ! mv "$staged" "$SITE_DIR"; then
    [[ -z "$previous" ]] || mv "$previous" "$SITE_DIR"
    die "Не удалось заменить файлы сайта"
  fi
  printf '%s\n' "$SITE_DOMAIN" > "$REMNA_DIR/selfsteal/domain"
  printf '%s\n' "$SITE_THEME" > "$THEME_FILE"
}

write_nginx_conf() {
  local with_https="$1" speedtest=0 holder
  [[ "$SITE_THEME" == speedtest || "$SITE_THEME" == lg ]] && speedtest=1
  if (( with_https && speedtest )); then
    holder="$(ss -ltnpH "sport = :$SPEED_PORT" 2>/dev/null | grep -v nginx || true)"
    [[ -z "$holder" ]] || die "Порт $SPEED_PORT для приёма замера скорости занят. Задайте SELFSTEAL_SPEED_PORT."
  fi
  {
    cat <<EOF
limit_conn_zone \$server_name zone=selfsteal_files:1m;

server {
    listen 80;
    server_name $SITE_DOMAIN;
    server_tokens off;
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_DIR;
        default_type text/plain;
    }
    location / {
        return 301 https://$SITE_DOMAIN\$request_uri;
    }
}
EOF
    if (( with_https )); then
      cat <<EOF

server {
    listen 127.0.0.1:$SITE_PORT ssl http2;
    server_name $SITE_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$SITE_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SITE_DOMAIN/privkey.pem;
    ssl_session_cache shared:selfsteal_tls:20m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    server_tokens off;
    access_log off;
    keepalive_requests 1000;
    sendfile on;
    tcp_nopush on;
    open_file_cache max=4000 inactive=60s;
    charset utf-8;
    root $SITE_DIR;
    index index.html;
    error_page 404 /404.html;
    location = /404.html { internal; }
    location / {
        try_files \$uri \$uri/ =404;
    }
    location /assets/ {
        expires 30d;
    }
    # большие файлы: листинг как у настоящих зеркал, скорость на поток ограничена, чтобы проверки не выкачивали канал
    location ~ ^/(pub|files|nightly|releases|audio|video|downloads)/ {
        autoindex on;
        autoindex_exact_size off;
        limit_conn selfsteal_files 16;
        limit_rate_after 32m;
        limit_rate 12m;
    }
EOF
      if (( speedtest )); then
        cat <<EOF
    location = /speedtest/empty {
        add_header Cache-Control "no-store" always;
        return 204;
    }
    location = /speedtest/garbage.bin {
        add_header Cache-Control "no-store" always;
        limit_conn selfsteal_files 16;
        limit_rate 25m;
    }
    location = /speedtest/upload {
        client_max_body_size 16m;
        client_body_buffer_size 16m;
        proxy_request_buffering on;
        proxy_pass http://127.0.0.1:$SPEED_PORT;
    }
EOF
      fi
      echo "}"
      if (( speedtest )); then
        cat <<EOF

server {
    listen 127.0.0.1:$SPEED_PORT;
    access_log off;
    client_max_body_size 16m;
    return 204;
}
EOF
      fi
    fi
  } > "$NGINX_CONF"
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

# Для одинаковых доменов копируем уже выданный сертификат self-steal.
# Не пишем в /etc/letsencrypt/live: этот каталог управляется Certbot.
copy_shared_hy2_cert() {
  local source_dir="/etc/letsencrypt/live/$SITE_DOMAIN"
  local target_dir="/etc/letsencrypt/hysteria2/$HY2_DOMAIN"
  [[ -s "$source_dir/fullchain.pem" && -s "$source_dir/privkey.pem" ]] || die "Отсутствует сертификат или ключ self-steal для $SITE_DOMAIN"
  install -d -m 700 "$target_dir"
  install -m 644 "$source_dir/fullchain.pem" "$target_dir/fullchain.pem"
  install -m 600 "$source_dir/privkey.pem" "$target_dir/privkey.pem"
  echo "Hysteria2: скопирован сертификат self-steal в $target_dir"
}

detect_node_ips() {
  if [[ -n "${SELFSTEAL_PUBLIC_IP:-}" ]]; then
    NODE_IPV4="$SELFSTEAL_PUBLIC_IP"
  else
    NODE_IPV4="$(curl -4fsS --noproxy '*' --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  fi
  valid_ipv4 "$NODE_IPV4" || NODE_IPV4="$(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4, p, "/"); print p[1]; exit}')"
  NODE_IPV6="$(curl -6fsS --noproxy '*' --max-time 6 https://api64.ipify.org 2>/dev/null || true)"
  [[ "$NODE_IPV6" == *:* ]] || NODE_IPV6=""
}

# BBR и буферы под много соединений: fq + bbr заметно ровнее держат поток на дальних маршрутах,
# большие буферы нужны QUIC (Hysteria2), иначе ядро режет UDP на высоких скоростях
apply_network_tuning() {
  modprobe tcp_bbr 2>/dev/null || true
  cat > "$SYSCTL_CONF" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
fs.file-max = 2097152
net.netfilter.nf_conntrack_max = 1048576
EOF
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    printf 'tcp_bbr\n' > /etc/modules-load.d/remnanode-bbr.conf
  else
    sed -i '/tcp_congestion_control/d;/default_qdisc/d' "$SYSCTL_CONF"
    echo "BBR в этом ядре нет — алгоритм управления перегрузкой не меняю"
  fi
  [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]] || sed -i '/nf_conntrack_max/d' "$SYSCTL_CONF"
  if sysctl -q -p "$SYSCTL_CONF" >/dev/null 2>&1; then
    echo "Сеть: применены настройки из $SYSCTL_CONF"
  else
    echo "Сеть: часть параметров не применилась (контейнерная виртуализация?), остальное работает"
  fi
}

tune_nginx_main() {
  local main=/etc/nginx/nginx.conf backup current
  [[ -f "$main" ]] || return 0
  backup="$main.before-remnanode"
  [[ -f "$backup" ]] || cp "$main" "$backup"
  current="$(sed -nE 's/^[[:space:]]*worker_connections[[:space:]]+([0-9]+);.*/\1/p' "$main" | head -n1)"
  if [[ -n "$current" ]] && (( current < 8192 )); then
    sed -Ei 's/^([[:space:]]*worker_connections[[:space:]]+)[0-9]+;/\18192;/' "$main"
  fi
  if ! grep -Eq '^[[:space:]]*worker_rlimit_nofile' "$main"; then
    sed -Ei '0,/^[[:space:]]*worker_processes[^;]*;/s//&\nworker_rlimit_nofile 65535;/' "$main"
  fi
  mkdir -p /etc/systemd/system/nginx.service.d
  printf '[Service]\nLimitNOFILE=65535\n' > /etc/systemd/system/nginx.service.d/remnanode-limits.conf
  systemctl daemon-reload
  if ! nginx -t >/dev/null 2>&1; then
    cp "$backup" "$main"
    echo "nginx.conf: настройку воркеров откатил — nginx -t её не принял"
  fi
}

install_cf_helper() {
  install -d -m 755 /usr/local/sbin
  cat > "$CF_HELPER" <<'PY'
#!/usr/bin/env python3
import ipaddress
import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("CF_API_BASE", "https://api.cloudflare.com/client/v4")
TOKEN = os.environ.get("CF_API_TOKEN", "")
TTL = 60
PANEL_API = os.environ.get("NODE_DNS_API", "https://app.willvpn.space/api/node-installer/dns")


def node_key():
    key = os.environ.get("SECRET_KEY", "").strip()
    if not key:
        try:
            for line in open("/opt/remnanode/.env"):
                if line.startswith("SECRET_KEY="):
                    key = line.split("=", 1)[1].strip()
        except OSError:
            pass
    if not key:
        die("нет SECRET_KEY ноды")
    return key


def panel(payload, family=socket.AF_INET):
    # в панель идём нужным семейством адресов: запись получает тот IP, с которого пришёл запрос
    original = socket.getaddrinfo
    socket.getaddrinfo = lambda *a, **k: [r for r in original(*a, **k) if r[0] == family]
    try:
        request = urllib.request.Request(PANEL_API, method="POST", data=json.dumps(dict(payload, secret_key=node_key())).encode(),
                                         headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=40) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            detail = json.load(error).get("detail")
        except Exception:
            detail = f"HTTP {error.code}"
        print(f"Панель: {detail}", file=sys.stderr)
        sys.exit(2 if error.code == 503 else 1)
    except Exception as error:
        if family == socket.AF_INET6:
            return None
        die(f"панель недоступна: {error}")
    finally:
        socket.getaddrinfo = original


def panel_main(argv):
    command = argv[1]
    if command == "check":
        result = panel({"action": "check"})
        print(f"Панель: ключ ноды принят, внешний IP {result['ip']}")
        return
    if command in {"plan", "set"} and len(argv) < 3:
        die("не указан домен")
    if command == "plan":
        for line in panel({"action": "plan", "domain": argv[2]}).get("records", []):
            print(line)
        return
    names = [argv[2]] if command == "set" else os.environ.get("CF_DOMAINS", "").split()
    args = argv[3:]
    for name in names:
        result = panel({"action": "set", "domain": name, "move_old": command == "sync" or "--move-old" in args, "drop_ipv6": "--drop-ipv6" in args})
        print("\n".join(result["changes"]))
        if command == "sync" or "--ipv6" in args:
            result6 = panel({"action": "set", "domain": name}, socket.AF_INET6)
            if result6:
                print("\n".join(result6["changes"]))


def die(message):
    print(f"Cloudflare: {message}", file=sys.stderr)
    sys.exit(1)


def call(method, path, body=None):
    request = urllib.request.Request(
        API + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            data = json.load(response)
    except urllib.error.HTTPError as error:
        try:
            data = json.load(error)
        except Exception:
            die(f"{method} {path.split('?')[0]}: HTTP {error.code}")
    except Exception as error:
        die(f"{method} {path.split('?')[0]}: {error}")
    if not data.get("success"):
        errors = "; ".join(f"{e.get('code')} {e.get('message')}" for e in data.get("errors") or [])
        die(f"{method} {path.split('?')[0]}: {errors or 'unknown error'}")
    return data.get("result")


def zone_for(name):
    labels = name.split(".")
    for i in range(len(labels) - 1):
        candidate = ".".join(labels[i:])
        zones = call("GET", "/zones?" + urllib.parse.urlencode({"name": candidate, "per_page": 5}))
        if zones:
            return zones[0]
    die(f"токен не видит зону для {name}: нужен доступ Zone.DNS:Edit к этому домену")


def records(zone, kind, name):
    return call("GET", f"/zones/{zone}/dns_records?" + urllib.parse.urlencode({"type": kind, "name": name, "per_page": 100})) or []


def put(zone, name, kind, content):
    if kind == "A":
        for record in records(zone, "CNAME", name):
            call("DELETE", f"/zones/{zone}/dns_records/{record['id']}")
            print(f"{name}: удалён CNAME → {record['content']} (мешал A-записи)")
    current = records(zone, kind, name)
    keep = next((r for r in current if r["content"] == content), current[0] if current else None)
    if keep is None:
        call("POST", f"/zones/{zone}/dns_records", {"type": kind, "name": name, "content": content, "ttl": TTL, "proxied": False})
        print(f"{name}: создана {kind} {content}")
    elif keep["content"] != content or keep.get("proxied") or keep.get("ttl") != TTL:
        call("PATCH", f"/zones/{zone}/dns_records/{keep['id']}", {"content": content, "ttl": TTL, "proxied": False})
        print(f"{name}: {kind} {keep['content']}{' (через прокси CF)' if keep.get('proxied') else ''} → {content}")
    else:
        print(f"{name}: {kind} {content} уже верная")
    for record in current:
        if keep is not None and record["id"] != keep["id"]:
            call("DELETE", f"/zones/{zone}/dns_records/{record['id']}")
            print(f"{name}: удалена лишняя {kind} {record['content']}")


def drop(zone, name, kind):
    for record in records(zone, kind, name):
        call("DELETE", f"/zones/{zone}/dns_records/{record['id']}")
        print(f"{name}: удалена {kind} {record['content']} — у ноды нет такого адреса")


def public_ip(v6):
    url = "https://api64.ipify.org" if v6 else "https://api.ipify.org"
    try:
        with urllib.request.urlopen(url, timeout=8) as response:
            value = response.read().decode().strip()
        address = ipaddress.ip_address(value)
        return value if address.version == (6 if v6 else 4) and address.is_global else None
    except Exception:
        return None


def move_old(zone, old_ips, new_ip):
    moved = 0
    for old in old_ips:
        query = urllib.parse.urlencode({"type": "A", "content": old, "per_page": 100})
        for record in call("GET", f"/zones/{zone}/dns_records?{query}") or []:
            if record.get("content") != old:
                continue
            call("PATCH", f"/zones/{zone}/dns_records/{record['id']}", {"content": new_ip})
            print(f"{record['name']}: A {old} → {new_ip} (стояла на старом IP ноды)")
            moved += 1
    if old_ips and not moved:
        print(f"Других записей на старом IP {', '.join(old_ips)} нет")


def ensure(name, ipv4, ipv6, drop_v6, move=False):
    ipaddress.IPv4Address(ipv4)
    zone = zone_for(name)
    # старый IP ноды — то, куда домен смотрел до переустановки; остальные записи на нём переезжают вместе с нодой
    old_ips = [r["content"] for r in records(zone["id"], "A", name) if r["content"] != ipv4] if move else []
    put(zone["id"], name, "A", ipv4)
    if old_ips:
        move_old(zone["id"], old_ips, ipv4)
    if ipv6:
        ipaddress.IPv6Address(ipv6)
        put(zone["id"], name, "AAAA", ipv6)
    elif drop_v6:
        drop(zone["id"], name, "AAAA")


def main(argv):
    if len(argv) < 2 or argv[1] not in {"check", "plan", "set", "sync"}:
        die("использование: check | plan <домен> --ipv4 IP | set <домен> --ipv4 IP [--ipv6 IP | --drop-ipv6] [--move-old] | sync")
    if not TOKEN:
        panel_main(argv)
        return
    if argv[1] == "check":
        call("GET", "/zones?per_page=1")
        print("Cloudflare: токен принят")
        return
    if argv[1] == "plan":
        if len(argv) < 5 or argv[3] != "--ipv4":
            die("использование: plan <домен> --ipv4 IP")
        name, ipv4 = argv[2].lower().rstrip("."), argv[4]
        zone = zone_for(name)["id"]
        for old_ip in sorted({r["content"] for r in records(zone, "A", name) if r["content"] != ipv4}):
            query = urllib.parse.urlencode({"type": "A", "content": old_ip, "per_page": 100})
            for record in call("GET", f"/zones/{zone}/dns_records?{query}") or []:
                if record.get("content") == old_ip and record["name"] != name:
                    print(f"{record['name']} {old_ip}")
        return
    if argv[1] == "set":
        if len(argv) < 3:
            die("не указан домен")
        name, args = argv[2].lower().rstrip("."), argv[3:]
        ipv4 = args[args.index("--ipv4") + 1] if "--ipv4" in args else None
        ipv6 = args[args.index("--ipv6") + 1] if "--ipv6" in args else None
        if not ipv4:
            die("не указан --ipv4")
        ensure(name, ipv4, ipv6, "--drop-ipv6" in args, "--move-old" in args)
        return
    names = os.environ.get("CF_DOMAINS", "").split()
    ipv4 = public_ip(False)
    if not names or not ipv4:
        die("нет доменов или не удалось узнать внешний IPv4")
    ipv6 = public_ip(True) if os.environ.get("CF_IPV6", "auto") != "off" else None
    for name in names:
        ensure(name, ipv4, ipv6, False, True)


main(sys.argv)
PY
  chmod 755 "$CF_HELPER"
}

setup_cloudflare() {
  # по умолчанию DNS правит панель: токен Cloudflare лежит только на ней, нода доказывает себя ключом SECRET_KEY.
  # CF_API_TOKEN=... включает прямой режим без панели
  local out status=0
  CF_API_TOKEN="${CF_API_TOKEN:-}"
  install_cf_helper
  out="$(CF_API_TOKEN="$CF_API_TOKEN" SECRET_KEY="$SECRET_KEY" "$CF_HELPER" check 2>&1)" || status=$?
  if (( status == 0 )); then
    echo "$out"
    USE_CF=1
    DNS_RESOLVER="1.1.1.1"
  elif (( status == 2 )); then
    echo "DNS: на панели автоматика не настроена — проверяю записи как раньше"
  else
    echo "DNS: автоматика недоступна ($out) — проверяю записи как раньше"
  fi
}

wait_public_dns() {
  local domain="$1" want="$2" i seen=""
  for (( i = 0; i < 36; i++ )); do
    seen="$(dig +short A "$domain" @1.1.1.1 | sort -u | tr '\n' ' ')$(dig +short A "$domain" @8.8.8.8 | sort -u | tr '\n' ' ')"
    if [[ "$seen" == "$want $want " ]]; then
      echo "DNS $domain → $want виден в 1.1.1.1 и 8.8.8.8"
      return 0
    fi
    sleep 5
  done
  echo "DNS $domain ещё не обновился у публичных резолверов (видно: ${seen:-ничего}). Продолжаю: Let's Encrypt спрашивает Cloudflare напрямую."
}

point_dns() {
  local domain="$1"
  local -a extra=()
  if [[ -n "$NODE_IPV6" ]]; then
    extra=(--ipv6 "$NODE_IPV6")
  elif [[ -z "$(ip -6 addr show scope global 2>/dev/null)" ]]; then
    extra=(--drop-ipv6)
  fi
  # нода переехала: всё, что в зоне смотрело на её старый IP, переводим на новый. сначала показываем список —
  # опечатка в домене иначе увела бы на этот сервер записи другой живой ноды
  local moving
  moving="$(CF_API_TOKEN="$CF_API_TOKEN" SECRET_KEY="$SECRET_KEY" "$CF_HELPER" plan "$domain" --ipv4 "$NODE_IPV4")" || die "Cloudflare: не удалось прочитать записи $domain"
  if [[ -n "$moving" ]]; then
    echo "На старом IP ноды стоят и другие записи (имя, IP):"
    sed 's/^/  /' <<< "$moving"
    if ask_yes_no_default_yes "Перевести их на $NODE_IPV4 вместе с $domain?"; then
      extra+=(--move-old)
    fi
  fi
  CF_API_TOKEN="$CF_API_TOKEN" SECRET_KEY="$SECRET_KEY" "$CF_HELPER" set "$domain" --ipv4 "$NODE_IPV4" "${extra[@]}" || die "Не удалось обновить DNS $domain в Cloudflare"
  wait_public_dns "$domain" "$NODE_IPV4"
}

enable_dns_watch() {
  local domains="$1"
  install -d -m 700 /etc/remnanode
  umask 077
  {
    printf 'CF_DOMAINS="%s"\n' "$domains"
    if [[ -n "$CF_API_TOKEN" ]]; then printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN"; fi
  } > "$CF_ENV"
  umask 022
  cat > /etc/systemd/system/remnanode-cf-dns.service <<EOF
[Unit]
Description=Point node domains in Cloudflare at this server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$CF_ENV
ExecStart=$CF_HELPER sync
EOF
  cat > /etc/systemd/system/remnanode-cf-dns.timer <<'EOF'
[Unit]
Description=Check node IP and fix Cloudflare DNS every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now remnanode-cf-dns.timer >/dev/null
  echo "DNS: раз в 10 минут проверяю IP ноды и правлю записи ($domains)"
}

[[ $EUID -eq 0 ]] || die "Run as root"
if [[ "${1:-}" == "--refresh-site" ]]; then
  [[ $# -eq 1 ]] || die "Использование: $0 --refresh-site"
  [[ -f "$REMNA_DIR/selfsteal/domain" && -d "$SITE_DIR" && -f "$NGINX_CONF" ]] || die "Сайт self-steal ещё не установлен"
  SITE_DOMAIN="$(cat "$REMNA_DIR/selfsteal/domain")"
  validate_domain "$SITE_DOMAIN"
  detect_node_ips
  pick_theme
  write_site
  write_nginx_conf 1
  echo "Обновлена страница https://$SITE_DOMAIN/ (шаблон $SITE_THEME)"
  exit 0
fi
[[ $# -eq 0 ]] || die "Неизвестный аргумент: $1"
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
fi

if (( ENABLE_SITE )); then
  pick_theme
  echo "Шаблон сайта: $SITE_THEME (другой: SELFSTEAL_THEME=$(IFS='|'; echo "${SITE_THEMES[*]}")|formats|random)"
fi

SHARED_DOMAIN=0
if (( ENABLE_SITE && ENABLE_HY2 )) && [[ "$SITE_DOMAIN" == "$HY2_DOMAIN" ]]; then
  SHARED_DOMAIN=1
  echo "REALITY self-steal и Hysteria2 используют $SITE_DOMAIN: будет один выпуск сертификата с отдельной копией для Hysteria2."
fi

configure_public_firewall

if ask_yes_no_default_yes "Настроить сеть под большой трафик (BBR, буферы TCP/UDP, лимиты)?"; then
  apply_network_tuning
fi

if (( ENABLE_SITE || ENABLE_HY2 )); then
  if ! command -v certbot >/dev/null || ! command -v dig >/dev/null || ! command -v python3 >/dev/null || { (( ENABLE_SITE )) && ! command -v nginx >/dev/null; }; then
    apt-get update
    packages=(certbot dnsutils)
    if (( ENABLE_SITE )); then packages+=(nginx); fi
    if ! command -v python3 >/dev/null; then packages+=(python3); fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  fi
  detect_node_ips
  valid_ipv4 "$NODE_IPV4" || die "Не удалось определить внешний IPv4 ноды. Укажите SELFSTEAL_PUBLIC_IP."
  setup_cloudflare
  if (( USE_CF )); then
    dns_names=""
    if (( ENABLE_SITE )); then point_dns "$SITE_DOMAIN"; dns_names="$SITE_DOMAIN"; fi
    if (( ENABLE_HY2 && ! SHARED_DOMAIN )); then point_dns "$HY2_DOMAIN"; dns_names="${dns_names:+$dns_names }$HY2_DOMAIN"; fi
    if ask_yes_no_default_yes "Следить за IP ноды и чинить DNS автоматически?"; then
      enable_dns_watch "$dns_names"
    fi
  fi
fi

if (( ENABLE_SITE )); then
  existing_domain=""
  if [[ -f "$REMNA_DIR/selfsteal/domain" ]]; then
    existing_domain="$(cat "$REMNA_DIR/selfsteal/domain")"
  fi
  [[ -z "$existing_domain" || "$existing_domain" == "$SITE_DOMAIN" ]] || die "Установлен другой домен self-steal: $existing_domain"
  # с Cloudflare запись только что выставлена через API: кеш резолверов здесь только мешал бы
  (( USE_CF )) || check_domain_dns "$SITE_DOMAIN"
fi

if (( ENABLE_HY2 && ! USE_CF )); then
  check_domain_dns "$HY2_DOMAIN"
fi

mkdir -p "$REMNA_DIR"

if (( ENABLE_SITE )); then
  install -d -m 755 "$REMNA_DIR/selfsteal" "$SITE_DIR" "$ACME_DIR"
  write_site
  tune_nginx_main
  if (( SHARED_DOMAIN )); then
    # Нельзя объявлять два server_name на одном порту 80 для одного домена.
    rm -f "$HY2_ACME_CONF"
  fi
  write_nginx_conf 0
  if (( ENABLE_HY2 && ! SHARED_DOMAIN )); then start_hy2_acme; fi
  if [[ -f "/etc/letsencrypt/live/$SITE_DOMAIN/fullchain.pem" ]]; then
    if [[ ! -f "/etc/letsencrypt/renewal/$SITE_DOMAIN.conf" ]] || ! grep -Eq '^authenticator[[:space:]]*=[[:space:]]*webroot$' "/etc/letsencrypt/renewal/$SITE_DOMAIN.conf"; then
      certbot renew --cert-name "$SITE_DOMAIN" --webroot --webroot-path "$ACME_DIR" --dry-run
      certbot renew --cert-name "$SITE_DOMAIN" --webroot --webroot-path "$ACME_DIR" --force-renewal
    fi
  else
    certbot certonly --webroot -w "$ACME_DIR" -d "$SITE_DOMAIN" --cert-name "$SITE_DOMAIN" --non-interactive --agree-tos -m "$CERT_EMAIL"
  fi
  write_nginx_conf 1
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
  if (( SHARED_DOMAIN )); then
    # Certbot уже выдал/нашёл сертификат в блоке ENABLE_SITE.
    # Второй сертификат НЕ запрашиваем, а копируем сертификат и ключ.
    copy_shared_hy2_cert
  elif [[ ! -f "/etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem" ]]; then
    if (( ENABLE_SITE )); then
      certbot certonly --webroot -w "$ACME_DIR" -d "$HY2_DOMAIN" --cert-name "$HY2_DOMAIN" --non-interactive --agree-tos -m "$CERT_EMAIL"
    else
      certbot certonly --standalone -d "$HY2_DOMAIN" --non-interactive --agree-tos -m "$CERT_EMAIL"
    fi
  fi
fi

if (( ENABLE_SITE || ENABLE_HY2 )); then
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  if (( SHARED_DOMAIN )); then
    # Certbot вызывает этот deploy-hook после успешного продления.
    # Имя начинается с 00-, чтобы копирование выполнялось раньше рестарта ноды.
    cat > "$SHARED_HY2_HOOK" <<EOF
#!/bin/sh
set -eu
[ "\${RENEWED_LINEAGE:-}" = "/etc/letsencrypt/live/$SITE_DOMAIN" ] || exit 0
install -d -m 700 "/etc/letsencrypt/hysteria2/$HY2_DOMAIN"
install -m 644 "/etc/letsencrypt/live/$SITE_DOMAIN/fullchain.pem" "/etc/letsencrypt/hysteria2/$HY2_DOMAIN/fullchain.pem"
install -m 600 "/etc/letsencrypt/live/$SITE_DOMAIN/privkey.pem" "/etc/letsencrypt/hysteria2/$HY2_DOMAIN/privkey.pem"
EOF
    chmod 700 "$SHARED_HY2_HOOK"
  else
    # Убираем ранее созданный хук при переключении на разные домены.
    rm -f "$SHARED_HY2_HOOK"
  fi
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
  echo "После настройки REALITY сайт будет доступен по адресу: https://$SITE_DOMAIN/ (шаблон $SITE_THEME)"
  echo "REALITY: target=127.0.0.1:$SITE_PORT, serverNames=[\"$SITE_DOMAIN\"], xver=0"
  echo "В Remnawave укажите этот домен в SNI клиентского профиля и target в конфигурации REALITY."
fi
if (( ENABLE_HY2 )); then
  if (( SHARED_DOMAIN )); then
    echo "Hysteria2: общий домен $HY2_DOMAIN, копия сертификата /etc/letsencrypt/hysteria2/$HY2_DOMAIN/fullchain.pem"
    echo "Hysteria2: приватный ключ /etc/letsencrypt/hysteria2/$HY2_DOMAIN/privkey.pem"
    echo "Сертификат Hysteria2 будет повторно копироваться при продлении Certbot."
    echo "Hysteria2: для ответа тем же сайтом по HTTP/3 добавьте в streamSettings.hysteriaSettings этого inbound:"
    cat <<EOF
"masquerade": {
  "type": "proxy",
  "url": "https://127.0.0.1:$SITE_PORT",
  "rewriteHost": false,
  "insecure": true
}
EOF
  else
    echo "Hysteria2: отдельный домен $HY2_DOMAIN, сертификат /etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem"
  fi
fi
