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
  SITE_DIR="$SITE_DIR" SITE_DOMAIN="$SITE_DOMAIN" SITE_VARIANT="$variant" SITE_ZONE="$zone" SITE_OTHER_ZONE="$other_zone" python3 - <<'PY'
from pathlib import Path
from html import escape
import os
import textwrap

root = Path(os.environ["SITE_DIR"])
domain = os.environ["SITE_DOMAIN"]
variant = int(os.environ["SITE_VARIANT"])
primary_zone = os.environ["SITE_ZONE"]
secondary_zone = os.environ["SITE_OTHER_ZONE"]
palettes = [
    ("#245f59", "#eef3f1", "#183531", "#59736d"),
    ("#345d86", "#eef2f7", "#1d3349", "#61778b"),
    ("#6c6030", "#f3f3ec", "#373627", "#77755e"),
    ("#87554b", "#f5f0ee", "#402d2b", "#866d68"),
    ("#28677c", "#edf3f5", "#1e3740", "#5e7982"),
    ("#5e5883", "#f2f1f6", "#333047", "#747085"),
]
accent, background, ink, muted = palettes[variant]
zones = [
    ("Europe/Berlin", "Berlin"), ("Europe/London", "London"),
    ("Europe/Amsterdam", "Amsterdam"), ("Europe/Helsinki", "Helsinki"),
    ("Europe/Tallinn", "Tallinn"), ("Europe/Warsaw", "Warsaw"),
    ("Europe/Vienna", "Vienna"), ("Asia/Dubai", "Dubai"),
    ("Asia/Hong_Kong", "Hong Kong"), ("Asia/Singapore", "Singapore"),
    ("Asia/Tokyo", "Tokyo"), ("America/New_York", "New York"),
    ("America/Toronto", "Toronto"), ("America/Los_Angeles", "Los Angeles"),
]
zone_names = dict(zones)
lead_city = zone_names.get(primary_zone, "Berlin")
other_city = zone_names.get(secondary_zone, "London")
taglines = [
    "A clearer way to work across time zones.",
    "Keep the same moment in view.",
    "Time is local. The moment is shared.",
    "Find a better hour for everyone.",
    "Across cities, on the same page.",
    "Make room for the right time.",
]
root.mkdir(parents=True, exist_ok=True)
(root / "assets").mkdir(exist_ok=True)

