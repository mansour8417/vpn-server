#!/usr/bin/env bash
#
# Xray VLESS + XTLS-Vision + REALITY  —  one-shot installer
# Target: Ubuntu 22.04+ (incl. 26.04) or Debian 12+, run as root.
# Works on a rented VPS or a machine at home behind a port-forward.
#
#   bash install.sh                     # auto-pick SNI, port 443
#   bash install.sh --port 8443
#   bash install.sh --sni www.samsung.com
#   bash install.sh --allow-torrent     # do not block bittorrent
#   bash install.sh --host vpn.example.com   # put a hostname in client links
#                                            # (home server on a dynamic IP)
#
set -euo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

XRAY_BIN=/usr/local/bin/xray
XRAY_DIR=/usr/local/etc/xray
XRAY_ASSETS=/usr/local/share/xray
export XRAY_LOCATION_ASSET="$XRAY_ASSETS"
CONFIG="$XRAY_DIR/config.json"
META="$XRAY_DIR/server.env"

PORT=443
SNI=""
HOST=""
BLOCK_TORRENT=1

valid_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }
valid_host() {
  [[ ${#1} -le 253 && "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && "$1" != *..* ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port|--sni|--host)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "missing value for $1" >&2; exit 1; }
      case "$1" in
        --port) PORT=$2 ;;
        --sni) SNI=$2 ;;
        --host) HOST=$2 ;;
      esac
      shift 2 ;;
    --allow-torrent) BLOCK_TORRENT=0; shift ;;
    -h|--help)       sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

valid_port "$PORT" || die "port must be an integer from 1 to 65535"
[[ -z "$HOST" ]] || valid_host "$HOST" || die "host must be an IPv4 address or DNS hostname"
[[ -z "$SNI" ]] || valid_host "$SNI" || die "SNI must be a DNS hostname"

# Xray itself warns about this: a REALITY listener on a non-443 port is an
# anomaly the GFW looks for, and it can get the whole IP blocked.
[[ "$PORT" == 443 ]] || warn "port $PORT is not 443 — this makes the server easier to fingerprint and block"

[[ $EUID -eq 0 ]] || die "run as root (sudo bash install.sh)"
[[ ! -e "$CONFIG" && ! -L "$CONFIG" && ! -e "$META" && ! -L "$META" ]] \
  || die "existing configuration found; refusing to overwrite users or keys. See SECURITY.md for migration"
[[ ! -e "$XRAY_DIR" && ! -L "$XRAY_DIR" ]] \
  || die "existing Xray directory found; use a clean, dedicated server"
[[ ! -e /etc/systemd/system/xray.service ]] || die "existing Xray service found"
[[ -r /etc/os-release ]] || die "unsupported OS"
# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" =~ ^(ubuntu|debian)$ ]] || die "only Ubuntu and Debian are supported"

# Read the effective SSH configuration, including Include directives, before
# changing packages or firewall rules. Preserve every configured SSH listener.
command -v sshd >/dev/null || die "install and configure OpenSSH server first"
SSH_PORTS=$(sshd -T | awk '$1 == "port" {print $2}')
[[ -n "$SSH_PORTS" ]] || die "could not determine SSH ports"
for ssh_port in $SSH_PORTS; do
  valid_port "$ssh_port" || die "invalid SSH port reported by sshd"
  [[ "$ssh_port" != "$PORT" ]] || die "VPN port conflicts with SSH"
done

# ---------------------------------------------------------------- packages
log "installing dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl unzip jq qrencode openssl ca-certificates \
                      chrony ufw fail2ban >/dev/null

# clock skew breaks the REALITY handshake, so make sure NTP is actually on
timedatectl set-ntp true 2>/dev/null || true
systemctl enable --now chrony >/dev/null 2>&1 || true

# ---------------------------------------------------------------- xray core
case "$(uname -m)" in
  x86_64|amd64)  ASSET=Xray-linux-64.zip ;;
  aarch64|arm64) ASSET=Xray-linux-arm64-v8a.zip ;;
  armv7l)        ASSET=Xray-linux-arm32-v7a.zip ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

# Reviewed release: change only after validating a newer version.
TAG=v26.3.27
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected release tag"
log "installing Xray-core $TAG ($ASSET)"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BASE="https://github.com/XTLS/Xray-core/releases/download/$TAG"
curl -fsSL -o "$TMP/x.zip"      "$BASE/$ASSET"
curl -fsSL -o "$TMP/x.zip.dgst" "$BASE/$ASSET.dgst"

