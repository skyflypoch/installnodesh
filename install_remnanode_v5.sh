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
  mapfile -t dns_ips < <(dig +short A "$domain" | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print}' | sort -u)
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

write_site() {
  local variant staged previous
  variant=$(( $(printf '%s' "$SITE_DOMAIN" | cksum | awk '{print $1}') % 6 ))
  staged="$(mktemp -d "$REMNA_DIR/selfsteal/.site-next.XXXXXX")"
  chmod 755 "$staged"
  (umask 022; SITE_DIR="$staged" SITE_DOMAIN="$SITE_DOMAIN" SITE_VARIANT="$variant" python3 - <<'PY'
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
    error_page 404 /404.html;
    location = /404.html { internal; }
    location / {
        try_files \$uri \$uri/ =404;
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

[[ $EUID -eq 0 ]] || die "Run as root"
if [[ "${1:-}" == "--refresh-site" ]]; then
  [[ $# -eq 1 ]] || die "Использование: $0 --refresh-site"
  [[ -f "$REMNA_DIR/selfsteal/domain" && -d "$SITE_DIR" && -f "$NGINX_CONF" ]] || die "Сайт self-steal ещё не установлен"
  SITE_DOMAIN="$(cat "$REMNA_DIR/selfsteal/domain")"
  validate_domain "$SITE_DOMAIN"
  write_site
  echo "Обновлена страница https://$SITE_DOMAIN/"
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

SHARED_DOMAIN=0
if (( ENABLE_SITE && ENABLE_HY2 )) && [[ "$SITE_DOMAIN" == "$HY2_DOMAIN" ]]; then
  SHARED_DOMAIN=1
  echo "REALITY self-steal и Hysteria2 используют $SITE_DOMAIN: будет один выпуск сертификата с отдельной копией для Hysteria2."
fi

configure_public_firewall

if (( ENABLE_SITE || ENABLE_HY2 )); then
  if ! command -v certbot >/dev/null || ! command -v dig >/dev/null || { (( ENABLE_SITE )) && { ! command -v nginx >/dev/null || ! command -v python3 >/dev/null; }; }; then
    apt-get update
    packages=(certbot dnsutils)
    if (( ENABLE_SITE )); then
      packages+=(nginx)
      if ! command -v python3 >/dev/null; then packages+=(python3); fi
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  fi
fi

if (( ENABLE_SITE )); then
  existing_domain=""
  if [[ -f "$REMNA_DIR/selfsteal/domain" ]]; then
    existing_domain="$(cat "$REMNA_DIR/selfsteal/domain")"
  fi
  [[ -z "$existing_domain" || "$existing_domain" == "$SITE_DOMAIN" ]] || die "Установлен другой домен self-steal: $existing_domain"
  check_domain_dns "$SITE_DOMAIN"
fi

if (( ENABLE_HY2 )); then
  check_domain_dns "$HY2_DOMAIN"
fi

mkdir -p "$REMNA_DIR"

if (( ENABLE_SITE )); then
  install -d -m 755 "$REMNA_DIR/selfsteal" "$SITE_DIR" "$ACME_DIR"
  write_site
  if (( SHARED_DOMAIN )); then
    # Нельзя объявлять два server_name на одном порту 80 для одного домена.
    rm -f "$HY2_ACME_CONF"
  fi
  start_http_site
  if (( ENABLE_HY2 && ! SHARED_DOMAIN )); then start_hy2_acme; fi
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
  echo "После настройки REALITY сайт будет доступен по адресу: https://$SITE_DOMAIN/"
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