css = r'''
:root{color-scheme:light;--accent:ACCENT;--bg:BACKGROUND;--ink:INK;--muted:MUTED;--line:#d7dfdc;--paper:#fff;--dark:#19322f}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{margin:0;background:var(--bg);color:var(--ink);font-family:"Avenir Next","Segoe UI",Arial,sans-serif;-webkit-font-smoothing:antialiased}
a{color:inherit}
button,input,select{font:inherit}
button{cursor:pointer}
.site{max-width:1180px;margin:auto;padding:0 36px}
.skip{position:absolute;left:-9999px;top:8px;padding:10px;background:#fff;z-index:100}
.skip:focus{left:10px}
.topbar{min-height:82px;display:flex;align-items:center;justify-content:space-between;gap:24px;border-bottom:1px solid var(--line)}
.brand{font-size:25px;font-weight:800;letter-spacing:-.075em;text-decoration:none;white-space:nowrap;display:inline-flex;align-items:center;gap:10px}
.brand i{width:13px;height:13px;border:3px solid var(--accent);border-radius:50%;display:block}
.nav{display:flex;align-items:center;gap:25px;font-size:14px;font-weight:650}
.nav a{text-decoration:none;color:var(--muted);white-space:nowrap}
.nav a:hover,.nav a[aria-current=page]{color:var(--ink)}
.nav a[aria-current=page]{box-shadow:0 2px var(--accent)}
.hero{padding:78px 0 72px;display:grid;grid-template-columns:1.08fr .92fr;gap:8%;align-items:center}
.eyebrow{display:block;color:var(--accent);font-size:12px;font-weight:800;letter-spacing:.15em;text-transform:uppercase;margin-bottom:19px}
h1{font-size:clamp(46px,6.6vw,84px);line-height:1.03;letter-spacing:-.075em;margin:0 0 24px;font-weight:680}
h2{font-size:clamp(29px,3.5vw,44px);line-height:1.12;letter-spacing:-.055em;margin:0 0 18px;font-weight:680}
h3{font-size:21px;line-height:1.25;letter-spacing:-.03em;margin:0 0 12px}
p{line-height:1.67;margin:0 0 18px}
.hero p,.page-intro p{font-size:18px;max-width:620px;color:var(--muted)}
.actions{display:flex;gap:12px;flex-wrap:wrap;margin-top:30px}
.btn{display:inline-flex;align-items:center;justify-content:center;min-height:46px;padding:0 18px;border-radius:10px;border:1px solid var(--accent);background:var(--accent);color:#fff;text-decoration:none;font-weight:700;font-size:14px}
.btn.alt{background:transparent;color:var(--ink);border-color:#bfcfca}
.btn:hover{filter:brightness(.95)}
.clock-panel{background:var(--ink);color:#fff;border-radius:22px;padding:32px;min-height:350px;display:flex;flex-direction:column;justify-content:space-between}
.clock-panel .micro{font-size:13px;color:#bbd0ca}
.clock-panel strong{font-size:clamp(64px,7vw,102px);font-weight:600;letter-spacing:-.08em;line-height:1;font-variant-numeric:tabular-nums;display:block;margin:24px 0 10px}
.clock-panel p{color:#e2ece9;font-size:17px;margin:0}
.clock-panel .panel-foot{border-top:1px solid #49625b;padding-top:18px;display:flex;justify-content:space-between;gap:14px;font-size:13px;color:#c6d7d1}
.section{padding:65px 0;border-top:1px solid var(--line)}
.section-head{display:flex;justify-content:space-between;gap:32px;align-items:end;margin-bottom:28px}
.section-head p{max-width:420px;color:var(--muted)}
.link{color:var(--accent);font-weight:750;text-decoration:none}
.link:hover{text-decoration:underline}
.tool-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}
.tool-card{background:var(--paper);border:1px solid var(--line);border-radius:15px;min-height:210px;padding:27px;display:flex;flex-direction:column;text-decoration:none;transition:transform .15s,border-color .15s}
.tool-card:hover{transform:translateY(-3px);border-color:var(--accent)}
.tool-card .num{font-size:13px;color:var(--accent);font-weight:800;margin-bottom:38px}
.tool-card p{color:var(--muted);font-size:14px;margin:0}
.tool-card .arr{margin-top:auto;padding-top:18px;color:var(--accent);font-weight:700}
.band{background:var(--ink);color:#fff;border-radius:18px;padding:37px;display:grid;grid-template-columns:1fr auto;gap:25px;align-items:center}
.band p{color:#c6d7d1;margin:0}
.band .btn{background:#fff;color:var(--ink);border-color:#fff}
.page-intro{padding:66px 0 44px;max-width:770px}
.page-intro h1{font-size:clamp(42px,5.8vw,72px)}
.breadcrumbs{font-size:13px;color:var(--muted);margin-bottom:24px}
.breadcrumbs a{text-decoration:none}
.breadcrumbs a:hover{text-decoration:underline}
.workspace{display:grid;grid-template-columns:1.05fr .95fr;gap:18px;padding-bottom:65px}
.panel{background:#fff;border:1px solid var(--line);border-radius:18px;padding:30px}
.panel.dark{background:var(--ink);color:#fff;border-color:var(--ink)}
.panel.dark p,.panel.dark .small{color:#c7d9d2}
.field-grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}
.field{display:flex;flex-direction:column;gap:9px;margin-bottom:19px}
.field label{font-size:14px;font-weight:700}
.field input,.field select{min-height:50px;width:100%;border:1px solid #bdccc7;border-radius:9px;background:#fff;color:#19322f;padding:0 13px}
.field input:focus-visible,.field select:focus-visible,button:focus-visible,a:focus-visible{outline:3px solid var(--accent);outline-offset:3px}
.result-number{display:block;font-size:clamp(58px,7vw,98px);font-weight:600;line-height:1.1;letter-spacing:-.08em;font-variant-numeric:tabular-nums;margin:30px 0 12px}
.small{font-size:14px;color:var(--muted)}
.feedback{min-height:22px;font-size:14px;color:var(--muted)}
.feedback.error{color:#b13c36}
.list{display:grid;grid-template-columns:repeat(2,1fr);gap:14px;margin:0 0 65px}
.list a{display:block;background:#fff;border:1px solid var(--line);border-radius:12px;padding:22px;text-decoration:none}
.list a:hover{border-color:var(--accent)}
.list a strong{display:block;font-size:19px;letter-spacing:-.03em;margin-bottom:8px}
.list a span{display:block;font-size:14px;color:var(--muted);line-height:1.5}
.prose{max-width:760px;padding-bottom:75px}
.prose h2{font-size:30px;margin:48px 0 15px}
.prose h3{margin:28px 0 12px}
.prose p,.prose li{font-size:17px;line-height:1.72;color:#425c55}
.prose ul,.prose ol{padding-left:23px}
.prose li{margin:10px 0}
.prose aside{background:#fff;border-left:4px solid var(--accent);padding:22px 25px;margin:31px 0}
.prose aside p{margin:0}
.facts{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin:20px 0 60px}
.fact{border-top:2px solid var(--accent);padding:17px 0}
.fact strong{display:block;font-size:21px;margin-bottom:8px}
.fact span{color:var(--muted);font-size:14px;line-height:1.5}
.clock-list{display:grid;grid-template-columns:repeat(2,1fr);gap:14px;padding-bottom:65px}
.clock-row{background:#fff;border:1px solid var(--line);border-radius:12px;padding:22px;display:flex;align-items:center;justify-content:space-between;gap:20px}
.clock-row span{display:block;font-size:14px;color:var(--muted);margin-top:4px}
.clock-row time{font-size:34px;letter-spacing:-.06em;font-variant-numeric:tabular-nums}
.meeting-list{display:grid;gap:7px;max-height:560px;overflow:auto}
.meeting-row{display:grid;grid-template-columns:1fr 1fr auto;gap:12px;align-items:center;padding:10px 12px;border-radius:8px;background:#f4f7f5;font-size:14px}
.meeting-row.good{background:#e1efe8}
.meeting-row em{font-style:normal;font-size:12px;color:#527465}
.footer{border-top:1px solid var(--line);padding:32px 0 38px;display:flex;justify-content:space-between;gap:30px;color:var(--muted);font-size:13px}
.footer-links{display:flex;gap:18px;flex-wrap:wrap}
.footer a{text-decoration:none}
.footer a:hover{text-decoration:underline}
@media(max-width:800px){.site{padding:0 22px}.topbar{align-items:flex-start;flex-direction:column;justify-content:center;padding:19px 0;gap:16px}.nav{max-width:100%;overflow:auto;padding-bottom:5px}.hero{grid-template-columns:1fr;gap:30px;padding:57px 0}.clock-panel{min-height:300px}.tool-grid{grid-template-columns:1fr 1fr}.workspace{grid-template-columns:1fr}.section-head{display:block}.section-head p{margin:0}.facts{grid-template-columns:1fr 1fr}}
@media(max-width:560px){.site{padding:0 18px}.nav{gap:17px;font-size:13px}.hero h1{font-size:51px}.hero p,.page-intro p{font-size:16px}.page-intro{padding:48px 0 31px}.tool-grid,.list,.clock-list,.facts,.field-grid{grid-template-columns:1fr}.tool-card{min-height:180px}.band{grid-template-columns:1fr}.panel{padding:23px}.footer{flex-direction:column}.clock-row time{font-size:28px}.meeting-row{grid-template-columns:1fr 1fr}.meeting-row em{grid-column:1/-1}}
'''
for key, value in {"ACCENT":accent,"BACKGROUND":background,"INK":ink,"MUTED":muted}.items():
    css = css.replace(key, value)