# the .dgst file lists several hashes; pull the SHA2-256 line and compare
want=$(awk '/^SHA2-256=/{print $2}' "$TMP/x.zip.dgst")
have=$(sha256sum "$TMP/x.zip" | awk '{print $1}')
[[ -n "$want" ]] || die "no checksum found in $ASSET.dgst"
[[ "$want" == "$have" ]] || die "checksum mismatch (want $want, got $have)"
log "checksum verified"

unzip -oq "$TMP/x.zip" -d "$TMP/x"
install -m 755 "$TMP/x/xray" "$XRAY_BIN"
install -d -m 755 "$XRAY_ASSETS" /var/log/xray
id -u xray >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin xray
[[ $(id -u xray) -ne 0 ]] || die "xray must not be a root account"
install -d -m 750 -o root -g xray "$XRAY_DIR"
install -m 644 "$TMP/x/geoip.dat" "$TMP/x/geosite.dat" "$XRAY_ASSETS/"
chmod 750 /var/log/xray

# ---------------------------------------------------------------- pick SNI
# REALITY borrows a real site's TLS handshake. The site must speak TLS 1.3 +
# HTTP/2 and be reachable *from this VPS*, so probe rather than guess.
probe_sni() {
  local host=$1 out
  out=$(timeout 6 openssl s_client -connect "$host:443" -servername "$host" \
        -tls1_3 -alpn h2 </dev/null 2>/dev/null) || return 1
  grep -q 'ALPN protocol: h2'      <<<"$out" || return 1
  grep -q 'TLSv1.3'                <<<"$out" || return 1
  return 0
}

if [[ -z "$SNI" ]]; then
  log "probing candidate SNI targets (TLS 1.3 + HTTP/2)"
  for cand in www.samsung.com www.lovelive-anime.jp swdist.apple.com \
              www.asus.com academy.nvidia.com addons.mozilla.org \
              www.amd.com shop.battle.net; do
    if probe_sni "$cand"; then
      # rough latency check — a nearby target makes the disguise more credible
      ms=$( { time -p timeout 6 openssl s_client -connect "$cand:443" \
              -servername "$cand" </dev/null >/dev/null 2>&1; } 2>&1 \
            | awk '/^real/{printf "%d", $2*1000}')
      printf '    %-24s ok  (~%sms)\n' "$cand" "${ms:-?}"
      [[ -z "$SNI" ]] && SNI="$cand"
    else
      printf '    %-24s unusable\n' "$cand"
    fi
  done
fi
[[ -n "$SNI" ]] || die "no usable SNI target found; pass one with --sni"
probe_sni "$SNI" || die "SNI target failed TLS 1.3 / HTTP/2 validation"
log "SNI target: $SNI"

# ---------------------------------------------------------------- keys
KEYPAIR=$("$XRAY_BIN" x25519)
# label wording changes between Xray versions ("Public key:" vs
# "Password (PublicKey):"), so key off line position and take the last field
PRIVATE_KEY=$(sed -n '1p' <<<"$KEYPAIR" | awk '{print $NF}')
PUBLIC_KEY=$( sed -n '2p' <<<"$KEYPAIR" | awk '{print $NF}')
[[ ${#PRIVATE_KEY} -gt 20 && ${#PUBLIC_KEY} -gt 20 ]] || die "failed to generate REALITY keypair"

UUID=$("$XRAY_BIN" uuid)
SHORT_ID=$(openssl rand -hex 8)

# what clients dial. A home server's IP moves, so allow a DDNS hostname here;
# this is only the dial address — the TLS name clients present is still $SNI.
if [[ -n "$HOST" ]]; then
  SERVER_IP="$HOST"
  log "client links will use hostname: $HOST"
else
  SERVER_IP=$(curl -fsS --max-time 10 https://api.ipify.org \
              || curl -fsS --max-time 10 https://ifconfig.me \
              || hostname -I | awk '{print $1}')
  [[ -n "$SERVER_IP" ]] || die "could not determine public IP"
fi
valid_host "$SERVER_IP" || die "invalid public address; pass --host explicitly"

# ---------------------------------------------------------------- config
routing_rules='[
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:private"], "outboundTag": "block" }'
if [[ $BLOCK_TORRENT -eq 1 ]]; then
  routing_rules+=',
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }'
fi
routing_rules+='
    ]'

cat > "$CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query", "1.1.1.1"],
    "queryStrategy": "UseIP"
  },
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "flow": "xtls-rprx-vision", "email": "admin" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$SNI:443",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIP" } },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": $routing_rules
  },
  "policy": {
    "levels": { "0": { "handshake": 3, "connIdle": 180 } },
    "system": { "statsInboundUplink": false, "statsInboundDownlink": false }
  }
}
EOF
chown root:xray "$CONFIG"
chmod 640 "$CONFIG"