(root / "assets/site.css").write_text(css.strip() + "\n")

js = r'''
"use strict";
const places=[["Europe/Berlin","Berlin"],["Europe/London","London"],["Europe/Amsterdam","Amsterdam"],["Europe/Helsinki","Helsinki"],["Europe/Tallinn","Tallinn"],["Europe/Warsaw","Warsaw"],["Europe/Vienna","Vienna"],["Asia/Dubai","Dubai"],["Asia/Hong_Kong","Hong Kong"],["Asia/Singapore","Singapore"],["Asia/Tokyo","Tokyo"],["America/New_York","New York"],["America/Toronto","Toronto"],["America/Los_Angeles","Los Angeles"]];
const labels=Object.fromEntries(places);
const clock=(date,zone)=>new Intl.DateTimeFormat("en-GB",{timeZone:zone,hour:"2-digit",minute:"2-digit",hourCycle:"h23"}).format(date);
const day=(date,zone)=>new Intl.DateTimeFormat("en-GB",{timeZone:zone,weekday:"long",day:"numeric",month:"long",year:"numeric"}).format(date);
const isWeekday=(date,zone)=>!["Sat","Sun"].includes(new Intl.DateTimeFormat("en-US",{timeZone:zone,weekday:"short"}).format(date));
function parts(date,zone){const out={};for(const p of new Intl.DateTimeFormat("en-GB",{timeZone:zone,year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",hourCycle:"h23"}).formatToParts(date)){if(p.type!=="literal")out[p.type]=Number(p.value);}return out;}
function wall(date,zone){const p=parts(date,zone);return [String(p.year).padStart(4,"0"),String(p.month).padStart(2,"0"),String(p.day).padStart(2,"0")].join("-")+"T"+String(p.hour).padStart(2,"0")+":"+String(p.minute).padStart(2,"0");}
function instant(value,zone){const m=/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(value);if(!m)return null;const target=Date.UTC(+m[1],+m[2]-1,+m[3],+m[4],+m[5]);let ms=target;for(let i=0;i<4;i++){const p=parts(new Date(ms),zone);const delta=target-Date.UTC(p.year,p.month-1,p.day,p.hour,p.minute);ms+=delta;if(delta===0)break;}const result=new Date(ms);return wall(result,zone)===value?result:null;}
function fillZones(select,initial){for(const [zone,name] of places)select.add(new Option(name,zone));select.value=labels[initial]?initial:places[0][0];}
function live(){for(const el of document.querySelectorAll("[data-clock]")){const zone=el.dataset.clock;el.textContent=clock(new Date(),zone);}for(const el of document.querySelectorAll("[data-date]")){el.textContent=day(new Date(),el.dataset.date);}}
live();setInterval(live,30000);
const converter=document.getElementById("converter");
if(converter){const from=document.getElementById("from-zone"),to=document.getElementById("to-zone"),input=document.getElementById("from-time"),result=document.getElementById("result-time"),resultDate=document.getElementById("result-date"),feedback=document.getElementById("feedback");fillZones(from,converter.dataset.from);fillZones(to,converter.dataset.to);input.value=wall(new Date(),from.value);let previous=from.value;function render(){const date=instant(input.value,from.value);if(!date){result.textContent="--:--";resultDate.textContent="Choose another local time.";feedback.textContent="This time may be invalid because local clocks changed.";feedback.classList.add("error");return;}result.textContent=clock(date,to.value);resultDate.textContent=day(date,to.value)+" in "+labels[to.value];feedback.textContent="";feedback.classList.remove("error");}from.addEventListener("change",()=>{const date=instant(input.value,previous);previous=from.value;if(date)input.value=wall(date,from.value);render();});to.addEventListener("change",render);input.addEventListener("input",render);document.getElementById("now-button").addEventListener("click",()=>{input.value=wall(new Date(),from.value);render();});document.getElementById("swap-button").addEventListener("click",()=>{const date=instant(input.value,from.value);const old=from.value;from.value=to.value;to.value=old;previous=from.value;if(date)input.value=wall(date,from.value);render();});document.getElementById("copy-button").addEventListener("click",async()=>{const date=instant(input.value,from.value);if(!date)return;try{await navigator.clipboard.writeText(clock(date,to.value)+" "+day(date,to.value)+" in "+labels[to.value]);feedback.textContent="Copied to clipboard.";feedback.classList.remove("error");}catch{feedback.textContent="Clipboard access is unavailable.";feedback.classList.add("error");}});render();}
const meeting=document.getElementById("meeting-planner");
if(meeting){const from=document.getElementById("meeting-from"),to=document.getElementById("meeting-to"),input=document.getElementById("meeting-date"),list=document.getElementById("meeting-list"),feedback=document.getElementById("meeting-feedback");fillZones(from,meeting.dataset.from);fillZones(to,meeting.dataset.to);input.value=wall(new Date(),from.value).slice(0,10);function render(){list.replaceChildren();if(!input.value){feedback.textContent="Choose a date.";return;}let count=0;for(let hour=7;hour<=21;hour++){const date=instant(input.value+"T"+String(hour).padStart(2,"0")+":00",from.value);if(!date)continue;const local=parts(date,to.value);const good=hour>=9&&hour<18&&local.hour>=9&&local.hour<18&&isWeekday(date,from.value)&&isWeekday(date,to.value);const row=document.createElement("div");row.className="meeting-row"+(good?" good":"");const a=document.createElement("span"),b=document.createElement("span"),c=document.createElement("em");a.textContent=String(hour).padStart(2,"0")+":00 "+labels[from.value];b.textContent=clock(date,to.value)+" "+labels[to.value];c.textContent=good?"Both in working hours":day(date,to.value).split(",")[0];row.append(a,b,c);list.append(row);if(good)count++;}feedback.textContent=count?count+" shared weekday working-hour slots shown in green.":"No shared weekday 09:00–18:00 slots on this date.";};from.addEventListener("change",render);to.addEventListener("change",render);input.addEventListener("input",render);render();}
const gap=document.getElementById("date-gap");
if(gap){const a=document.getElementById("date-a"),b=document.getElementById("date-b"),out=document.getElementById("gap-result"),caption=document.getElementById("gap-caption");const today=new Date();a.value=today.toISOString().slice(0,10);b.value=new Date(today.getTime()+7*86400000).toISOString().slice(0,10);function utc(value){const m=/^(\d{4})-(\d{2})-(\d{2})$/.exec(value);return m?Date.UTC(+m[1],+m[2]-1,+m[3]):null;}function render(){const x=utc(a.value),y=utc(b.value);if(x===null||y===null){out.textContent="—";caption.textContent="Select two valid dates.";return;}const days=Math.round(Math.abs(y-x)/86400000);out.textContent=String(days);caption.textContent=days===1?"calendar day between the dates":"calendar days between the dates";}a.addEventListener("input",render);b.addEventListener("input",render);render();}
'''
(root / "assets/site.js").write_text(js.strip() + "\n")

def page(path, title, description, main, nav=""):
    current = lambda name: ' aria-current="page"' if nav == name else ""
    header = f'''<a class="skip" href="#main">Skip to content</a><div class="site"><header class="topbar"><a class="brand" href="/">clockline<i aria-hidden="true"></i></a><nav class="nav" aria-label="Main navigation"><a href="/convert/"{current("convert")}>Converter</a><a href="/meeting/"{current("meeting")}>Meeting planner</a><a href="/world-clock/"{current("world")}>World clock</a><a href="/guides/"{current("guides")}>Guides</a><a href="/cities/"{current("cities")}>Cities</a></nav></header><main id="main">{main}</main><footer class="footer"><span>Clockline · Practical time tools for everyday planning</span><div class="footer-links"><a href="/about/">About</a><a href="/privacy/">Privacy</a><span>{escape(domain)}</span></div></footer></div>'''
    html = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="theme-color" content="{background}"><meta name="description" content="{escape(description, quote=True)}"><link rel="icon" href="/assets/favicon.svg" type="image/svg+xml"><link rel="manifest" href="/site.webmanifest"><link rel="stylesheet" href="/assets/site.css"><title>{escape(title)} — Clockline</title></head><body>{header}<script defer src="/assets/site.js"></script></body></html>'''
    dest = root / path
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(html + "\n")
    return "/" + (str(Path(path).parent) + "/" if path != "index.html" else "")

crumb = lambda label: f'<div class="breadcrumbs"><a href="/">Home</a> / {escape(label)}</div>'
intro = lambda label, title, text: f'<div class="page-intro">{crumb(label)}<span class="eyebrow">{escape(label)}</span><h1>{escape(title)}</h1><p>{escape(text)}</p></div>'
tools = [
    ("/convert/", "01", "Time zone converter", "Translate a local date and time into another city."),
    ("/meeting/", "02", "Meeting planner", "Scan the hours two cities have in common."),
    ("/world-clock/", "03", "World clock", "See the current time and date across cities."),
    ("/date-gap/", "04", "Date gap", "Count calendar days between two dates."),
]
tool_cards = ''.join(f'<a class="tool-card" href="{u}"><span class="num">{n} / TOOL</span><h3>{t}</h3><p>{d}</p><span class="arr">Open tool →</span></a>' for u,n,t,d in tools[:3])
home = f'''<section class="hero"><div><span class="eyebrow">Clockline / Time tools</span><h1>{taglines[variant]}</h1><p>Compare local times, find a meeting hour and understand the dates behind the clock. Built for people who work, travel or talk across cities.</p><div class="actions"><a class="btn" href="/convert/">Convert a time</a><a class="btn alt" href="/guides/">Read the guides</a></div></div><div class="clock-panel"><div><span class="micro">LOCAL TIME · {escape(lead_city.upper())}</span><strong data-clock="{escape(primary_zone)}">--:--</strong><p data-date="{escape(primary_zone)}">Loading local date</p></div><div class="panel-foot"><span>Same moment in {escape(other_city)}</span><span data-clock="{escape(secondary_zone)}">--:--</span></div></div></section><section class="section"><div class="section-head"><div><span class="eyebrow">Choose a task</span><h2>Start with the time you know.</h2></div><p>Each tool works directly in your browser. No account or setup is needed.</p></div><div class="tool-grid">{tool_cards}</div><p style="margin-top:22px"><a class="link" href="/date-gap/">Count days between dates →</a></p></section><section class="section"><div class="band"><div><span class="eyebrow" style="color:#bfd6cf">A useful reference</span><h2>Clocks change. Your plans can keep up.</h2><p>Read how offsets, summer time and local dates affect calls and deadlines.</p></div><a class="btn" href="/guides/">Explore the guides</a></div></section>'''
page("index.html", "Time tools for cities and dates", "Convert time zones, plan meetings, view world clocks and read practical guides.", home)

convert = f'''{intro("Converter","Convert a time between cities","Enter a date and time where you are, then see the same moment in another city. Seasonal clock changes are handled by your browser's time-zone data.")}<section class="workspace" id="converter" data-from="{escape(primary_zone)}" data-to="{escape(secondary_zone)}"><div class="panel"><div class="field-grid"><div class="field"><label for="from-zone">From</label><select id="from-zone"></select></div><div class="field"><label for="to-zone">To</label><select id="to-zone"></select></div></div><div class="field"><label for="from-time">Local date and time</label><input id="from-time" type="datetime-local"></div><div class="actions"><button class="btn" id="now-button" type="button">Use current time</button><button class="btn alt" id="swap-button" type="button">Swap cities</button></div><p class="feedback" id="feedback" role="status" aria-live="polite"></p></div><div class="panel dark"><span class="small">THE SAME MOMENT</span><strong class="result-number" id="result-time">--:--</strong><p id="result-date">Choose a time</p><button class="btn alt" id="copy-button" type="button" style="color:#fff;border-color:#91aba2">Copy result</button></div></section><section class="section"><h2>Why the date can change</h2><p class="small">When two cities are far apart, a late evening in one can be the next morning in another. Check the full date before you book a call or set a deadline.</p><a class="link" href="/guides/utc-offsets/">How time-zone offsets work →</a></section>'''
page("convert/index.html","Time zone converter","Convert a local time between cities with automatic seasonal time-zone rules.",convert,"convert")

meeting = f'''{intro("Meeting planner","Find an hour that works in both cities","Compare a full day in two places. Green rows show weekday hours between 09:00 and 18:00 in both cities; check the date as well as the clock.")}<section class="workspace" id="meeting-planner" data-from="{escape(primary_zone)}" data-to="{escape(secondary_zone)}"><div class="panel"><div class="field-grid"><div class="field"><label for="meeting-from">First city</label><select id="meeting-from"></select></div><div class="field"><label for="meeting-to">Second city</label><select id="meeting-to"></select></div></div><div class="field"><label for="meeting-date">Date in the first city</label><input id="meeting-date" type="date"></div><p class="small">Working hours are a planning aid. Confirm availability and local holidays with the people involved.</p><p class="feedback" id="meeting-feedback" role="status" aria-live="polite"></p></div><div class="panel"><h3>Hour by hour</h3><div class="meeting-list" id="meeting-list"></div></div></section><section class="section"><h2>Before sending the invite</h2><p class="small">Include both the time zone and the calendar date. Around seasonal clock changes, an hour that worked last month may be different today.</p><a class="link" href="/guides/remote-meetings/">Read the meeting checklist →</a></section>'''
page("meeting/index.html","Meeting planner","Compare two cities hour by hour and find shared working hours.",meeting,"meeting")

world_cities = [primary_zone,secondary_zone,"Europe/London","Europe/Warsaw","Asia/Dubai","Asia/Tokyo","America/New_York","America/Los_Angeles"]
world_cities = list(dict.fromkeys(world_cities))
world_rows = ''.join(f'<div class="clock-row"><div><strong>{escape(zone_names[z])}</strong><span data-date="{escape(z)}">Loading date</span></div><time data-clock="{escape(z)}">--:--</time></div>' for z in world_cities)
world = f'''{intro("World clock","The moment, around the world","These clocks update every 30 seconds. Each city shows its local date, which may differ from yours.")}<div class="clock-list">{world_rows}</div><section class="section"><h2>Need a particular hour?</h2><p class="small">Use the converter to translate a future date and time. The clocks above show only the current moment.</p><a class="link" href="/convert/">Open the converter →</a></section>'''
page("world-clock/index.html","World clock","Live local times and dates in cities around the world.",world,"world")

gap = f'''{intro("Date gap","Count the days between dates","Choose a start and end date. The result counts calendar-day boundaries and is unaffected by daylight saving time.")}<section class="workspace" id="date-gap"><div class="panel"><div class="field-grid"><div class="field"><label for="date-a">First date</label><input id="date-a" type="date"></div><div class="field"><label for="date-b">Second date</label><input id="date-b" type="date"></div></div><p class="small">The count excludes the starting day. For example, Monday to Tuesday is one day.</p></div><div class="panel dark"><span class="small">DATE DIFFERENCE</span><strong class="result-number" id="gap-result">—</strong><p id="gap-caption">calendar days between the dates</p></div></section><section class="section"><h2>Calendar days and elapsed hours</h2><p class="small">A calendar-day count is useful for scheduling. It is not always the same as dividing elapsed hours by 24 when clocks move forward or back.</p><a class="link" href="/guides/daylight-saving/">Understand clock changes →</a></section>'''
page("date-gap/index.html","Date gap calculator","Count calendar days between two dates without daylight-saving surprises.",gap)

guides = [
    ("daylight-saving","What changes when clocks change","How seasonal time changes affect calls, dates and recurring events."),
    ("utc-offsets","UTC offsets, without the jargon","Understand why an offset is a snapshot, not a permanent city rule."),
    ("remote-meetings","A short checklist for remote meetings","Pick an hour, share the right date and avoid calendar surprises."),
]
guide_links = ''.join(f'<a href="/guides/{slug}/"><strong>{title}</strong><span>{desc}</span></a>' for slug,title,desc in guides)
page("guides/index.html","Guides to time zones and dates","Clear, practical guides to UTC offsets, seasonal clock changes and remote meetings.",intro("Guides","Understand the clock behind the calendar","Short explanations for the questions that come up when people plan across cities.")+f'<div class="list">{guide_links}</div>',"guides")
articles = {
"daylight-saving":(
"What changes when clocks change",
"Seasonal clock changes are local rules. Two cities can change on different dates, and some places do not change at all.",
'''<h2>Why a familiar hour can move</h2><p>A city may move its clocks forward or back during the year. That changes its offset from UTC, and therefore the hour shown in another city at the same moment. The date of the change is set locally and can differ between countries.</p><h2>Two tricky local times</h2><p>When clocks move forward, part of the local morning may never occur. When they move back, an hour can occur twice. If a time falls in either window, ask for the date and the time zone, or share a calendar invitation with a defined zone.</p><aside><p>Clockline uses the time-zone information available in your browser. Rules can change, so confirm critical travel or operational schedules with an authoritative local source.</p></aside><h2>For recurring meetings</h2><p>A meeting fixed to one city's local hour can shift for people elsewhere. Review recurring invites shortly before seasonal changes, especially when participants are in countries with different change dates.</p>'''),
"utc-offsets":(
"UTC offsets, without the jargon",
"An offset tells you how far a local clock sits from UTC at one moment. A named time zone also carries the rules for other dates.",
'''<h2>An offset describes one instant</h2><p>UTC+02:00 means a local clock is two hours ahead of Coordinated Universal Time at that moment. It does not tell you whether the same city will use UTC+02:00 all year.</p><h2>Use a city zone for future dates</h2><p>A named zone such as Europe/Berlin includes historical and seasonal rules. When planning for a future date, choose the city or its time zone instead of typing a fixed offset from memory.</p><h2>Check the local date</h2><p>A time-zone conversion may cross midnight. Include the weekday and date when you send a deadline or meeting time. “09:00 Tuesday in Tokyo” is clearer than “09:00” alone.</p><aside><p>For a future event, use the converter with the event's date. Today's offset may not apply then.</p></aside>'''),
"remote-meetings":(
"A short checklist for remote meetings",
"Small details prevent most scheduling mistakes when a call crosses time zones.",
'''<h2>Start with a date</h2><p>Choose the day in one city first. Then compare the same moment in each participant's city. The second local date might be different.</p><h2>Look for a shared window</h2><p>The meeting planner marks hours from 09:00 to 18:00 in both places. Treat that as a starting point; working patterns, breaks and holidays are personal.</p><h2>Send a calendar invitation</h2><p>Set a named time zone in the invitation. Write the date, time and city in the accompanying message so people can spot an unexpected conversion.</p><h2>Check again near a clock change</h2><p>For recurring meetings, compare the cities after seasonal time changes. A fixed local hour in one place can shift for everyone else.</p>''')
}
for slug,(title,summary,body) in articles.items():
    main = intro("Guides",title,summary)+f'<article class="prose">{body}<p><a class="link" href="/guides/">← All guides</a></p></article>'
    page(f"guides/{slug}/index.html",title,summary,main,"guides")