cat > "$META" <<EOF
SERVER_IP=$SERVER_IP
PORT=$PORT
SNI=$SNI
PUBLIC_KEY=$PUBLIC_KEY
EOF
chown root:root "$META"
chmod 600 "$META"

"$XRAY_BIN" run -test -config "$CONFIG" >/dev/null || die "generated config failed validation"
log "config validated"

# ---------------------------------------------------------------- service
chown xray:xray /var/log/xray

cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://xtls.github.io/
After=network-online.target
Wants=network-online.target

[Service]
User=xray
Group=xray
# needed to bind :443 as a non-root user
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$XRAY_BIN run -config $CONFIG
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/log/xray
Environment=XRAY_LOCATION_ASSET=$XRAY_ASSETS

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/logrotate.d/xray <<'EOF'
/var/log/xray/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
    su xray xray
}
EOF

systemctl daemon-reload
systemctl enable --now xray >/dev/null
sleep 1
systemctl is-active --quiet xray || { journalctl -u xray -n 30 --no-pager; die "xray failed to start"; }
log "xray service running"

# ---------------------------------------------------------------- tuning
log "enabling BBR + network tuning"
cat > /etc/sysctl.d/99-xray.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
fs.file-max = 1048576
EOF
sysctl --system >/dev/null 2>&1 || true

# ---------------------------------------------------------------- firewall
log "firewall: preserving existing rules; allowing SSH ports and Xray on $PORT"
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
for ssh_port in $SSH_PORTS; do ufw allow "$ssh_port"/tcp >/dev/null; done
ufw allow "$PORT"/tcp      >/dev/null
ufw --force enable         >/dev/null
systemctl enable --now fail2ban >/dev/null 2>&1 || true

# ---------------------------------------------------------------- manager
install -m 755 /dev/stdin /usr/local/bin/vpn <<'VPN_MANAGER_EOF'
#!/usr/bin/env bash
# vpn — manage Xray REALITY users
set -euo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

XRAY_DIR=/usr/local/etc/xray
CONFIG="$XRAY_DIR/config.json"
META="$XRAY_DIR/server.env"
XRAY=/usr/local/bin/xray
export XRAY_LOCATION_ASSET=/usr/local/share/xray

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -f "$CONFIG" && -f "$META" ]] || { echo "xray is not installed" >&2; exit 1; }
die() { echo "$*" >&2; exit 1; }
for path in "$XRAY_DIR" "$CONFIG" "$META"; do
  [[ ! -L "$path" && $(stat -c %u "$path") == 0 ]] || die "unsafe ownership or symlink: $path; see SECURITY.md"
  mode=$(stat -c %a "$path")
  (( (8#$mode & 8#022) == 0 )) || die "group/world-writable path: $path"
done
# Serialize reads and writes. The service account cannot create this lock.
exec 9>"$XRAY_DIR/.manager.lock"
flock -x 9

# Metadata is data, never shell code, including during legacy migrations.
SERVER_IP='' PORT='' SNI='' PUBLIC_KEY=''
while IFS='=' read -r key value || [[ -n "$key" ]]; do
  case "$key" in
    SERVER_IP) SERVER_IP=$value ;;
    PORT) PORT=$value ;;
    SNI) SNI=$value ;;
    PUBLIC_KEY) PUBLIC_KEY=$value ;;
    *) die "unexpected metadata field" ;;
  esac