city_data = [
    ("berlin","Europe/Berlin","Berlin","Germany","Berlin follows Central European local time, with seasonal clock changes. A fixed offset is therefore not a reliable way to describe every future date.","Europe/London","London"),
    ("warsaw","Europe/Warsaw","Warsaw","Poland","Warsaw uses the same regional clock pattern as many central European cities. Check the date when comparing it with places outside Europe.","Asia/Tokyo","Tokyo"),
    ("london","Europe/London","London","United Kingdom","London's local clock changes seasonally. Its relationship to another city can shift when that city changes clocks on a different day.","America/New_York","New York"),
    ("new-york","America/New_York","New York","United States","New York observes seasonal clock changes. The gap to European cities can briefly differ around changeover dates.","Europe/London","London"),
    ("tokyo","Asia/Tokyo","Tokyo","Japan","Tokyo keeps the same local clock through the year. The difference from cities with seasonal clock changes still varies.","Europe/Warsaw","Warsaw"),
    ("dubai","Asia/Dubai","Dubai","United Arab Emirates","Dubai keeps the same local clock through the year. Compare it by date with cities whose clocks change seasonally.","Europe/London","London"),
]
city_links = ''.join(f'<a href="/cities/{slug}/"><strong>{name}</strong><span>{country} · View local time and planning notes</span></a>' for slug,zone,name,country,summary,other,other_name in city_data)
page("cities/index.html","City time guides","Local clocks and practical planning notes for six cities.",intro("Cities","A closer look at local time","Open a city to see its current local time and the details that matter when planning across places.")+f'<div class="list">{city_links}</div>',"cities")
for slug,zone,name,country,summary,other,other_name in city_data:
    main = intro("Cities",f"Time in {name}",summary)+f'''<section class="workspace"><div class="panel dark"><span class="small">{escape(country.upper())} / LOCAL TIME</span><strong class="result-number" data-clock="{escape(zone)}">--:--</strong><p data-date="{escape(zone)}">Loading local date</p></div><div class="panel"><h3>Compare with {escape(other_name)}</h3><p>The same moment is currently <strong data-clock="{escape(other)}">--:--</strong> in {escape(other_name)}.</p><p class="small">For a future date, use the converter. Seasonal rules may change the difference between the cities.</p><a class="btn" href="/convert/">Convert a time</a></div></section><section class="section"><h2>Planning notes</h2><div class="facts"><div class="fact"><strong>Check the date</strong><span>One city may already be on the next calendar day.</span></div><div class="fact"><strong>Use a named zone</strong><span>It is more reliable for future events than a fixed UTC offset.</span></div><div class="fact"><strong>Confirm availability</strong><span>Local working hours and holidays vary by person and place.</span></div></div><a class="link" href="/cities/">← All cities</a></section>'''
    page(f"cities/{slug}/index.html",f"Time in {name}",f"Current local time in {name} and practical time-zone planning notes.",main,"cities")