done < "$META"
if [[ ! "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] || (( 10#$PORT > 65535 )); then
  die "invalid metadata port"
fi
for host in "$SERVER_IP" "$SNI"; do
  [[ ${#host} -le 253 && "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && "$host" != *..* ]] || die "invalid metadata hostname"
done
[[ "$PUBLIC_KEY" =~ ^[a-zA-Z0-9_-]{43}$ ]] || die "invalid metadata public key"

tmp='' backup=''
cleanup() { [[ -z "$tmp" ]] || rm -f -- "$tmp"; [[ -z "$backup" ]] || rm -f -- "$backup"; }
trap cleanup EXIT

valid_name() {
  [[ -n "$1" && ${#1} -le 64 && ! "$1" =~ [[:cntrl:]] ]] || die "user name must be 1-64 characters without control characters"
}

reload() {
  "$XRAY" run -test -config "$tmp" >/dev/null || die "candidate config invalid; original preserved"
  backup=$(mktemp "$XRAY_DIR/.backup.XXXXXX")
  cp -p "$CONFIG" "$backup"
  chown root:xray "$tmp"; chmod 640 "$tmp"
  mv -f -- "$tmp" "$CONFIG"; tmp=
  if ! systemctl restart xray || ! systemctl is-active --quiet xray; then
    mv -f -- "$backup" "$CONFIG"; backup=
    systemctl restart xray || true
    die "restart failed; original configuration restored"
  fi
  rm -f -- "$backup"; backup=
}

urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

share_link() {
  local name=$1 uuid sid
  uuid=$(jq -r --arg e "$name" \
    '.inbounds[0].settings.clients[]|select(.email==$e)|.id' "$CONFIG")
  [[ -n "$uuid" && "$uuid" != null ]] || { echo "no such user: $name" >&2; return 1; }
  # each user gets its own shortId, matched by position
  local idx
  idx=$(jq -r --arg e "$name" \
    '[.inbounds[0].settings.clients[].email]|index($e)' "$CONFIG")
  sid=$(jq -r --argjson i "$idx" '.inbounds[0].streamSettings.realitySettings.shortIds[$i]' "$CONFIG")
  printf 'vless://%s@%s:%s?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=%s&fp=chrome&pbk=%s&sid=%s#%s\n' \
    "$uuid" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$sid" "$(urlenc "$name")"
}

show() {
  local name=$1 link
  link=$(share_link "$name")
  echo
  echo "  user : $name"
  echo "  link : $link"
  echo
  qrencode -t ANSIUTF8 -m 2 "$link"
}

case "${1:-help}" in
  add)
    name=${2-}
    valid_name "$name"
    jq -e --arg e "$name" '.inbounds[0].settings.clients[]|select(.email==$e)' \
      "$CONFIG" >/dev/null 2>&1 && { echo "user '$name' already exists" >&2; exit 1; }
    uuid=$("$XRAY" uuid); sid=$(openssl rand -hex 8)
    tmp=$(mktemp "$XRAY_DIR/.config.XXXXXX")
    jq --arg id "$uuid" --arg e "$name" --arg sid "$sid" '
      .inbounds[0].settings.clients += [{id:$id, flow:"xtls-rprx-vision", email:$e}]
      | .inbounds[0].streamSettings.realitySettings.shortIds += [$sid]' \
      "$CONFIG" > "$tmp"
    reload; show "$name" ;;

  del|rm)
    name=${2-}
    valid_name "$name"
    idx=$(jq -r --arg e "$name" '[.inbounds[0].settings.clients[].email]|index($e)' "$CONFIG")
    [[ "$idx" != null ]] || { echo "no such user: $name" >&2; exit 1; }
    [[ "$idx" != 0 ]] || { echo "refusing to delete the admin user" >&2; exit 1; }
    tmp=$(mktemp "$XRAY_DIR/.config.XXXXXX")
    jq --argjson i "$idx" '
      .inbounds[0].settings.clients |= del(.[$i])
      | .inbounds[0].streamSettings.realitySettings.shortIds |= del(.[$i])' \
      "$CONFIG" > "$tmp"
    reload; echo "removed $name" ;;

  list|ls)
    printf '%-20s %s\n' USER UUID
    jq -r '.inbounds[0].settings.clients[]|"\(.email)\t\(.id)"' "$CONFIG" \
      | while IFS=$'\t' read -r e i; do printf '%-20s %s\n' "$e" "$i"; done ;;

  link|qr) valid_name "${2-}"; show "$2" ;;

  status)
    systemctl status xray --no-pager -n 5 || true
    echo; echo "listening on ${SERVER_IP}:${PORT}  sni=${SNI}"
    ss -tlnp 2>/dev/null | grep -E ":${PORT}\b" || echo "WARNING: nothing listening on ${PORT}" ;;

  log)
    count=${2:-50}
    [[ "$count" =~ ^[1-9][0-9]{0,5}$ ]] || die "log count must be 1-999999"
    journalctl -u xray -n "$count" --no-pager ;;

  update)
    die "automatic update is disabled: follow the verified, staged update procedure in SECURITY.md" ;;

  *)
    cat <<'USAGE'
usage: vpn <command>

  add <name>     create a user and print its link + QR code
  del <name>     remove a user
  list           list users
  link <name>    reprint a user's link + QR code
  status         service and listener status
  log [n]        last n log lines
  update         explain the manual update requirement (does not change the server)
USAGE
    ;;
esac
VPN_MANAGER_EOF

# ---------------------------------------------------------------- done
echo
log "installation complete"
vpn link admin
cat <<EOF

  server   : $SERVER_IP:$PORT
  protocol : VLESS + XTLS-Vision + REALITY
  sni      : $SNI

  manage with:  vpn add <name> | vpn list | vpn del <name> | vpn status

EOF