about = intro("About","Time tools that get to the point","Clockline is a small collection of browser-based tools for converting times, comparing cities and counting dates.")+'''<article class="prose"><h2>What you can do here</h2><p>Convert a future local time, compare two cities hour by hour, check current clocks and count calendar days. The guides explain where time-zone conversions tend to go wrong.</p><h2>How the clocks work</h2><p>The interactive tools use your browser's built-in international time-zone data. Clockline does not operate a time service or publish its own time-zone rules. If a local rule changes recently, your browser may need an update.</p><p><a class="link" href="/convert/">Open the converter →</a></p></article>'''
page("about/index.html","About","About Clockline's browser-based time and date tools.",about)
privacy = intro("Privacy","A simple site with local tools","Clockline's interactive calculations run in your browser.")+'''<article class="prose"><h2>Information you enter</h2><p>Dates, times and city choices are processed in your browser to show a result. The site does not ask for an account or send those inputs to a Clockline application server.</p><h2>Site delivery</h2><p>Like other websites, the web server delivering these pages may record request details such as an IP address and requested path in its access logs. The retention of those logs depends on the server operator.</p><h2>Third-party content</h2><p>The site loads its styles and scripts from the same domain. It has no embedded third-party analytics or advertising in these pages.</p></article>'''
page("privacy/index.html","Privacy","How Clockline handles browser calculations and site delivery.",privacy)
page("404.html","Page not found","The requested Clockline page could not be found.",intro("404","That page is not here","The address may have changed, or there may be a typo.")+'<div class="actions" style="padding-bottom:80px"><a class="btn" href="/">Back to the home page</a><a class="btn alt" href="/guides/">Browse the guides</a></div>')

(root / "assets/favicon.svg").write_text(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="{ink}"/><circle cx="32" cy="32" r="17" fill="none" stroke="{background}" stroke-width="5"/><path d="M32 20v13l9 7" fill="none" stroke="{accent}" stroke-width="5" stroke-linecap="round"/></svg>\n')
(root / "robots.txt").write_text("User-agent: *\nAllow: /\nSitemap: https://" + domain + "/sitemap.xml\n")
paths = ["/","/convert/","/meeting/","/world-clock/","/date-gap/","/guides/"] + ["/guides/"+s+"/" for s,_,_ in guides] + ["/cities/"] + ["/cities/"+c[0]+"/" for c in city_data] + ["/about/","/privacy/"]
(root / "sitemap.xml").write_text('<?xml version="1.0" encoding="utf-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + ''.join('<url><loc>https://'+domain+p+'</loc></url>' for p in paths) + '</urlset>\n')
(root / "site.webmanifest").write_text('{"name":"Clockline","short_name":"Clockline","start_url":"/","display":"browser","background_color":"'+background+'","theme_color":"'+background+'","icons":[{"src":"/assets/favicon.svg","sizes":"any","type":"image/svg+xml"}]}\n')
print(f"Clockline: wrote {len(list(root.rglob('*')))} files and directories for {domain}")
PY
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
  else
    echo "Hysteria2: отдельный домен $HY2_DOMAIN, сертификат /etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem"
  fi
fi